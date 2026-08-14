// WindowShelf.qml — "la Repisa"
// ---------------------------------------------------------------------------
// El diagnóstico: "minimizar" en Windows son DOS funciones que el tiling separó.
//   (a) quitar algo de en medio sin cerrarlo  -> el scratchpad de Hyprland ya lo hace
//   (b) tener un inventario permanente de lo que existe -> ESTO es lo que falta
// Todos los rices atacan (a) con un scratchpad que, en cuanto lo usas, desaparece
// de la vista: guardar algo ahí es perderlo. Este widget existe SOLO para (b).
//
// REGLA DURA DEL DISEÑO: nada entra en la Repisa sin dejar una ficha visible en
// la barra, ocupando píxeles reales, para siempre. Por eso no hay auto-ocultado,
// ni colapso por inactividad, ni "modo compacto" que esconda fichas: el
// desbordamiento se convierte en un `+N` que sigue ocupando sitio y que abre el
// inventario completo.
//
// Adaptado de código real de end-4/illogical-impulse (commit 69f1a54):
//   - icono de app:            modules/ii/dock/DockAppButton.qml:94-97
//   - re-resolver icono:       modules/ii/dock/DockAppButton.qml:25-31
//   - ScriptModel + objectProp:modules/ii/dock/DockApps.qml:49-52
//   - debounce de hover:       modules/ii/dock/DockApps.qml:67-93
//   - estructura del popover:  modules/ii/bar/StyledPopup.qml  (DIVERGE: ver R15 abajo)
//   - sintaxis Lua de dispatch:modules/ii/overview/OverviewWidget.qml:269,287
// ---------------------------------------------------------------------------

import QtQuick
import QtQuick.Layouts
import QtQuick.Effects
import Quickshell
import Quickshell.Io
import Quickshell.Hyprland
import Quickshell.Widgets
import Quickshell.Wayland
import qs.services
import qs.modules.common
import qs.modules.common.widgets

MouseArea {
    id: root

    // ---------------------------------------------------------------- opt-in
    // B2 del brief: opt-in y fallo aislado. Todo con `?.` + `??` para que el
    // widget funcione ANTES de que el usuario añada el bloque a Config.qml, y
    // para que se apague solo si Config todavía no ha cargado.
    property bool shelfEnabled: Config.options?.bar?.windowShelf?.enable ?? false
    property string shelfWorkspace: Config.options?.bar?.windowShelf?.workspace ?? "shelf"
    property int maxChips: Config.options?.bar?.windowShelf?.maxChips ?? 9
    property int staleMinutes: Config.options?.bar?.windowShelf?.staleMinutes ?? 30
    property int oldHours: Config.options?.bar?.windowShelf?.oldHours ?? 4
    property bool useGlobalShortcuts: Config.options?.bar?.windowShelf?.globalShortcuts ?? true
    property bool attentionPulse: Config.options?.bar?.windowShelf?.attentionPulse ?? true
    property var ignoredWorkspaces: Config.options?.bar?.windowShelf?.ignoreWorkspaces ?? []

    // Si HyprlandData todavía no ha poblado nada, el widget entero desaparece en
    // vez de tumbar la barra (B9). `undefined` y `null` se tratan igual.
    readonly property bool hasData: (HyprlandData?.windowList ?? null) !== null
    readonly property bool active: root.shelfEnabled && root.hasData

    // ------------------------------------------------------------ geometría
    readonly property real chipSize: Math.max(18, Math.min(26, Appearance.sizes.baseBarHeight - 10))
    readonly property real iconSize: root.chipSize - 6
    readonly property real chipSpacing: 3
    // R16: margen explícito alrededor de la fila. El punto de novedad y el aro de
    // fijado se dibujan DENTRO de la ficha (ver `novelDot`), pero el pulso de
    // atención escala la ficha a 1.08, así que la fila necesita holgura o la
    // ventana de la barra recorta el borde superior/inferior.
    readonly property real edgePadding: 4

    visible: root.active
    implicitWidth: root.active ? (chipRow.implicitWidth + root.edgePadding * 2) : 0
    implicitHeight: Appearance.sizes.baseBarHeight
    hoverEnabled: true
    // No robamos clics: las fichas tienen su propio MouseArea encima. Este
    // MouseArea existe solo para saber si el ratón está sobre la Repisa.
    acceptedButtons: Qt.NoButton

    Behavior on implicitWidth {
        animation: Appearance.animation.elementMoveFast.numberAnimation.createObject(this)
    }

    // ============================================================== INVENTARIO
    // `meta` guarda lo que Hyprland NO sabe: cuándo se guardó, si hay novedad, si
    // está fijada y en qué orden llegó. Se indexa por dirección normalizada (sin
    // "0x", minúsculas) porque `hyprctl clients -j` la da CON prefijo y los
    // eventos del socket2 la dan SIN él.
    property var meta: ({})
    property int arrivalSeq: 0
    property int pinSeq: 0
    property var entries: []
    // Tolerancia de ausencias antes de borrar una ficha (B3, permanencia mínima):
    // un refresco a medias de `windowList` no puede vaciar el inventario.
    readonly property int missTolerance: 2
    // Direcciones que acabamos de sacar de la Repisa, con su fecha de caducidad.
    property var restoring: ({})
    readonly property int restoreGraceMs: 1500
    property int lastNormalWorkspaceId: 1
    property double now: Date.now()
    property int iconEpoch: 0

    function normAddr(a) {
        if (!a)
            return "";
        var s = String(a).trim().toLowerCase();
        if (s.indexOf("0x") === 0)
            s = s.substring(2);
        return s;
    }

    function isSpecial(name) {
        return (typeof name === "string") && name.indexOf("special:") === 0;
    }

    function syncFromHyprland() {
        var list = HyprlandData?.windowList ?? null;
        // Lista vacía o ausente = "no hay datos", NO "no hay nada guardado".
        // Una ventana guardada sigue apareciendo en `hyprctl clients -j`, así que
        // una lista vacía de verdad implica cero ventanas en todo el sistema y
        // por tanto cero fichas; tratarlo como "sin datos" es lo conservador.
        if (!list || list.length === 0) {
            root.rebuildEntries();
            return;
        }

        var seen = ({});
        for (var i = 0; i < list.length; i++) {
            var w = list[i];
            if (!w || !w.address || !w.workspace)
                continue;
            if (!root.isSpecial(w.workspace.name))
                continue;
            // Hecho 5 del brief: con una ventana en fullscreen, las otras de su
            // columna se aparcan en at≈[-100000,-100000] con size=[1,1]. Esas no
            // son fichas, son centinelas.
            if (w.size && w.size[0] <= 1)
                continue;
            if (root.ignoredWorkspaces.indexOf(w.workspace.name) !== -1)
                continue;

            var key = root.normAddr(w.address);
            // Ventana de gracia tras recuperar: descartamos lecturas rancias que
            // todavía sitúan la ventana en el special.
            if (root.restoring[key] !== undefined) {
                if (Date.now() < root.restoring[key])
                    continue;
                delete root.restoring[key];
            }
            seen[key] = true;
            var m = root.meta[key];
            var title = w.title ?? "";
            if (!m) {
                root.meta[key] = ({
                    seq: ++root.arrivalSeq,
                    shelvedAt: Date.now(),
                    title: title,
                    cls: w.class ?? "",
                    ws: w.workspace.name,
                    addr: w.address,
                    pinned: false,
                    pinAt: 0,
                    novel: false,
                    misses: 0
                });
            } else {
                m.misses = 0;
                m.cls = w.class ?? m.cls;
                m.ws = w.workspace.name;
                m.addr = w.address;
                // R4: el cambio de título mientras está guardada es novedad.
                // HyprlandData ya re-ejecuta `hyprctl clients -j` en cada evento
                // (hecho 10), así que esto no añade ni una llamada IPC.
                if (title !== m.title) {
                    m.title = title;
                    m.novel = true;
                }
            }
        }

        var keys = Object.keys(root.meta);
        for (var k = 0; k < keys.length; k++) {
            if (seen[keys[k]])
                continue;
            root.meta[keys[k]].misses++;
            if (root.meta[keys[k]].misses >= root.missTolerance)
                delete root.meta[keys[k]];
        }
        root.rebuildEntries();
    }

    function rebuildEntries() {
        var out = [];
        var keys = Object.keys(root.meta);
        for (var i = 0; i < keys.length; i++) {
            var m = root.meta[keys[i]];
            out.push({
                key: keys[i],
                address: m.addr,
                cls: m.cls,
                title: m.title,
                ws: m.ws,
                shelvedAt: m.shelvedAt,
                pinned: m.pinned,
                pinAt: m.pinAt,
                novel: m.novel,
                seq: m.seq
            });
        }
        // R6, constancia posicional: las fijadas SIEMPRE a la izquierda y, dentro
        // de cada bloque, por orden de llegada (nunca por reciente). Consecuencia
        // buscada: sin acción del usuario ninguna ficha cambia de sitio jamás; las
        // nuevas se añaden por la derecha. Un trastero que se reordena solo deja
        // de servir. Efecto secundario útil: como las fijadas van primero, nunca
        // caen al desbordamiento `+N`.
        out.sort(function (a, b) {
            if (a.pinned !== b.pinned)
                return a.pinned ? -1 : 1;
            if (a.pinned)
                return a.pinAt - b.pinAt;
            return a.seq - b.seq;
        });
        root.entries = out;
    }

    // ================================================================ ACCIONES
    // R12 / hecho verificado: con config Lua la sintaxis de dispatchers CAMBIA.
    // `Hyprland.usingLua` (Quickshell 0.3.0) lo dice en tiempo de ejecución, así
    // que no hay que adivinar: emitimos el dialecto correcto en cada caso.
    // Con Lua, `follow = false` es el equivalente exacto de `movetoworkspacesilent`.
    // Se lee en el momento de despachar, no se cachea: `usingLua` es false hasta
    // que el módulo Hyprland de Quickshell termina de inicializarse.
    readonly property bool lua: Hyprland.usingLua

    // En Lua, un selector de workspace NUMÉRICO no puede ir entrecomillado y uno
    // con NOMBRE ("special:shelf", "r+1") sí. Mezclarlo es el fallo silencioso
    // clásico: el dispatch no falla, simplemente no hace nada.
    function luaValue(v) {
        var s = String(v);
        return /^[-+]?\d+$/.test(s) ? s : `"${s}"`;
    }

    // `hyprctl clients -j` da la dirección CON "0x"; los eventos del socket2 la
    // dan SIN él. El selector siempre la quiere con prefijo.
    function windowSelector(addr) {
        var s = String(addr);
        if (s.indexOf("address:") === 0)
            return s;
        return "address:" + (s.indexOf("0x") === 0 ? s : "0x" + s);
    }

    function moveWindow(ws, addr, follow) {
        var sel = root.windowSelector(addr);
        if (root.lua)
            Hyprland.dispatch(`hl.dsp.window.move({ workspace = ${root.luaValue(ws)}, window = "${sel}", follow = ${follow ? "true" : "false"} })`);
        else
            Hyprland.dispatch(`${follow ? "movetoworkspace" : "movetoworkspacesilent"} ${ws},${sel}`);
        root.nudgeWindowList();
    }

    function focusWindow(addr) {
        var sel = root.windowSelector(addr);
        if (root.lua)
            Hyprland.dispatch(`hl.dsp.focus({window = "${sel}"})`);
        else
            Hyprland.dispatch(`focuswindow ${sel}`);
    }

    // Refresco inmediato tras una acción DEL USUARIO (nunca en bucle). Lanza solo
    // `hyprctl clients -j`, no los cinco procesos de updateAll(). El evento de
    // Hyprland refrescaría igual: esto solo quita la latencia. Con guarda por si
    // la función no existe en esta versión del servicio.
    function nudgeWindowList() {
        if (typeof HyprlandData?.updateWindowList === "function")
            HyprlandData.updateWindowList();
    }

    function focusedClient() {
        var list = HyprlandData?.windowList ?? null;
        if (!list)
            return null;
        for (var i = 0; i < list.length; i++) {
            // El brief garantiza `focusHistoryID` en windowList; 0 = la enfocada.
            if (list[i] && list[i].focusHistoryID === 0)
                return list[i];
        }
        return null;
    }

    // R1: función invocable. El atajo lo ata el usuario (ver nota final).
    function stash() {
        var w = root.focusedClient();
        if (!w || !w.address)
            return;
        // Guardar algo que ya está guardado no hace nada.
        if (root.isSpecial(w.workspace?.name))
            return;
        root.moveWindow("special:" + root.shelfWorkspace, w.address, false);
    }

    // R3: recuperar. Ver `caveatText`: NO vuelve a su sitio original.
    function restore(addr) {
        if (!addr)
            return;
        var id = root.lastNormalWorkspaceId;
        if (typeof id !== "number" || id < 1)
            return;
        var key = root.normAddr(addr);
        // Carrera real: si un refresco de `windowList` ya estaba en vuelo cuando
        // pulsamos, vuelve con la ventana TODAVÍA en el special y `sync` la
        // resucitaría como ficha nueva, perdiendo su antigüedad y su fijado.
        // Durante la ventana de gracia se ignora esa dirección.
        root.restoring[key] = Date.now() + root.restoreGraceMs;
        root.moveWindow(id, addr, false);
        root.focusWindow(addr);
        // Salida inmediata: no esperamos a la histéresis para quitar la ficha.
        delete root.meta[key];
        root.popupLatched = false;
        root.rebuildEntries();
    }

    function restoreLast() {
        if (root.entries.length === 0)
            return;
        root.restore(root.entries[root.entries.length - 1].address);
    }

    function togglePin(key) {
        var m = root.meta[key];
        if (!m)
            return;
        m.pinned = !m.pinned;
        m.pinAt = m.pinned ? ++root.pinSeq : 0;
        root.rebuildEntries();
    }

    // Marcar como vista sin recuperarla: si no, una novedad solo se apaga
    // recuperando la ventana, y eso obliga a deshacer la Repisa para callarla.
    function dismissNovelty(key) {
        var m = root.meta[key];
        if (!m || !m.novel)
            return;
        m.novel = false;
        root.rebuildEntries();
    }

    function ageLabel(ms) {
        var h = Math.floor(ms / 3600000);
        if (h < 24)
            return h + "h";
        return Math.floor(h / 24) + "d";
    }

    // ================================================================= SEÑALES
    Connections {
        target: HyprlandData

        function onWindowListChanged() {
            root.syncFromHyprland();
        }

        function onActiveWorkspaceChanged() {
            var ws = HyprlandData?.activeWorkspace ?? null;
            // Cacheamos el último workspace NORMAL: si el usuario está mirando un
            // special en el momento de recuperar, devolver la ventana "al actual"
            // la metería en otro scratchpad.
            if (ws && typeof ws.id === "number" && ws.id >= 1)
                root.lastNormalWorkspaceId = ws.id;
        }
    }

    Connections {
        target: Hyprland

        // R4, la otra mitad: `urgent` es la señal nativa de "esta ventana pide
        // atención" (xdg-activation). Es literalmente lo que hace parpadear la
        // barra de tareas de Windows, y llega aunque la ventana esté en un
        // special workspace. El handler es deliberadamente trivial: el socket2 de
        // Hyprland tiene cola de 64 eventos y desconecta al cliente lento
        // (hecho 10), así que aquí no se hace nada síncrono ni pesado.
        function onRawEvent(event) {
            if (event.name !== "urgent")
                return;
            // El objeto `event` se reutiliza entre emisiones: copiamos ya.
            var key = root.normAddr(String(event.data ?? "").split(",")[0]);
            var m = root.meta[key];
            if (m && !m.novel) {
                m.novel = true;
                root.rebuildEntries();
            }
        }
    }

    Connections {
        target: DesktopEntries

        // Los .desktop pueden cargar después que la primera ficha: re-resolvemos
        // los iconos una vez. Patrón de DockAppButton.qml:25-31.
        function onApplicationsChanged() {
            root.iconEpoch++;
        }
    }

    Component.onCompleted: {
        var ws = HyprlandData?.activeWorkspace ?? null;
        if (ws && typeof ws.id === "number" && ws.id >= 1)
            root.lastNormalWorkspaceId = ws.id;
        root.syncFromHyprland();
    }

    // B4 — ÚNICO Timer, y justificado: no hace IPC ni lee ficheros, solo mueve el
    // reloj para que las fichas envejezcan. Los umbrales son 30 min y 4 h, así que
    // 60 s va sobradísimo, y se PARA solo cuando la Repisa está vacía, que es el
    // estado normal. Coste: un tick de JS por minuto mientras haya algo guardado.
    Timer {
        interval: 60000
        repeat: true
        running: root.active && root.entries.length > 0
        onTriggered: root.now = Date.now()
    }

    // B3 — sobre la histéresis: los umbrales de envejecimiento son monótonos en el
    // tiempo (una ficha nunca "rejuvenece"), así que no pueden vibrar y no
    // necesitan margen de salida. Donde SÍ hace falta permanencia mínima es en la
    // pertenencia al inventario, y ahí está `missTolerance`.

    // ============================================================ IPC / ATAJOS
    IpcHandler {
        target: "shelf"

        // Los tipos de retorno son OBLIGATORIOS o Quickshell no registra la
        // función (v0.3.0). Uso: `qs -c ii ipc call shelf stash`.
        function stash(): void {
            root.stash();
        }

        function restoreLast(): void {
            root.restoreLast();
        }
    }

    Loader {
        // Opcional: si dos instancias registrasen el mismo appid:name, Quickshell
        // casca. Por eso es apagable desde Config.
        active: root.useGlobalShortcuts && root.active
        sourceComponent: Item {
            GlobalShortcut {
                name: "shelfStash"
                description: "Guarda la ventana enfocada en la Repisa"
                onPressed: root.stash()
            }
            GlobalShortcut {
                name: "shelfRestoreLast"
                description: "Recupera la última ventana guardada en la Repisa"
                onPressed: root.restoreLast()
            }
        }
    }

    // ==================================================================== UI
    readonly property int overflowCount: Math.max(0, root.entries.length - root.maxChips)
    readonly property string caveatText: "Al recuperarla vuelve junto a la ventana enfocada (o al final de la cinta), NO a su sitio original, y pierde su ancho de columna. Hyprland no guarda memoria posicional."

    Row {
        id: chipRow
        anchors.centerIn: parent
        spacing: root.chipSpacing

        // --- R7: ranura vacía. Si el destino no se ve, nadie descubre que existe.
        Item {
            visible: root.entries.length === 0
            width: visible ? root.chipSize * 1.6 : 0
            height: root.chipSize
            anchors.verticalCenter: parent.verticalCenter

            Canvas {
                id: emptySlot
                anchors.fill: parent
                // El tema Material You se regenera con cada wallpaper: hay que
                // repintar el canvas cuando cambia el color, no solo al crearlo.
                property color strokeColor: Appearance.colors.colOutlineVariant
                onStrokeColorChanged: requestPaint()
                onWidthChanged: requestPaint()
                onHeightChanged: requestPaint()
                onPaint: {
                    var ctx = getContext("2d");
                    ctx.reset();
                    var r = Math.min(height / 2, 6);
                    var x = 1;
                    var y = 1;
                    var w = width - 2;
                    var h = height - 2;
                    ctx.strokeStyle = emptySlot.strokeColor;
                    ctx.lineWidth = 1;
                    ctx.setLineDash([3, 3]);
                    ctx.beginPath();
                    ctx.moveTo(x + r, y);
                    ctx.arcTo(x + w, y, x + w, y + h, r);
                    ctx.arcTo(x + w, y + h, x, y + h, r);
                    ctx.arcTo(x, y + h, x, y, r);
                    ctx.arcTo(x, y, x + w, y, r);
                    ctx.closePath();
                    ctx.stroke();
                }
            }

            MaterialSymbol {
                anchors.centerIn: parent
                text: "inventory_2"
                iconSize: Appearance.font.pixelSize.smaller
                color: Appearance.colors.colOutlineVariant
            }
        }

        // --- Fichas
        Repeater {
            // ScriptModel + objectProp mantiene la identidad de los delegados
            // aunque `entries` se reconstruya entero en cada evento: sin esto se
            // perdería el hover y se relanzarían los pulsos de atención.
            model: ScriptModel {
                objectProp: "key"
                values: root.entries
            }

            delegate: Item {
                id: chip
                required property var modelData
                required property int index

                // `shelvedAt` puede faltar si algo fue mal: nunca dejamos que un
                // NaN se propague a la UI.
                readonly property bool aged: chip.ageMs >= root.staleMinutes * 60000
                readonly property bool old: chip.ageMs >= root.oldHours * 3600000
                readonly property double ageMs: {
                    var t = chip.modelData.shelvedAt;
                    if (typeof t !== "number")
                        return 0;
                    return Math.max(0, root.now - t);
                }
                readonly property bool novel: chip.modelData.novel === true
                readonly property bool pinned: chip.modelData.pinned === true
                // R5 + R4: una ficha con novedad recupera el color aunque sea vieja.
                // El envejecimiento habla de "cuánto lleva ahí"; la novedad, de
                // "esto acaba de pasar", y esa gana.
                readonly property bool washed: chip.aged && !chip.novel

                // R8: solo las `maxChips` primeras ocupan sitio en la barra; el
                // resto vive en el `+N`. En un Row los `visible: false` no ocupan.
                visible: chip.index < root.maxChips
                width: visible ? chipBg.implicitWidth : 0
                height: root.chipSize
                anchors.verticalCenter: parent.verticalCenter

                Rectangle {
                    id: chipBg
                    anchors.fill: parent
                    // El pulso escala la ficha; el origen centrado evita que se
                    // desplace hacia un lado al crecer.
                    transformOrigin: Item.Center
                    implicitWidth: root.chipSize + (ageText.visible ? ageText.implicitWidth + 5 : 0)
                    radius: Appearance.rounding.small
                    color: chipMouse.containsMouse ? Appearance.colors.colLayer1Hover : (chip.novel ? Appearance.colors.colSecondaryContainer : Appearance.colors.colLayer1)
                    // R6 + B12: la fijación no se señala SOLO con color (la paleta
                    // se regenera con el wallpaper y no puedo asumir contraste).
                    // Señales: posición (siempre a la izquierda) + borde + el
                    // símbolo de chincheta. Tres, y solo una es cromática.
                    border.width: chip.pinned ? 1 : 0
                    border.color: Appearance.colors.colPrimary

                    Behavior on color {
                        animation: Appearance.animation.elementMoveFast.colorAnimation.createObject(this)
                    }
                    Behavior on implicitWidth {
                        animation: Appearance.animation.elementMoveFast.numberAnimation.createObject(this)
                    }

                    // B1 — animación FINITA. Es el destello naranja de la barra de
                    // tareas de Windows: avisa tres veces y para, dejando el punto
                    // fijo como recordatorio. NUNCA Animation.Infinite: Waybar #669
                    // midió una sola animación continua llevando la GPU al 60-80%.
                    SequentialAnimation {
                        id: attention
                        running: false
                        loops: 3
                        NumberAnimation {
                            target: chipBg
                            property: "scale"
                            to: 1.08
                            duration: 140
                        }
                        NumberAnimation {
                            target: chipBg
                            property: "scale"
                            to: 1.0
                            duration: 140
                        }
                    }

                    // Si la ficha se va al desbordamiento a mitad del pulso, hay
                    // que parar Y devolver la escala: si no, se queda a 1.08.
                    onVisibleChanged: {
                        if (!visible) {
                            attention.stop();
                            chipBg.scale = 1.0;
                        }
                    }

                    // R5 — "pierde saturación", literal, con MultiEffect de
                    // QtQuick.Effects. Uso `layer.enabled` + `layer.effect` en vez
                    // de `MultiEffect { source: ... }` por tres razones:
                    //   1. es el idiom que ya funciona en esta misma barra
                    //      (Workspaces.qml:86-91),
                    //   2. con layer.enabled=false no cuesta NADA: las fichas
                    //      frescas no pagan textura ninguna,
                    //   3. si el efecto no estuviera disponible, la capa sigue
                    //      pintando el icono normal — nunca una ficha en blanco.
                    // El aviso de que `layer.enabled` recorta a la caja EXACTA del
                    // elemento no aplica aquí: dentro de `iconHolder` solo está el
                    // icono, que la rellena justa. El punto de novedad y la
                    // chincheta son HERMANOS de iconHolder, no hijos, así que
                    // quedan fuera de la capa y no se pueden recortar.
                    Item {
                        id: iconHolder
                        anchors.verticalCenter: parent.verticalCenter
                        x: (root.chipSize - width) / 2
                        width: root.iconSize
                        height: root.iconSize
                        opacity: chip.washed ? 0.75 : 1.0
                        layer.smooth: true
                        layer.enabled: chip.washed
                        layer.effect: MultiEffect {
                            saturation: -1.0
                        }

                        Behavior on opacity {
                            animation: Appearance.animation.elementMoveFast.numberAnimation.createObject(this)
                        }

                        IconImage {
                            anchors.fill: parent
                            source: {
                                root.iconEpoch;
                                return Quickshell.iconPath(AppSearch.guessIcon(chip.modelData.cls ?? ""), "image-missing");
                            }
                            implicitSize: root.iconSize
                        }
                    }

                    // R5 — segunda señal, no cromática: a las 4 h la ficha dice
                    // cuánto lleva. La Repisa se vuelve más ancha y más ruidosa
                    // cuanto más la abandonas; no puede ser un vertedero silencioso.
                    StyledText {
                        id: ageText
                        visible: chip.old
                        anchors.verticalCenter: parent.verticalCenter
                        x: root.chipSize - 1
                        text: root.ageLabel(chip.ageMs)
                        font.pixelSize: Appearance.font.pixelSize.smallest
                        color: Appearance.colors.colSubtext
                    }

                    // R4 + R16 — el punto de novedad va DENTRO de los límites de la
                    // ficha, no sobresaliendo. Un badge que desborda se recorta en
                    // cuanto un ancestro tenga `layer.enabled` (que renderiza a una
                    // textura del tamaño EXACTO del elemento) o al pegarse al borde
                    // de la ventana de la barra. Inset = imposible de recortar.
                    Rectangle {
                        id: novelDot
                        visible: chip.novel
                        width: 6
                        height: 6
                        radius: Appearance.rounding.full
                        x: root.chipSize - width - 2
                        y: 2
                        color: Appearance.m3colors.m3error
                        border.width: 1
                        border.color: Appearance.colors.colLayer1
                    }

                    // R16: tamaño explícito. Un Text sin caja se dimensiona por la
                    // altura de línea de la fuente, que aquí desbordaría la ficha
                    // por abajo; con width/height + alineación queda dentro seguro.
                    MaterialSymbol {
                        visible: chip.pinned
                        text: "keep"
                        iconSize: 9
                        color: Appearance.colors.colPrimary
                        width: 10
                        height: 10
                        horizontalAlignment: Text.AlignHCenter
                        verticalAlignment: Text.AlignVCenter
                        x: 1
                        y: root.chipSize - 11
                    }

                    MouseArea {
                        id: chipMouse
                        anchors.fill: parent
                        hoverEnabled: true
                        acceptedButtons: Qt.LeftButton | Qt.RightButton | Qt.MiddleButton
                        cursorShape: Qt.PointingHandCursor
                        onClicked: mouse => {
                            if (mouse.button === Qt.LeftButton)
                                root.restore(chip.modelData.address);
                            else if (mouse.button === Qt.RightButton)
                                // Igual que el dock, donde clic derecho fija/desfija
                                // (DockAppButton.qml altAction).
                                root.togglePin(chip.modelData.key);
                            else if (mouse.button === Qt.MiddleButton)
                                root.dismissNovelty(chip.modelData.key);
                        }
                    }
                }

                onNovelChanged: {
                    if (chip.novel && root.attentionPulse && chip.visible)
                        attention.restart();
                }
            }
        }

        // --- R8: desbordamiento. El `+N` sigue ocupando píxeles reales (R14) y es
        // el acceso al inventario completo, así que nada "desaparece" al pasar de 9.
        Rectangle {
            id: overflowChip
            visible: root.overflowCount > 0
            width: visible ? Math.max(root.chipSize, overflowText.implicitWidth + 10) : 0
            height: root.chipSize
            anchors.verticalCenter: parent.verticalCenter
            radius: Appearance.rounding.small
            color: overflowMouse.containsMouse || root.popupLatched ? Appearance.colors.colLayer1Hover : Appearance.colors.colLayer1
            border.width: 1
            border.color: Appearance.colors.colOutlineVariant

            StyledText {
                id: overflowText
                anchors.centerIn: parent
                text: "+" + root.overflowCount
                font.pixelSize: Appearance.font.pixelSize.smaller
                color: Appearance.colors.colOnLayer1
            }

            MouseArea {
                id: overflowMouse
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                // Fija el popover abierto: con el ratón solo, viajar de la barra al
                // popover es incómodo justo cuando más falta hace (hay >9 fichas).
                onClicked: root.popupLatched = !root.popupLatched
            }
        }
    }

    // ================================================================ POPOVER
    // Aquí viven R9 (el aviso del hecho 7) y el inventario completo.
    //
    // Por qué NO uso StyledPopup ni StyledToolTip:
    //   - StyledToolTip es un ToolTip de QtQuick.Controls: dentro de una ventana
    //     layer-shell de 34-40 px de alto SE RECORTA. De hecho end-4 no lo usa en
    //     ningún widget de `modules/ii/bar/`, solo en superficies grandes.
    //   - StyledPopup sí abre un PanelWindow propio (bien), pero centra sin acotar:
    //       left = mapFromItem(hoverTarget, (anchoTrigger - anchoPopup)/2, 0).x
    //     Cerca de un borde ese valor se va negativo y el contenido se recorta.
    //     No puedo parchearlo (el encargo prohíbe tocar archivos de end-4), así que
    //     replico su estructura aquí y AÑADO el acotado (R15).
    property bool popupHovered: false
    property bool popupLatched: false
    // OJO: el popover se abre TAMBIÉN con la Repisa vacía. Es justo cuando más
    // falta hace: la ranura discontinua invita a pasar el ratón y ahí es donde se
    // explica qué es esto y cómo se guarda. Condicionarlo a que hubiera fichas
    // dejaba el descubrimiento en un callejón sin salida.
    readonly property bool wantPopup: root.active && (root.containsMouse || root.popupHovered || root.popupLatched)
    readonly property int popupMaxRows: 12
    // Ancho fijo del contenido: hace determinista el acotado contra los bordes
    // (R15) y evita que un título largo dispare el ancho del popover.
    readonly property int popupWidth: 320

    onWantPopupChanged: popupDebounce.restart()

    Timer {
        id: popupDebounce
        // Puente entre la barra y el popover: entre ambos hay unos píxeles muertos
        // (el margen de la sombra queda fuera de la máscara de entrada) y sin este
        // retardo el popover se cerraría al intentar entrar en él. Mismo patrón y
        // mismo orden de magnitud que DockApps.qml:89-93. No es polling: solo
        // corre en las transiciones de hover.
        interval: 120
        repeat: false
        onTriggered: shelfPopup.show = root.wantPopup
    }

    LazyLoader {
        id: shelfPopup
        property bool show: false
        active: shelfPopup.show

        component: PanelWindow {
            id: popupWindow
            color: "transparent"
            readonly property bool barAtBottom: Config.options?.bar?.bottom ?? false

            anchors.left: true
            anchors.top: !popupWindow.barAtBottom
            anchors.bottom: popupWindow.barAtBottom

            exclusionMode: ExclusionMode.Ignore
            exclusiveZone: 0
            WlrLayershell.namespace: "quickshell:popup"
            WlrLayershell.layer: WlrLayer.Overlay

            implicitWidth: popupBackground.implicitWidth + Appearance.sizes.elevationMargin * 2
            implicitHeight: popupBackground.implicitHeight + Appearance.sizes.elevationMargin * 2

            // Solo el rectángulo visible recibe entrada; el margen de la sombra no.
            mask: Region {
                item: popupBackground
            }

            margins {
                left: {
                    var qw = root.QsWindow ?? null;
                    if (!qw)
                        return 0;
                    var w = popupWindow.implicitWidth;
                    var centered = qw.mapFromItem(root, (root.width - w) / 2, 0).x;
                    var screenW = popupWindow.screen?.width ?? qw.window?.width ?? 0;
                    if (screenW <= 0)
                        return Math.max(0, centered);
                    // R15: si no cabe centrado sobre el disparador, se pega al
                    // borde en vez de salirse y recortarse.
                    return Math.max(0, Math.min(centered, screenW - w));
                }
                top: popupWindow.barAtBottom ? 0 : Appearance.sizes.barHeight
                bottom: popupWindow.barAtBottom ? Appearance.sizes.barHeight : 0
            }

            Rectangle {
                id: popupBackground
                anchors.fill: parent
                anchors.margins: Appearance.sizes.elevationMargin
                implicitWidth: popupColumn.implicitWidth + 20
                implicitHeight: popupColumn.implicitHeight + 20
                color: Appearance.m3colors.m3surfaceContainer
                radius: Appearance.rounding.small
                border.width: 1
                border.color: Appearance.colors.colLayer0Border

                Component.onDestruction: root.popupHovered = false

                MouseArea {
                    anchors.fill: parent
                    hoverEnabled: true
                    acceptedButtons: Qt.NoButton
                    onContainsMouseChanged: root.popupHovered = containsMouse
                }

                ColumnLayout {
                    id: popupColumn
                    anchors.centerIn: parent
                    spacing: 3

                    RowLayout {
                        Layout.fillWidth: true
                        Layout.bottomMargin: 2
                        spacing: 6

                        MaterialSymbol {
                            text: "inventory_2"
                            iconSize: Appearance.font.pixelSize.normal
                            color: Appearance.colors.colOnLayer1
                        }
                        StyledText {
                            Layout.fillWidth: true
                            text: root.entries.length === 0 ? "Repisa · vacía" : ("Repisa · " + root.entries.length + (root.entries.length === 1 ? " ventana guardada" : " ventanas guardadas"))
                            font.pixelSize: Appearance.font.pixelSize.small
                            color: Appearance.colors.colOnLayer1
                        }
                    }

                    // Estado vacío: la ranura discontinua dice que la Repisa existe;
                    // esto dice qué hace y cómo se llena.
                    StyledText {
                        visible: root.entries.length === 0
                        Layout.fillWidth: true
                        Layout.preferredWidth: root.popupWidth
                        Layout.maximumWidth: root.popupWidth
                        text: "Guarda la ventana enfocada con tu atajo, o con: qs -c ii ipc call shelf stash. Deja aquí una ficha con su icono que no se va sola: clic para recuperarla, clic derecho para fijarla a la izquierda."
                        wrapMode: Text.WordWrap
                        font.pixelSize: Appearance.font.pixelSize.smallest
                        color: Appearance.colors.colSubtext
                    }

                    Repeater {
                        model: root.entries.slice(0, root.popupMaxRows)

                        delegate: Rectangle {
                            id: popupRow
                            required property var modelData
                            Layout.fillWidth: true
                            implicitWidth: root.popupWidth
                            implicitHeight: 28
                            radius: Appearance.rounding.small
                            color: rowMouse.containsMouse ? Appearance.colors.colLayer1Hover : "transparent"

                            RowLayout {
                                anchors.fill: parent
                                anchors.leftMargin: 6
                                anchors.rightMargin: 6
                                spacing: 6

                                IconImage {
                                    source: {
                                        root.iconEpoch;
                                        return Quickshell.iconPath(AppSearch.guessIcon(popupRow.modelData.cls ?? ""), "image-missing");
                                    }
                                    implicitSize: 16
                                }

                                MaterialSymbol {
                                    visible: popupRow.modelData.pinned === true
                                    text: "keep"
                                    iconSize: 12
                                    color: Appearance.colors.colPrimary
                                }

                                Rectangle {
                                    visible: popupRow.modelData.novel === true
                                    implicitWidth: 6
                                    implicitHeight: 6
                                    radius: Appearance.rounding.full
                                    color: Appearance.m3colors.m3error
                                }

                                StyledText {
                                    Layout.fillWidth: true
                                    text: (popupRow.modelData.title && popupRow.modelData.title.length > 0) ? popupRow.modelData.title : (popupRow.modelData.cls ?? "?")
                                    elide: Text.ElideRight
                                    font.pixelSize: Appearance.font.pixelSize.smaller
                                    color: Appearance.colors.colOnLayer1
                                }

                                StyledText {
                                    text: {
                                        var t = popupRow.modelData.shelvedAt;
                                        if (typeof t !== "number")
                                            return "";
                                        return root.ageLabel(Math.max(0, root.now - t));
                                    }
                                    font.pixelSize: Appearance.font.pixelSize.smallest
                                    color: Appearance.colors.colSubtext
                                }
                            }

                            MouseArea {
                                id: rowMouse
                                anchors.fill: parent
                                hoverEnabled: true
                                acceptedButtons: Qt.LeftButton | Qt.RightButton
                                cursorShape: Qt.PointingHandCursor
                                onClicked: mouse => {
                                    if (mouse.button === Qt.LeftButton)
                                        root.restore(popupRow.modelData.address);
                                    else
                                        root.togglePin(popupRow.modelData.key);
                                }
                            }
                        }
                    }

                    StyledText {
                        visible: root.entries.length > root.popupMaxRows
                        Layout.fillWidth: true
                        text: "…y " + (root.entries.length - root.popupMaxRows) + " más"
                        font.pixelSize: Appearance.font.pixelSize.smallest
                        color: Appearance.colors.colSubtext
                    }

                    Rectangle {
                        Layout.fillWidth: true
                        Layout.topMargin: 4
                        implicitHeight: 1
                        color: Appearance.colors.colOutlineVariant
                    }

                    // R9 — el hecho 7 del brief, a la vista y no escondido.
                    RowLayout {
                        Layout.fillWidth: true
                        Layout.preferredWidth: root.popupWidth
                        Layout.maximumWidth: root.popupWidth
                        Layout.topMargin: 2
                        spacing: 6

                        MaterialSymbol {
                            Layout.alignment: Qt.AlignTop
                            text: "info"
                            iconSize: Appearance.font.pixelSize.smaller
                            color: Appearance.colors.colSubtext
                        }
                        StyledText {
                            Layout.fillWidth: true
                            text: root.caveatText
                            wrapMode: Text.WordWrap
                            font.pixelSize: Appearance.font.pixelSize.smallest
                            color: Appearance.colors.colSubtext
                        }
                    }
                }
            }
        }
    }
}
