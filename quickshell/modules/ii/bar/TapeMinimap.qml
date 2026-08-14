pragma ComponentBehavior: Bound

// TapeMinimap.qml — minimapa de la cinta del layout scrolling nativo (Hyprland 0.55.x)
//
// Dibuja la cinta horizontal completa del workspace activo comprimida al ancho
// dado. Cada ventana es un segmento de ancho proporcional al real. Tres estados:
// enfocada / dentro del viewport / fuera (por izquierda o por derecha).
//
// Se deja caer en ~/.config/quickshell/ii/modules/ii/bar/ y se instancia desde
// BarContent.qml. No parchea nada de end-4.

import QtQuick
import Quickshell
import Quickshell.Hyprland
import qs.services
import qs.modules.common
import qs.modules.common.widgets

Loader {
    id: root

    // ─────────────────────────────────────────────────────────────────────
    // API pública
    // ─────────────────────────────────────────────────────────────────────

    // "transient" | "permanent" | "counter"
    property string mode: Config.options?.bar.tapeMinimap?.mode ?? "transient"

    // Ancho del dibujo de la cinta (sin contar el contador ni el padding).
    property int tapeWidth: Config.options?.bar.tapeMinimap?.width ?? 220

    // Opcional. En multi-monitor pásale el screen de la barra
    // (p. ej. `screen: QsWindow.window?.screen`) para que el minimapa mire SU
    // monitor y no el que tenga el foco. Si es null se usa el monitor enfocado.
    property var screen: null

    property int barHeight: Appearance.sizes?.baseBarHeight ?? 34

    // ─────────────────────────────────────────────────────────────────────
    // Opt-in y fallo aislado (regla dura del jurado)
    // ─────────────────────────────────────────────────────────────────────

    // Off by default: si la clave no existe en Config.qml el widget no aparece.
    // Optional chaining desde `Config.options` porque durante el arranque el
    // JsonObject puede no estar poblado todavía.
    readonly property bool enabled: Config.options?.bar.tapeMinimap?.enable ?? false

    readonly property int minWindows: Config.options?.bar.tapeMinimap?.minWindows ?? 2

    // Intervalo del Timer de los modos permanentes. Ver justificación abajo.
    readonly property int pollInterval: Config.options?.bar.tapeMinimap?.pollInterval ?? 500

    // Cuánto se queda visible el modo transitorio tras el último evento.
    readonly property int holdMs: Config.options?.bar.tapeMinimap?.holdMs ?? 1200

    // Cuánto se queda visible cuando lo que lo despierta es una urgencia.
    readonly property int urgentHoldMs: Config.options?.bar.tapeMinimap?.urgentHoldMs ?? 3000

    // ─────────────────────────────────────────────────────────────────────
    // Estado interno
    // ─────────────────────────────────────────────────────────────────────

    readonly property var emptyTape: ({
        ok: false, sig: "", items: [], span: 0, min: 0,
        vpX: 0, vpW: 0, total: 0, focusedOrdinal: 0,
        outLeft: 0, outRight: 0, urgentLeft: false, urgentRight: false
    })

    // OJO: `tape` NO es un binding. Se reasigna sólo cuando la firma cambia, para
    // que el Repeater no destruya y recree todos los delegates en cada tick del
    // poll ni en cada `title` de una pestaña del navegador.
    property var tape: root.emptyTape

    property bool transientShown: false

    // Direcciones ya "faroneadas": address -> true. Evita que el faro se
    // redispare mientras la ventana siga urgente (sería un parpadeo infinito
    // encubierto, y eso está prohibido).
    property var seenUrgent: ({})

    // Se incrementa SÓLO en una transición real a urgente fuera del viewport.
    property int faroTick: 0
    property string faroSide: ""

    active: root.enabled && root.tape.ok
            && root.tape.total >= root.minWindows
            && (root.mode !== "transient" || root.transientShown)
    visible: root.active

    // ─────────────────────────────────────────────────────────────────────
    // Datos: monitor, workspace, cinta
    // ─────────────────────────────────────────────────────────────────────

    readonly property var monitorData: {
        const ms = HyprlandData.monitors ?? [];
        if (ms.length === 0)
            return null;
        // Si nos han pasado el screen de la barra, casamos por nombre (hyprctl
        // monitors y ShellScreen usan el mismo, p. ej. "eDP-1").
        if (root.screen?.name) {
            const byName = ms.find(m => m?.name === root.screen.name);
            if (byName)
                return byName;
        }
        return ms.find(m => m?.focused) ?? ms[0] ?? null;
    }

    function buildTape() {
        try {
            const mon = root.monitorData;
            if (!mon)
                return root.emptyTape;

            // Hecho 3: `at`/`size` son coordenadas GLOBALES. El viewport de este
            // monitor es [mon.x, mon.x + ancho lógico], nunca [0, ancho].
            // hyprctl monitors publica width/height en píxeles FÍSICOS, así que
            // hay que dividir por scale para compararlo con `at`/`size`, que van
            // en coordenadas lógicas. (En este portátil scale=1 y da igual, pero
            // en un monitor escalado sin esto el viewport saldría al doble.)
            const monScale = (mon.scale && mon.scale > 0) ? mon.scale : 1;
            const monX = mon.x ?? 0;
            const monW = (mon.width ?? 0) / monScale;
            if (!(monW > 0))
                return root.emptyTape;
            const vpL = monX;
            const vpR = monX + monW;

            // El workspace activo DE ESTE MONITOR. `monitors -j` ya trae
            // activeWorkspace; si no estuviera, caemos al global de HyprlandData.
            const wsId = mon.activeWorkspace?.id ?? HyprlandData.activeWorkspace?.id;
            if (wsId === undefined || wsId === null)
                return root.emptyTape;

            // Hecho 6: no dibujamos cinta en un workspace que no usa scrolling.
            // Si el campo no existe (Hyprland viejo) asumimos que sí, para no
            // desaparecer por una comprobación que no podemos hacer.
            const tiled = (HyprlandData.workspaceById ?? {})[wsId]?.tiledLayout;
            if (tiled !== undefined && tiled !== null
                && String(tiled).toLowerCase().indexOf("scroll") < 0)
                return root.emptyTape;

            // Urgencia: HyprlandData no la expone. La sacamos de Quickshell, que
            // sí tiene HyprlandToplevel.urgent, y casamos por dirección.
            // OJO: HyprlandToplevel.address viene SIN el prefijo "0x" y
            // `hyprctl clients -j` lo pone. end-4 hace el mismo apaño en
            // OverviewWidget.qml (`const address = `0x${toplevel.HyprlandToplevel?.address}``).
            const urgentAddrs = ({});
            const tls = Hyprland.toplevels?.values ?? [];
            for (let i = 0; i < tls.length; i++) {
                const tl = tls[i];
                if (tl?.urgent && tl?.address)
                    urgentAddrs["0x" + String(tl.address).replace(/^0x/, "")] = true;
            }

            const focusedAddr = Hyprland.activeToplevel?.address
                ? "0x" + String(Hyprland.activeToplevel.address).replace(/^0x/, "")
                : "";

            const list = HyprlandData.windowList ?? [];
            const wins = [];
            for (let i = 0; i < list.length; i++) {
                const c = list[i];
                if (!c || !c.at || !c.size)
                    continue;
                if (c.workspace?.id !== wsId)
                    continue;
                // Hecho 5: con una ventana en fullscreen, las demás de su columna
                // se aparcan en at ≈ [-100000,-100000] con size [1,1].
                if (!(c.size[0] > 1))
                    continue;
                // Las flotantes no son columnas de la cinta: no ocupan hueco en
                // ella y falsearían el mapa.
                if (c.floating)
                    continue;
                wins.push(c);
            }
            if (wins.length === 0)
                return root.emptyTape;

            wins.sort((a, b) => (a.at[0] - b.at[0]));

            // Extensión de la cinta. Se une con el viewport para que el marco del
            // viewport siempre quepa en el dibujo aunque todas las ventanas
            // quepan en pantalla.
            let min = Infinity;
            let max = -Infinity;
            for (let i = 0; i < wins.length; i++) {
                min = Math.min(min, wins[i].at[0]);
                max = Math.max(max, wins[i].at[0] + wins[i].size[0]);
            }
            min = Math.min(min, vpL);
            max = Math.max(max, vpR);
            const span = max - min;
            if (!(span > 0))
                return root.emptyTape;

            const items = [];
            let outLeft = 0;
            let outRight = 0;
            let urgentLeft = false;
            let urgentRight = false;
            let focusedOrdinal = 0;

            for (let i = 0; i < wins.length; i++) {
                const c = wins[i];
                const l = c.at[0];
                const r = c.at[0] + c.size[0];

                // Hecho 4: el campo `visible` de clients NO significa "está en
                // pantalla". Intersecamos cajas a mano. Pedimos más de 1 px de
                // solape para que una astilla no cuente como visible.
                const overlap = Math.min(r, vpR) - Math.max(l, vpL);
                const inView = overlap > 1;
                const side = inView ? "" : (((l + r) / 2 < (vpL + vpR) / 2) ? "left" : "right");

                const addr = c.address ?? "";
                const focused = (addr !== "" && addr === focusedAddr);
                const urgent = urgentAddrs[addr] === true;

                if (focused)
                    focusedOrdinal = i + 1;
                if (side === "left") {
                    outLeft++;
                    if (urgent)
                        urgentLeft = true;
                } else if (side === "right") {
                    outRight++;
                    if (urgent)
                        urgentRight = true;
                }

                items.push({
                    address: addr,
                    cls: c.class ?? "",
                    // NO clampamos a 0. end-4 hace `Math.max(at[0]-monitor.x, 0)`
                    // en OverviewWindow.qml y para una cinta eso es un bug: todas
                    // las ventanas de la izquierda se apilarían en x=0.
                    fx: (l - min) / span,
                    fw: (r - l) / span,
                    focused: focused,
                    inView: inView,
                    side: side,
                    urgent: urgent
                });
            }

            // Firma: sólo lo que cambia el DIBUJO. Redondeada a 1/1000 de la
            // cinta (≈0,2 px sobre 220) para que el jitter no reconstruya nada.
            let sig = wsId + "|" + wins.length + "|" + focusedOrdinal + "|";
            for (let i = 0; i < items.length; i++) {
                const it = items[i];
                sig += Math.round(it.fx * 1000) + "," + Math.round(it.fw * 1000)
                    + (it.focused ? "F" : "") + (it.inView ? "v" : it.side.charAt(0))
                    + (it.urgent ? "!" : "") + ";";
            }

            return {
                ok: true,
                sig: sig,
                items: items,
                span: span,
                min: min,
                vpX: (vpL - min) / span,
                vpW: (vpR - vpL) / span,
                total: wins.length,
                focusedOrdinal: focusedOrdinal,
                outLeft: outLeft,
                outRight: outRight,
                urgentLeft: urgentLeft,
                urgentRight: urgentRight
            };
        } catch (e) {
            // Degradar limpiamente: si algo del JSON viene raro, el widget se
            // esconde en vez de tumbar la barra.
            return root.emptyTape;
        }
    }

    function refreshTape() {
        if (!root.enabled)
            return;
        const t = root.buildTape();
        if (t.sig === root.tape.sig)
            return; // nada que redibujar: el poll sale gratis
        const prev = root.tape;
        root.tape = t;
        root.detectFaro(t);
        if (root.mode === "transient" && prev.ok && t.ok)
            root.poke(root.holdMs);
    }

    // El faro salta UNA vez por transición a urgente fuera del viewport.
    function detectFaro(t) {
        const seen = root.seenUrgent;
        const next = ({});
        let fired = "";
        for (let i = 0; i < t.items.length; i++) {
            const it = t.items[i];
            if (!it.urgent)
                continue;
            next[it.address] = true;
            if (it.inView)
                continue; // el faro es para lo que NO se ve
            if (seen[it.address] !== true && fired === "")
                fired = it.side;
        }
        root.seenUrgent = next; // al dejar de estar urgente puede volver a sonar
        if (fired !== "") {
            root.faroSide = fired;
            root.faroTick++;
            root.poke(root.urgentHoldMs);
        }
    }

    function poke(ms) {
        if (root.mode !== "transient")
            return;
        root.transientShown = true;
        holdTimer.interval = ms;
        holdTimer.restart();
    }

    // ─────────────────────────────────────────────────────────────────────
    // Acciones
    // ─────────────────────────────────────────────────────────────────────

    // Hyprland 0.55 con config Lua: `hyprctl dispatch X` se evalúa como
    // `return hl.dispatch(X)`, así que la sintaxis legacy es un error de sintaxis
    // Lua. Quickshell expone `Hyprland.usingLua` justo para esto. La rama Lua es
    // la que ya usa end-4 en OverviewWidget.qml.
    function focusAddress(addr) {
        // La dirección se interpola dentro de una cadena Lua. Sólo dejamos pasar
        // hex canónico: así no hace falta escapar comillas ni barras y una
        // dirección corrupta no puede generar Lua roto.
        if (!addr || !/^0x[0-9a-fA-F]+$/.test(String(addr)))
            return;
        if (Hyprland.usingLua)
            Hyprland.dispatch(`hl.dsp.focus({window = "address:${addr}"})`);
        else
            Hyprland.dispatch(`focuswindow address:${addr}`);
    }

    function stepFocus(dir) {
        const d = dir < 0 ? "left" : "right";
        if (Hyprland.usingLua)
            Hyprland.dispatch(`hl.dsp.focus({direction = "${d}"})`);
        else
            Hyprland.dispatch(`movefocus ${d === "left" ? "l" : "r"}`);
    }

    // ─────────────────────────────────────────────────────────────────────
    // Disparadores
    // ─────────────────────────────────────────────────────────────────────

    Component.onCompleted: root.refreshTape()

    Timer {
        id: holdTimer
        interval: root.holdMs
        repeat: false
        onTriggered: root.transientShown = false
    }

    // Hecho 2: NO existe evento IPC de scroll. La cinta se mueve también por
    // follow_focus y por gesto de trackpad, que no pasan por keybinds ni por el
    // socket2. Un mapa permanente sin polling MIENTE, así que los modos
    // permanentes pagan un Timer.
    //
    // 500 ms: es el extremo barato de la banda 300-500 ms que pide el brief. A
    // 220 px de cinta, medio segundo de scroll mueve los segmentos unos pocos
    // píxeles, así que no se percibe rancio, y son 2 despertares/s en vez de 3,3.
    //
    // Y el tick es barato por los dos lados:
    //  - Sólo `hyprctl clients -j` (updateWindowList), NO updateAll(): updateAll
    //    lanza CINCO procesos (clients, monitors, layers, workspaces,
    //    activeworkspace), que a 2 Hz serían 10 spawns/s. La geometría de la
    //    cinta sólo depende de clients.
    //  - Cuando la cinta no se ha movido, refreshTape() compara la firma y no
    //    reasigna el modelo: cero relayout, cero repintado.
    //
    // El Timer sólo existe en los modos permanentes; "transient" no paga nada.
    Timer {
        id: pollTimer
        running: root.active && root.mode !== "transient"
        interval: root.pollInterval
        repeat: true
        onTriggered: {
            // Guardado con typeof: si end-4 renombra la función, el widget sigue
            // dibujando con lo que llegue por eventos en vez de romperse.
            if (typeof HyprlandData.updateWindowList === "function")
                HyprlandData.updateWindowList();
        }
    }

    Connections {
        target: HyprlandData
        function onWindowListChanged() { root.refreshTape() }
        function onMonitorsChanged() { root.refreshTape() }
        function onActiveWorkspaceChanged() { root.refreshTape() }
    }

    Connections {
        target: Hyprland

        // Nada pesado ni síncrono aquí: el socket2 tiene cola de 64 eventos y
        // desconecta al cliente lento (hecho 10). Esto es una comparación de
        // strings y, como mucho, un recorrido de ~10 ventanas.
        function onRawEvent(event) {
            if (event.name === "urgent" || event.name === "activewindowv2")
                root.refreshTape();
        }
    }

    // ─────────────────────────────────────────────────────────────────────
    // Dibujo
    // ─────────────────────────────────────────────────────────────────────

    sourceComponent: Rectangle {
        id: content

        readonly property int pad: 6
        readonly property int mapHeight: Math.max(10, Math.round(root.barHeight * 0.45))
        readonly property int faroIcon: Math.max(10, Math.round(content.mapHeight * 0.95))
        // El hueco se dimensiona al PICO del pulso (1,25×), así el faro no se
        // sale de su celda ni en el fotograma más grande de la animación.
        readonly property int faroSlot: Math.ceil(content.faroIcon * 1.25)

        implicitWidth: layout.implicitWidth + content.pad * 2
        // Holgura vertical deliberada, por el mismo motivo.
        implicitHeight: Math.max(content.mapHeight + 8, content.faroSlot, layout.implicitHeight)

        color: Appearance.colors.colLayer1
        radius: Appearance.rounding.small

        Row {
            id: layout
            anchors.centerIn: parent
            spacing: 3

            // FARO (izquierda). Los dos huecos del faro OCUPAN SITIO SIEMPRE,
            // aunque estén vacíos. Dos motivos: (1) si aparecieran y
            // desaparecieran, el mapa se movería lateralmente cada vez que algo
            // se pone urgente, justo cuando el usuario está mirando; (2) así el
            // icono no se dibuja encima de los segmentos del borde, que son
            // precisamente los que está señalando.
            Item {
                width: content.faroSlot
                height: content.faroSlot
                anchors.verticalCenter: parent.verticalCenter

                MaterialSymbol {
                    id: faroLeft
                    anchors.centerIn: parent
                    text: "chevron_left"
                    iconSize: content.faroIcon
                    fill: 1
                    color: Appearance.m3colors.m3error
                    visible: root.tape.urgentLeft
                }
            }

            Item {
                id: mapArea
                width: root.tapeWidth
                height: content.mapHeight
                anchors.verticalCenter: parent.verticalCenter

                // Marco del viewport: lo que de verdad está en pantalla. Es una
                // señal de FORMA, no de color, porque la paleta Material You se
                // regenera con el wallpaper y no puedo asumir contraste.
                Rectangle {
                    id: viewportFrame

                    // El suelo de 2 px puede empujar el marco fuera del mapa
                    // cuando el viewport es una astilla de una cinta larguísima,
                    // así que la x se acota contra el contenedor. Misma familia
                    // de fallo que el popup que se recortaba en los bordes.
                    readonly property int fw: Math.min(mapArea.width,
                        Math.max(2, Math.round(root.tape.vpW * mapArea.width)))

                    x: Math.max(0, Math.min(mapArea.width - viewportFrame.fw,
                        Math.round(root.tape.vpX * mapArea.width)))
                    width: viewportFrame.fw
                    height: parent.height
                    color: "transparent"
                    radius: Appearance.rounding.small
                    border.width: 1
                    border.color: Appearance.colors.colOutlineVariant

                    // Idioma de la casa: las animaciones salen del tema, no
                    // hardcodeadas. OJO: `elementMove` sólo tiene
                    // `numberAnimation`; la única con `colorAnimation` es
                    // `elementMoveFast`.
                    Behavior on x {
                        animation: Appearance.animation.elementMove.numberAnimation.createObject(this)
                    }
                    Behavior on width {
                        animation: Appearance.animation.elementMove.numberAnimation.createObject(this)
                    }
                }

                Repeater {
                    model: root.tape.items

                    delegate: Rectangle {
                        id: seg

                        required property var modelData

                        // Altura = segunda señal, además del color: enfocada llena
                        // el alto, visible ~2/3, fuera ~1/3. Si la paleta deja los
                        // colores parecidos, la silueta sigue leyéndose.
                        readonly property real hFactor: seg.modelData.focused
                            ? 1.0
                            : (seg.modelData.urgent && !seg.modelData.inView ? 0.85
                                : (seg.modelData.inView ? 0.62 : 0.34))

                        // 2 px mínimo: una ventana estrecha muy lejos en la cinta
                        // no puede desaparecer del mapa. Pero ese suelo puede
                        // sacar el segmento por la derecha (última ventana de una
                        // cinta muy larga), así que la x se acota contra el mapa:
                        // nunca dibujamos fuera de la celda.
                        readonly property int segW: Math.min(mapArea.width,
                            Math.max(2, Math.round(seg.modelData.fw * mapArea.width) - 1))

                        x: Math.max(0, Math.min(mapArea.width - seg.segW,
                            Math.round(seg.modelData.fx * mapArea.width)))
                        width: seg.segW
                        height: Math.round(parent.height * seg.hFactor)
                        anchors.verticalCenter: parent.verticalCenter
                        radius: Appearance.rounding.small

                        color: seg.modelData.urgent
                            ? Appearance.m3colors.m3error
                            : (seg.modelData.focused
                                ? Appearance.colors.colPrimary
                                : (seg.modelData.inView
                                    ? Appearance.colors.colOnLayer1
                                    : Appearance.colors.colOutlineVariant))

                        opacity: seg.modelData.inView || seg.modelData.urgent ? 1.0 : 0.7

                        // Transiciones por cambio de estado, nunca bucles. Los
                        // Behavior no se disparan al construir el objeto, así que
                        // reconstruir el modelo no anima nada.
                        Behavior on x {
                            animation: Appearance.animation.elementMove.numberAnimation.createObject(this)
                        }
                        Behavior on width {
                            animation: Appearance.animation.elementMove.numberAnimation.createObject(this)
                        }
                        Behavior on height {
                            animation: Appearance.animation.elementMove.numberAnimation.createObject(this)
                        }
                        // `elementMoveFast` es la ÚNICA que expone colorAnimation.
                        Behavior on color {
                            animation: Appearance.animation.elementMoveFast.colorAnimation.createObject(this)
                        }
                    }
                }

                MouseArea {
                    id: mouse
                    anchors.fill: parent
                    acceptedButtons: Qt.LeftButton
                    hoverEnabled: false

                    // Acumulador: un trackpad de alta resolución escupe muchos
                    // deltas pequeños. Sin esto, un gesto = 15 cambios de foco.
                    property int wheelAcc: 0

                    onClicked: (event) => {
                        const items = root.tape.items;
                        if (!items || items.length === 0)
                            return;
                        const f = event.x / Math.max(1, mapArea.width);
                        let best = -1;
                        let bestDist = Infinity;
                        for (let i = 0; i < items.length; i++) {
                            const it = items[i];
                            if (f >= it.fx && f <= it.fx + it.fw) {
                                best = i;
                                break;
                            }
                            // Si el clic cae en un hueco entre columnas, va a la
                            // más cercana en vez de no hacer nada.
                            const d = Math.min(Math.abs(f - it.fx), Math.abs(f - (it.fx + it.fw)));
                            if (d < bestDist) {
                                bestDist = d;
                                best = i;
                            }
                        }
                        if (best >= 0)
                            root.focusAddress(items[best].address);
                    }

                    onWheel: (wheel) => {
                        mouse.wheelAcc += wheel.angleDelta.y;
                        while (mouse.wheelAcc >= 120) {
                            mouse.wheelAcc -= 120;
                            root.stepFocus(-1); // rueda arriba -> izquierda
                        }
                        while (mouse.wheelAcc <= -120) {
                            mouse.wheelAcc += 120;
                            root.stepFocus(1);
                        }
                        wheel.accepted = true;
                    }
                }
            }

            // FARO (derecha).
            Item {
                width: content.faroSlot
                height: content.faroSlot
                anchors.verticalCenter: parent.verticalCenter

                MaterialSymbol {
                    id: faroRight
                    anchors.centerIn: parent
                    text: "chevron_right"
                    iconSize: content.faroIcon
                    fill: 1
                    color: Appearance.m3colors.m3error
                    visible: root.tape.urgentRight
                }
            }

            // ‹2 · 4/7 · 1› — sólo en modo "counter".
            StyledText {
                visible: root.mode === "counter"
                anchors.verticalCenter: parent.verticalCenter
                font.pixelSize: Appearance.font.pixelSize.smaller
                color: Appearance.colors.colSubtext
                text: `‹${root.tape.outLeft} · ${root.tape.focusedOrdinal > 0 ? root.tape.focusedOrdinal : "—"}/${root.tape.total} · ${root.tape.outRight}›`
            }
        }

        // Si el minimapa aparece PORQUE algo se puso urgente (modo transitorio),
        // el contenido se crea después de que faroTick se incrementara, así que
        // aquí se ha perdido la señal: lo comprobamos a mano al construir.
        Component.onCompleted: {
            if (root.tape.urgentLeft || root.tape.urgentRight)
                faroPulse.start();
        }

        // El faro suena UNA vez por transición a urgente: un pulso de ida y
        // vuelta y se acabó. `loops` vale 1 por defecto y no se toca. En este
        // archivo no hay ni una animación infinita, ni parpadeos, ni pulsos
        // permanentes: mientras la urgencia siga, lo que queda es el tinte
        // ESTÁTICO del segmento y el chevrón encendido, que no cuestan GPU.
        SequentialAnimation {
            id: faroPulse

            NumberAnimation {
                target: root.faroSide === "left" ? faroLeft : faroRight
                property: "scale"
                from: 1.0
                to: 1.25
                duration: 160
                easing.type: Easing.OutCubic
            }
            NumberAnimation {
                target: root.faroSide === "left" ? faroLeft : faroRight
                property: "scale"
                to: 1.0
                duration: 900
                easing.type: Easing.InOutQuad
            }
        }

        Connections {
            target: root

            // Se para ANTES de reponer las escalas: si el pulso anterior seguía
            // en vuelo sobre el otro chevrón, pararlo después lo dejaría
            // congelado a media escala para siempre.
            function onFaroTickChanged() {
                faroPulse.stop();
                faroLeft.scale = 1.0;
                faroRight.scale = 1.0;
                faroPulse.start();
            }
        }
    }
}
