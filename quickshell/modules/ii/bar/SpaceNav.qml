// SpaceNav.qml — navegación espacial para la barra `ii` de end-4 / illogical-impulse
//
// Dos piezas en un solo archivo:
//   1. EL ASCENSOR   — indicador VERTICAL de workspaces. La longitud de cada fila
//                      codifica cuántas ventanas hay en esa planta (un "skyline").
//                      Hover abre un popover de consulta con los iconos de cada planta.
//   2. LAS MIGAS     — botón "atrás" espacial. Registra SOLO saltos no adyacentes.
//
// Diseñado para: Hyprland 0.55.x (config Lua) + Quickshell 0.3.0 + end-4 (panel family `ii`).
// Va en ~/.config/quickshell/ii/modules/ii/bar/ y se instancia desde BarContent.qml.

import qs.services
import qs.modules.common
import qs.modules.common.widgets
import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Hyprland

Item {
    id: root

    // ───────────────────────── Configuración (opt-in, tolerante a claves ausentes) ─────────────────────────
    // OJO: end-4 declara sus opciones en un JsonAdapter dentro de Config.qml con propiedades
    // ESTÁTICAS. Una clave que no esté declarada AHÍ es `undefined` para siempre, aunque se
    // escriba en shell.json — se descarta en silencio. Por eso todo se lee con optional
    // chaining + `??`, y por eso el default es FALSE: sin el bloque en Config.qml el widget
    // queda apagado, que es justo lo que pide "toggleable, off by default".
    //
    // Escotilla para probarlo sin tocar Config.qml:  SpaceNav { defaultEnable: true }
    property bool defaultEnable: false
    readonly property bool cfgEnable: Config.options?.bar?.spaceNav?.enable ?? root.defaultEnable
    readonly property bool cfgElevator: Config.options?.bar?.spaceNav?.elevator ?? true
    readonly property bool cfgBreadcrumbs: Config.options?.bar?.spaceNav?.breadcrumbs ?? true
    readonly property bool cfgGlobalShortcut: Config.options?.bar?.spaceNav?.globalShortcut ?? true
    // Distancia mínima (en nº de workspace) para considerar un cambio como "salto" y registrarlo.
    // 2 = un Super+Page_Down (adyacente, delta 1) NO deja miga. Es la regla que hace útil el widget.
    readonly property int cfgMinJump: Config.options?.bar?.spaceNav?.minJumpDistance ?? 2
    readonly property int cfgFarDistance: Config.options?.bar?.spaceNav?.farDistance ?? 3
    readonly property int cfgAwaySeconds: Config.options?.bar?.spaceNav?.awaySeconds ?? 60

    // Claves YA existentes en end-4 (verificadas en Config.qml):
    readonly property bool barAtBottom: Config.options?.bar?.bottom ?? false
    readonly property bool clickToShow: Config.options?.bar?.tooltips?.clickToShow ?? false

    // ───────────────────────── Estado de datos ─────────────────────────
    // Reparto de fuentes, a propósito:
    //   · ESTADO de workspaces (cuál está activo, cuáles existen) → objetos vivos de Quickshell
    //     (`Hyprland.workspaces`, `monitor.activeWorkspace`). Son event-driven y baratos.
    //   · DATOS POR VENTANA (clase y tamaño, que Quickshell no expone de forma utilizable)
    //     → `HyprlandData.windowList`, que es justo el hueco que ese servicio cubre.
    // No se toca `HyprlandData.workspaces` / `workspaceById`: de todo el JSON de workspaces
    // end-4 solo usa `id` y `monitor`, y esos ya vienen en los objetos de Quickshell.
    //
    // Nada de handlers de `rawEvent`: el socket2 tiene cola de 64 eventos y desconecta al
    // cliente lento. Aquí solo hay señales de cambio de propiedad, sin parseo por evento.
    readonly property HyprlandMonitor monitor: Hyprland.monitorFor(root.QsWindow.window?.screen)
    readonly property bool dataReady: (Hyprland.workspaces?.values?.length ?? 0) > 0
    readonly property bool active: root.cfgEnable && root.dataReady

    readonly property int currentWs: root.monitor?.activeWorkspace?.id ?? -1

    readonly property int floors: Math.max(1, Math.min(20, Config.options?.bar?.workspaces?.shown ?? 10))
    // Mismo cálculo de grupo que WorkspaceModel.qml de end-4: con 10 plantas y ws 11 activo,
    // el ascensor pasa a mostrar 11..20 en vez de mentir.
    readonly property int groupBase: Math.floor((Math.max(1, root.currentWs) - 1) / root.floors) * root.floors

    // Recuento de ventanas por planta + ventana principal (la de mayor área) de cada una.
    // Una sola pasada sobre windowList (n ≈ 5-30): mucho más barato que el `hyprctl clients -j`
    // que HyprlandData ya hace igualmente en cada evento, así que no añade coste de IPC.
    readonly property var floorStats: {
        const n = root.floors;
        const base = root.groupBase;
        const counts = new Array(n).fill(0);
        const mains = new Array(n).fill(null);
        const areas = new Array(n).fill(-1);
        const wins = HyprlandData.windowList ?? [];
        for (let i = 0; i < wins.length; ++i) {
            const w = wins[i];
            const wid = w?.workspace?.id ?? 0;
            if (wid < 1) continue; // los workspaces especiales tienen id negativo: fuera
            const idx = wid - base - 1;
            if (idx < 0 || idx >= n) continue;
            counts[idx] += 1;
            // NO se filtra el centinela de fullscreen (at ≈ -100000, size 1x1): son ventanas
            // reales aparcadas, y descontarlas haría encoger el skyline al maximizar algo.
            // Como su área es 1, nunca ganan el desempate de "ventana principal".
            const a = (w?.size?.[0] ?? 0) * (w?.size?.[1] ?? 0);
            if (a > areas[idx]) {
                areas[idx] = a;
                mains[idx] = w;
            }
        }
        return {
            counts: counts,
            mains: mains
        };
    }

    // Ventanas agrupadas por planta — SOLO se calcula con el popover abierto.
    // Cerrado no cuesta nada, que es lo que permite tener iconos sin pagarlos en cada evento.
    readonly property var floorWindows: {
        if (!root.popoverOpen)
            return null;
        const n = root.floors;
        const base = root.groupBase;
        const out = [];
        for (let i = 0; i < n; ++i)
            out.push([]);
        const wins = HyprlandData.windowList ?? [];
        for (let i = 0; i < wins.length; ++i) {
            const w = wins[i];
            const wid = w?.workspace?.id ?? 0;
            if (wid < 1)
                continue;
            const idx = wid - base - 1;
            if (idx < 0 || idx >= n)
                continue;
            out[idx].push(w);
        }
        return out;
    }

    // Memoización clase → icono. AppSearch.guessIcon() hace búsqueda difusa: llamarlo por
    // ventana y por evento sería caro. Con la caché se ejecuta una vez por clase distinta.
    property var iconCache: ({})
    function iconFor(cls) {
        if (!cls)
            return "";
        const hit = root.iconCache[cls];
        if (hit !== undefined)
            return hit;
        let src = "";
        try {
            src = Quickshell.iconPath(AppSearch.guessIcon(cls), "image-missing");
        } catch (e) {
            src = Quickshell.iconPath(String(cls).toLowerCase(), "image-missing");
        }
        root.iconCache[cls] = src;
        return src;
    }

    // ───────────────────────── Migas: estado ─────────────────────────
    readonly property int crumbCapacity: 3
    property var crumbs: []            // [{ ws: int, t: ms }] — la más reciente primero
    property int prevWs: -1
    property int lastDir: 1            // +1 bajando de planta (nº mayor), -1 subiendo
    property bool suppressNextRecord: false
    property bool timeStale: false
    property bool farShown: false

    readonly property var homeCrumb: root.crumbs.length > 0 ? root.crumbs[0] : null
    readonly property int homeDistance: root.homeCrumb ? Math.abs(root.currentWs - root.homeCrumb.ws) : 0

    onCurrentWsChanged: root.handleWorkspaceChange()

    function handleWorkspaceChange() {
        const from = root.prevWs;
        const to = root.currentWs;
        root.prevWs = to;
        if (to > 0 && from > 0)
            root.lastDir = (to > from) ? 1 : -1;
        numberSlide.restart();
        root.recordJump(from, to);
        // Se reevalúa SIEMPRE, no solo al dejar miga: alejarse paso a paso con
        // Super+Page_Down no registra nada pero sí cambia la distancia a casa.
        root.evaluateFar();
    }

    function recordJump(from, to) {
        if (from < 1 || to < 1)
            return;                        // arranque, o workspace especial
        if (root.suppressNextRecord) {
            // El salto lo provocó la rueda de este mismo widget (r±1 = adyacente por
            // definición aunque salte huecos vacíos). No es navegación, es ruido.
            root.suppressNextRecord = false;
            suppressTimer.stop();
            return;
        }
        if (Math.abs(to - from) < root.cfgMinJump)
            return;                        // adyacente: no deja miga
        root.pushCrumb(from);
    }

    function pushCrumb(wsId) {
        const list = root.crumbs.slice();
        if (list.length > 0 && list[0].ws === wsId)
            return;                        // no duplicar la cabeza
        for (let i = 0; i < list.length; ++i) {
            if (list[i].ws === wsId) {
                list.splice(i, 1);
                break;
            }                              // sin repetidos: se promueve al frente
        }
        list.unshift({
            ws: wsId,
            t: Date.now()
        });
        while (list.length > root.crumbCapacity)
            list.pop();
        // Reasignar el array (no mutarlo) es lo que emite la señal de cambio en QML.
        root.crumbs = list;
        root.timeStale = false;    // nueva "casa": el reloj de ausencia vuelve a cero
    }

    // Vuelve a una miga. `index` 0 = la más reciente. Pública: átala a un atajo si quieres.
    function goBack(index) {
        const i = index ?? 0;
        const c = root.crumbs[i];
        if (!c)
            return;
        root.goToWorkspace(c.ws);
    }

    function goToWorkspace(id) {
        if (id === root.currentWs || id < 1)
            return;
        // Hyprland 0.55 en modo Lua: el dispatcher recibe Lua, no `workspace N`.
        // Misma forma exacta que usa Workspaces.qml de end-4 hoy.
        Hyprland.dispatch(`hl.dsp.focus({workspace = ${id}})`);
    }

    // ───────────────────────── "Lejos de casa" (con histéresis y permanencia mínima) ─────────────────────────
    // Entra si te alejas >= cfgFarDistance plantas de la última posición estable, o si llevas
    // fuera más de cfgAwaySeconds. Sale solo al volver a distancia <= 1. La banda intermedia
    // (distancia 2) mantiene el estado: sin eso, el indicador vibraría en el umbral.
    function evaluateFar() {
        if (!root.homeCrumb) {
            root.setFar(false);
            return;
        }
        if (!root.farShown) {
            if (root.homeDistance >= root.cfgFarDistance || root.timeStale)
                root.setFar(true);
        } else if (root.homeDistance <= 1) {
            root.setFar(false);
        }
    }

    function setFar(v) {
        if (v === root.farShown)
            return;
        if (v) {
            root.farShown = true;
            farMinKeep.restart();          // una vez encendido, aguanta un mínimo
        } else if (!farMinKeep.running) {
            root.farShown = false;
        }
    }

    Timer {
        id: farMinKeep
        interval: 5000
        repeat: false
        onTriggered: root.evaluateFar()    // reevalúa al vencer la permanencia mínima
    }

    Timer {
        // Único timer periódico del widget: 0,2 Hz, y solo mientras HAY una miga y AÚN no se
        // ha cruzado el umbral de tiempo. En cuanto lo cruza, `running` pasa a false y se para.
        // Hace falta un reloj porque "llevo mucho rato fuera" no genera ningún evento.
        id: awayTicker
        interval: 5000
        repeat: true
        running: root.active && root.cfgBreadcrumbs && root.homeCrumb !== null && !root.timeStale
        onTriggered: {
            if (root.homeCrumb && (Date.now() - root.homeCrumb.t) >= root.cfgAwaySeconds * 1000) {
                root.timeStale = true;
                root.evaluateFar();
            }
        }
    }

    Timer {
        // Válvula de seguridad: si un dispatch se pierde, el flag de supresión no se queda pegado
        // comiéndose el siguiente salto de verdad. One-shot, no es polling.
        id: suppressTimer
        interval: 400
        repeat: false
        onTriggered: root.suppressNextRecord = false
    }

    // ───────────────────────── Atajo global ─────────────────────────
    // La barra se instancia una vez POR PANTALLA. Registrar el mismo GlobalShortcut en cada
    // instancia sería un duplicado, así que solo lo hace la instancia de la primera pantalla.
    readonly property var thisScreen: root.QsWindow.window?.screen ?? null
    readonly property bool primaryInstance: root.thisScreen !== null && (Quickshell.screens?.[0] ?? null) === root.thisScreen

    Loader {
        active: root.active && root.cfgBreadcrumbs && root.cfgGlobalShortcut && root.primaryInstance
        sourceComponent: backShortcut
    }

    Component {
        id: backShortcut

        // Se ata desde Lua con:  hl.dsp.global("quickshell:spaceNavBack")
        GlobalShortcut {
            name: "spaceNavBack"
            description: "SpaceNav: volver a la última planta visitada"
            onPressed: root.goBack(0)
        }
    }

    // ───────────────────────── Geometría ─────────────────────────
    Layout.fillHeight: true            // así basta con `SpaceNav {}` en BarContent
    implicitWidth: root.active ? content.implicitWidth : 0
    visible: root.active

    readonly property real floorMinLen: 5
    readonly property real floorStep: 4
    readonly property real floorMaxLen: root.floorMinLen + 4 * root.floorStep   // 4+ ventanas = tope
    readonly property real crumbSize: Math.max(12, Math.min(20, root.height - 6))
    readonly property real badgeSize: Math.round(root.crumbSize * 0.58)

    function lengthForCount(c) {
        if (c <= 0)
            return root.floorMinLen;
        return root.floorMinLen + Math.min(c, 4) * root.floorStep;
    }

    function floorAt(my) {
        if (skyline.height <= 0)
            return -1;
        const rel = my - skyline.y;
        if (rel < 0 || rel > skyline.height)
            return -1;
        const idx = Math.floor(rel / (skyline.height / root.floors));
        return Math.max(0, Math.min(root.floors - 1, idx));
    }

    readonly property int hoverFloor: elevatorMouse.containsMouse ? root.floorAt(elevatorMouse.mouseY) : -1
    readonly property bool popoverOpen: root.active && root.cfgElevator && elevatorMouse.containsMouse

    RowLayout {
        id: content
        anchors.fill: parent
        spacing: 7

        // ═════════════════════ 1. EL ASCENSOR ═════════════════════
        Item {
            id: elevator
            visible: root.cfgElevator
            Layout.fillHeight: true
            Layout.alignment: Qt.AlignVCenter
            implicitWidth: root.cfgElevator ? (numberBox.implicitWidth + 4 + root.floorMaxLen) : 0

            // Número de planta actual, con deslizamiento vertical EN LA DIRECCIÓN DEL CAMBIO:
            // ir a un workspace mayor = bajar de planta, el número entra por abajo.
            Item {
                id: numberBox
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
                height: parent.height
                implicitWidth: Math.max(13, numberText.implicitWidth)
                clip: true                 // el recorte es intencionado y del tamaño del propio item

                StyledText {
                    id: numberText
                    property real slideOffset: 0
                    anchors.horizontalCenter: parent.horizontalCenter
                    y: (parent.height - height) / 2 + slideOffset
                    text: root.currentWs > 0 ? String(root.currentWs) : "–"
                    font.pixelSize: Appearance.font.pixelSize.larger
                    font.weight: Font.DemiBold
                    color: Appearance.colors.colOnLayer1
                }

                // Una animación por cambio de estado. Cero animaciones infinitas en todo el archivo.
                SequentialAnimation {
                    id: numberSlide
                    PropertyAction {
                        target: numberText
                        property: "slideOffset"
                        value: root.lastDir >= 0 ? numberBox.height : -numberBox.height
                    }
                    ParallelAnimation {
                        NumberAnimation {
                            target: numberText
                            property: "slideOffset"
                            to: 0
                            duration: Appearance.animation.elementMoveFast.duration
                            easing.type: Appearance.animation.elementMoveFast.type
                            easing.bezierCurve: Appearance.animation.elementMoveFast.bezierCurve
                        }
                        NumberAnimation {
                            target: numberText
                            property: "opacity"
                            from: 0
                            to: 1
                            duration: Appearance.animation.elementMoveFast.duration
                        }
                    }
                }
            }

            // El skyline: una fila fina por planta, longitud = nº de ventanas.
            Item {
                id: skyline
                anchors.left: numberBox.right
                anchors.leftMargin: 4
                anchors.verticalCenter: parent.verticalCenter
                width: root.floorMaxLen
                height: parent.height

                readonly property real pitch: root.floors > 0 ? (height / root.floors) : 0
                readonly property real thickness: Math.max(1, Math.floor(skyline.pitch) - 1)

                Repeater {
                    model: root.floors

                    delegate: Rectangle {
                        id: floorRow
                        required property int index

                        readonly property int wsId: root.groupBase + floorRow.index + 1
                        readonly property int count: root.floorStats.counts[floorRow.index] ?? 0
                        readonly property bool isActive: floorRow.wsId === root.currentWs
                        readonly property bool isHovered: root.hoverFloor === floorRow.index

                        x: 0
                        y: floorRow.index * skyline.pitch
                        width: root.lengthForCount(floorRow.count)
                        // La planta actual es MÁS GRUESA además de ir en colPrimary: la paleta
                        // se regenera con el fondo de pantalla y no se puede dar el contraste
                        // por supuesto, así que el grosor es la segunda señal.
                        height: floorRow.isActive ? Math.max(2, skyline.thickness + 1) : skyline.thickness
                        radius: Appearance.rounding.full
                        color: floorRow.isActive ? Appearance.colors.colPrimary : (floorRow.count > 0 ? Appearance.colors.colOnLayer1 : Appearance.colors.colOutlineVariant)
                        opacity: floorRow.isActive ? 1.0 : (floorRow.isHovered ? 0.9 : (floorRow.count > 0 ? 0.75 : 0.4))

                        Behavior on width {
                            animation: Appearance.animation.elementMove.numberAnimation.createObject(this)
                        }
                        Behavior on height {
                            animation: Appearance.animation.elementMoveFast.numberAnimation.createObject(this)
                        }
                        Behavior on opacity {
                            animation: Appearance.animation.elementMoveFast.numberAnimation.createObject(this)
                        }
                        Behavior on color {
                            animation: Appearance.animation.elementMoveFast.colorAnimation.createObject(this)
                        }
                    }
                }
            }

            MouseArea {
                id: elevatorMouse
                anchors.fill: parent
                // Con clickToShow, end-4 apaga el hover: containsMouse solo es true al pulsar,
                // que es justo como consiguen el "tooltip al clic". Se respeta el mismo ajuste.
                hoverEnabled: !root.clickToShow
                // El botón DERECHO se deja fuera aposta para que siga subiendo al padre: en el
                // BarContent parcheado del usuario, un MouseArea encima de Workspaces abre el
                // overview con clic derecho. Si lo aceptara aquí, se lo comería.
                acceptedButtons: Qt.LeftButton | Qt.BackButton

                // `onPressed`, no `onClicked` — mismo patrón que Workspaces.qml de end-4:
                // un solo MouseArea para toda la tira y la planta se deduce de la posición.
                onPressed: mouse => {
                    if (mouse.button === Qt.BackButton) {
                        root.goBack(0);       // el botón "atrás" del ratón, atrás de verdad
                        return;
                    }
                    const f = root.floorAt(mouse.y);
                    if (f < 0)
                        return;
                    root.goToWorkspace(root.groupBase + f + 1);
                }

                // Rueda = cambio adyacente, exactamente igual que Workspaces.qml de end-4.
                onWheel: wheel => {
                    if (wheel.angleDelta.y === 0)
                        return;
                    root.suppressNextRecord = true;   // esto NO debe dejar miga
                    suppressTimer.restart();
                    if (wheel.angleDelta.y < 0)
                        Hyprland.dispatch(`hl.dsp.focus({workspace = "r+1"})`);
                    else
                        Hyprland.dispatch(`hl.dsp.focus({workspace = "r-1"})`);
                }
            }
        }

        // ═════════════════════ 2. LAS MIGAS ═════════════════════
        RowLayout {
            id: crumbRow
            visible: root.cfgBreadcrumbs
            Layout.alignment: Qt.AlignVCenter
            spacing: 3

            Repeater {
                model: root.crumbCapacity

                delegate: Item {
                    id: crumbItem
                    required property int index

                    readonly property var crumb: root.crumbs[crumbItem.index] ?? null
                    readonly property bool filled: crumbItem.crumb !== null
                    // Solo la PRIMERA miga se ilumina, y solo estando lejos de casa.
                    readonly property bool highlighted: crumbItem.index === 0 && crumbItem.filled && root.farShown
                    readonly property string iconSource: {
                        if (!crumbItem.filled)
                            return "";
                        const idx = crumbItem.crumb.ws - root.groupBase - 1;
                        if (idx < 0 || idx >= root.floors)
                            return "";
                        return root.iconFor(root.floorStats.mains[idx]?.class ?? "");
                    }

                    implicitWidth: root.crumbSize
                    implicitHeight: root.crumbSize
                    Layout.alignment: Qt.AlignVCenter

                    Rectangle {
                        id: crumbCircle
                        anchors.fill: parent
                        radius: Appearance.rounding.full
                        // Vacía = punto apagado, pero NUNCA desaparece: si no se ve, nadie
                        // descubre que el widget existe.
                        color: !crumbItem.filled ? "transparent" : (crumbItem.highlighted ? Appearance.colors.colPrimaryContainer : Appearance.colors.colSecondaryContainer)
                        border.width: crumbItem.highlighted ? 2 : 0
                        border.color: Appearance.colors.colPrimary

                        Behavior on color {
                            animation: Appearance.animation.elementMoveFast.colorAnimation.createObject(this)
                        }

                        // Estado vacío: tres puntitos apagados.
                        Rectangle {
                            visible: !crumbItem.filled
                            anchors.centerIn: parent
                            width: Math.max(4, root.crumbSize * 0.3)
                            height: width
                            radius: Appearance.rounding.full
                            color: Appearance.colors.colOutlineVariant
                            opacity: 0.55
                        }

                        AppIcon {
                            visible: crumbItem.filled && crumbItem.iconSource !== ""
                            anchors.centerIn: parent
                            implicitSize: Math.round(root.crumbSize * 0.62)
                            source: crumbItem.iconSource
                        }

                        // Sin icono (planta vacía o clase desconocida): el número al centro.
                        StyledText {
                            visible: crumbItem.filled && crumbItem.iconSource === ""
                            anchors.centerIn: parent
                            text: crumbItem.filled ? String(crumbItem.crumb.ws) : ""
                            font.pixelSize: Appearance.font.pixelSize.smaller
                            color: Appearance.colors.colOnSecondaryContainer
                        }
                    }

                    // Chapita con el número del espacio. Segunda señal junto al icono, porque
                    // dos iconos iguales en plantas distintas serían indistinguibles.
                    Rectangle {
                        id: crumbBadge
                        visible: crumbItem.filled && crumbItem.iconSource !== ""
                        anchors.right: parent.right
                        anchors.bottom: parent.bottom
                        anchors.rightMargin: -1
                        anchors.bottomMargin: -1
                        // Se ensancha a píldora con números de dos cifras (workspace 10+),
                        // que si no se salían del círculo.
                        width: Math.max(root.badgeSize, badgeText.implicitWidth + 5)
                        height: root.badgeSize
                        radius: Appearance.rounding.full
                        // Pares de rol de Material You: el contraste va garantizado aunque la
                        // paleta se regenere con el fondo de pantalla.
                        color: crumbItem.highlighted ? Appearance.colors.colPrimary : Appearance.colors.colLayer0

                        StyledText {
                            id: badgeText
                            anchors.centerIn: parent
                            text: crumbItem.filled ? String(crumbItem.crumb.ws) : ""
                            font.pixelSize: Appearance.font.pixelSize.smallest
                            color: crumbItem.highlighted ? Appearance.colors.colOnPrimary : Appearance.colors.colOnLayer0
                        }
                    }

                    MouseArea {
                        anchors.fill: parent
                        enabled: crumbItem.filled
                        acceptedButtons: Qt.LeftButton
                        onPressed: root.goBack(crumbItem.index)
                    }
                }
            }
        }
    }

    // ═════════════════════ POPOVER DEL ASCENSOR ═════════════════════
    // No se usa StyledPopup a propósito: centra el popup sobre su disparador y NO se puede
    // acotar desde fuera (solo expone hoverTarget / contentItem / popupBackgroundMargin).
    // Un PopupWindow con `adjustment: PopupAdjustment.All` delega el encaje en el compositor
    // (Flip | Slide | Resize), así que no puede recortarse por ningún borde, ni a la izquierda
    // ni a la derecha ni por abajo — y no depende de ningún parche local.
    readonly property int popoverRowH: 26
    readonly property int popoverPad: 10
    readonly property int popoverWidth: 300
    readonly property int popoverHeight: root.popoverPad * 2 + root.floors * root.popoverRowH

    PopupWindow {
        id: popover
        visible: root.popoverOpen
        color: "transparent"
        implicitWidth: root.popoverWidth
        implicitHeight: root.popoverHeight

        // Mismo patrón exacto que `modules/waffle/bar/tasks/TaskPreview.qml` de end-4.
        anchor {
            item: elevator
            // Barra arriba: cuelga por debajo. Barra abajo (`bar.bottom`): crece hacia arriba.
            edges: root.barAtBottom ? Edges.Top : Edges.Bottom
            gravity: root.barAtBottom ? Edges.Top : Edges.Bottom
            // Slide encaja horizontalmente pegado a cualquier borde; Flip da la vuelta al
            // popover si no cabe en vertical. A propósito SIN Resize: encoger la ventana
            // recortaría el contenido por dentro, que es justo lo que hay que evitar.
            adjustment: PopupAdjustment.Slide | PopupAdjustment.Flip
            margins.top: root.barAtBottom ? 0 : 4
            margins.bottom: root.barAtBottom ? 4 : 0
        }

        Rectangle {
            anchors.fill: parent
            color: Appearance.colors.colLayer0
            radius: Appearance.rounding.normal
            border.width: 1
            border.color: Appearance.colors.colOutlineVariant

            Loader {
                // El contenido (y por tanto la resolución de iconos) solo existe con el
                // popover abierto. Cerrado, coste cero.
                anchors.fill: parent
                anchors.margins: root.popoverPad
                active: root.popoverOpen
                sourceComponent: popoverContent
            }
        }
    }

    Component {
        id: popoverContent

        Column {
            spacing: 0

            Repeater {
                model: root.floors

                delegate: Item {
                    id: popRow
                    required property int index

                    readonly property int wsId: root.groupBase + popRow.index + 1
                    readonly property var wins: root.floorWindows ? (root.floorWindows[popRow.index] ?? []) : []
                    readonly property bool isActive: popRow.wsId === root.currentWs

                    width: parent.width
                    height: root.popoverRowH

                    Rectangle {
                        anchors.fill: parent
                        anchors.topMargin: 1
                        anchors.bottomMargin: 1
                        radius: Appearance.rounding.small
                        color: popRow.isActive ? Appearance.colors.colLayer1Active : "transparent"
                    }

                    StyledText {
                        id: popNumber
                        anchors.left: parent.left
                        anchors.leftMargin: 6
                        anchors.verticalCenter: parent.verticalCenter
                        width: 16
                        horizontalAlignment: Text.AlignRight
                        text: String(popRow.wsId)
                        font.pixelSize: Appearance.font.pixelSize.smaller
                        font.weight: popRow.isActive ? Font.DemiBold : Font.Normal
                        color: popRow.isActive ? Appearance.colors.colPrimary : Appearance.colors.colSubtext
                        opacity: popRow.wins.length > 0 || popRow.isActive ? 1.0 : 0.5
                    }

                    // Mini-cinta de iconos de esa planta.
                    Row {
                        anchors.left: popNumber.right
                        anchors.leftMargin: 8
                        anchors.verticalCenter: parent.verticalCenter
                        spacing: 3

                        Repeater {
                            model: Math.min(popRow.wins.length, 8)

                            delegate: AppIcon {
                                required property int index
                                implicitSize: 16
                                source: root.iconFor(popRow.wins[index]?.class ?? "")
                            }
                        }
                    }

                    StyledText {
                        anchors.right: parent.right
                        anchors.rightMargin: 6
                        anchors.verticalCenter: parent.verticalCenter
                        visible: popRow.wins.length > 8
                        text: `+${popRow.wins.length - 8}`
                        font.pixelSize: Appearance.font.pixelSize.smallest
                        color: Appearance.colors.colSubtext
                    }

                    StyledText {
                        anchors.left: popNumber.right
                        anchors.leftMargin: 8
                        anchors.verticalCenter: parent.verticalCenter
                        visible: popRow.wins.length === 0
                        text: "—"
                        font.pixelSize: Appearance.font.pixelSize.smaller
                        color: Appearance.colors.colOutlineVariant
                    }
                }
            }
        }
    }
}
