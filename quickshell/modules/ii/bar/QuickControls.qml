pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Shapes
import QtQuick.Layouts
import Quickshell
import qs.services
import qs.modules.common
import qs.modules.common.widgets

/**
 * QuickControls — brillo y volumen en la barra.
 *
 * En reposo: icono con un arco de 270 grados alrededor (hueco abajo) que marca el nivel.
 * Al hover:  el arco se desvanece y la capsula se estira en un slider horizontal M3
 *            Expressive (via + manija-barra de extremos redondeados).
 * Rueda:     +/-5 % siempre, expandido o no. Es el gesto principal.
 * Clic:      sobre el icono de volumen silencia (el icono pasa a tachado).
 *
 * REGLA DURA: "las capsulas crecen hacia el vacio, nunca empujan a las vecinas".
 * Aqui se cumple por construccion: el implicitWidth de este componente NO depende
 * del hover. Es siempre controlSize por control disponible. La expansion la dibuja
 * una capsula hija que se sale de los limites del Item (QML no recorta por defecto)
 * hacia el lado indicado por expandDirection. Como el implicitWidth no cambia, el
 * RowLayout/GridLayout que lo contiene no vuelve a repartir espacio: ni un pixel se
 * mueve en la barra. Ver la nota al final para donde colocarlo (hace falta ~135 px
 * de barra libre del lado de expansion).
 *
 * SEGUNDA REGLA DURA: nada se sale de la pantalla. El bug conocido de
 * StyledPopup.qml (centrar sin acotar -> x negativo -> recorte contra el borde)
 * tiene aqui su equivalente: una capsula que crece hacia el borde. Se evita
 * midiendo el hueco real a cada lado dentro de la ventana de la barra
 * (measureRoom) y (a) eligiendo el sentido que cabe, (b) recortando la anchura
 * al hueco disponible si no cabe entera por ninguno. expandDirection es una
 * PREFERENCIA, no una imposicion. Ademas no hay OSD ni tooltip flotante: el
 * porcentaje se dibuja DENTRO de la capsula ya acotada, asi que no hay un
 * segundo elemento que se pueda recortar por su cuenta.
 * Tampoco se usa layer.enabled en ningun sitio: renderiza a una textura del
 * tamaño exacto del elemento y cortaria lo que se dibuje fuera.
 *
 * Fuentes consultadas / adaptadas:
 * - Arco con Shape+PathAngleArc: tecnica tomada de end-4
 *   modules/common/widgets/CircularProgress.qml (no se reutiliza ese widget porque su
 *   hueco es simetrico alrededor del inicio y no permite un barrido fijo de 270 grados
 *   con hueco abajo).
 * - Geometria de la manija y de la via (handleWidth 3-4, handleMargins 4, radios
 *   interiores "unsharpen"): end-4 modules/common/widgets/StyledSlider.qml.
 * - Mapeo icono/valor y uso de monitor.setBrightness(): end-4
 *   modules/ii/sidebarRight/QuickSliders.qml.
 * - Idea del anillo alrededor del icono en la barra: corecathx/whisker
 *   modules/bar/CircularProgress.qml (allí es Canvas; aquí Shape, que no repinta en CPU).
 */
Item {
    id: root

    Layout.alignment: Qt.AlignVCenter

    // ─────────────────────────────────────────────────────────────────────
    // Config. Config.options es un JsonAdapter con propiedades declaradas
    // ESTATICAMENTE: una clave que no este en Config.qml vale undefined para
    // siempre, aunque el usuario la escriba en config.json. Por eso `enable`
    // cae a false: opt-in de verdad. HAY QUE INSERTAR EL BLOQUE DE Config.qml
    // QUE VA EN LA NOTA o el widget no aparece nunca (esa es la intencion:
    // fallo visible y aislado, no una barra rota).
    // El resto de claves son afinado opcional y no hace falta declararlas.
    // ─────────────────────────────────────────────────────────────────────
    readonly property var opts: Config.options?.bar.quickControls ?? null
    readonly property bool cfgEnable: root.opts?.enable ?? false
    readonly property bool cfgShowBrightness: root.opts?.showBrightness ?? true
    readonly property bool cfgShowVolume: root.opts?.showVolume ?? true
    readonly property int cfgStepPercent: root.opts?.stepPercent ?? 5
    readonly property int cfgExpandedWidth: root.opts?.expandedWidth ?? 168
    readonly property string cfgExpandDirection: root.opts?.expandDirection ?? "left"
    readonly property int cfgExpandDelay: root.opts?.expandDelay ?? 140
    readonly property int cfgCollapseDelay: root.opts?.collapseDelay ?? 220
    // Escrituras DDC/CI: agrupacion. Ver el comentario largo en requestValue().
    readonly property int cfgDdcTrailingMs: root.opts?.ddcTrailingMs ?? 180
    readonly property int cfgDdcMinIntervalMs: root.opts?.ddcMinIntervalMs ?? 400

    // ─────────────────────────────────────────────────────────────────────
    // Geometria (px). Nada de esto depende del estado de hover salvo la
    // anchura de la capsula, que es un hijo y no afecta al implicitWidth.
    // ─────────────────────────────────────────────────────────────────────
    readonly property real controlSize: 32
    readonly property real controlSpacing: 2
    readonly property real capsuleHeight: 30
    readonly property real pad: 5
    readonly property real iconBox: 22
    readonly property real gap: 6
    readonly property real pctBox: 32
    readonly property real arcSize: 26
    readonly property real arcWidth: 2.5
    readonly property real arcRadius: root.arcSize / 2 - root.arcWidth / 2
    readonly property real iconSize: 16
    readonly property real trackHeight: 12
    readonly property real handleWidth: 4
    readonly property real handleHeight: 22
    readonly property real handleGap: 4
    readonly property real handleInset: 4
    // Lo que ocupan icono + porcentaje + separaciones; el resto es via.
    readonly property real chromeWidth: root.pad * 2 + root.iconBox + root.pctBox + root.gap * 2
    readonly property real step: Math.max(1, root.cfgStepPercent) / 100
    // Qt entrega angleDelta en octavos de grado: 120 = una muesca de rueda clasica.
    readonly property real wheelNotch: 120

    // ─────────────────────────────────────────────────────────────────────
    // Acotado contra los bordes. Hueco real a cada lado DENTRO de la ventana
    // de la barra. Se mide en el momento de expandir (una llamada a mapToItem,
    // nada de bindings sobre posiciones que la barra recoloca sola).
    // ─────────────────────────────────────────────────────────────────────
    property real leftRoom: 0
    property real rightRoom: 0

    function measureRoom(): void {
        const win = root.QsWindow.window;
        if (!win || root.width <= 0) {
            root.leftRoom = 0;
            root.rightRoom = 0;
            return;
        }
        const p = root.mapToItem(null, 0, 0);   // null = coordenadas de escena
        root.leftRoom = Math.max(0, p.x);
        root.rightRoom = Math.max(0, win.width - (p.x + root.width));
    }

    // Peor caso entre los dos controles: la capsula se ancla al borde de origen
    // del control, y el que menos margen tiene deja controlSize de colchon.
    // Usar el minimo hace que ambos controles se expandan igual (misma
    // gramatica) y garantiza que ninguno se sale.
    readonly property real leftCapacity: root.leftRoom + root.controlSize
    readonly property real rightCapacity: root.rightRoom + root.controlSize
    readonly property real wantedWidth: Math.max(root.chromeWidth + 40, root.cfgExpandedWidth)

    // expandDirection es PREFERENCIA. Si por ese lado no cabe entera y por el
    // otro si, se da la vuelta. Si no cabe por ninguno, gana el lado con mas
    // hueco y la anchura se recorta a lo que haya.
    readonly property bool mirrored: {
        const capL = root.leftCapacity;
        const capR = root.rightCapacity;
        if (root.cfgExpandDirection === "left")
            return capL >= root.wantedWidth || capL >= capR;
        return !(capR >= root.wantedWidth || capR >= capL);
    }
    readonly property real expandedWidth: Math.max(root.controlSize, Math.min(root.wantedWidth, root.mirrored ? root.leftCapacity : root.rightCapacity))
    // Si ni recortando queda sitio para algo usable, no se expande: el arco y
    // la rueda siguen funcionando, que es el 90 % del uso.
    readonly property bool canExpand: root.expandedWidth >= root.controlSize + 24

    onWidthChanged: root.measureRoom()
    Component.onCompleted: root.measureRoom()

    // ─────────────────────────────────────────────────────────────────────
    // Fuentes de datos. Si faltan, el control correspondiente desaparece solo
    // y el otro sigue funcionando; si faltan las dos, desaparece el widget
    // entero sin tocar el resto de la barra.
    // ─────────────────────────────────────────────────────────────────────
    readonly property var screen: root.QsWindow.window?.screen ?? null
    readonly property var brightnessMonitor: {
        // Se USA Brightness.monitors (no solo se lee) para que el binding
        // dependa de el: getMonitorForScreen() es una funcion y por si sola no
        // notifica cuando cambia el conjunto de pantallas.
        const mons = Brightness.monitors;
        if (!mons || mons.length === 0)
            return null;
        return Brightness.getMonitorForScreen(root.screen) ?? null;
    }
    readonly property bool brightnessAvailable: root.cfgShowBrightness && root.brightnessMonitor !== null && (root.brightnessMonitor?.ready ?? false)
    readonly property bool volumeAvailable: root.cfgShowVolume && Audio.ready && (Audio.sink?.audio ?? null) !== null

    // Tope de volumen. Si la proteccion de end-4 esta activa, escribir por encima
    // de maxAllowed hace que Audio.qml revierta el cambio y emita
    // sinkProtectionTriggered; mejor no llegar a provocarlo. El paso de 5 % queda
    // siempre por debajo de maxAllowedIncrease (10 por defecto), asi que el otro
    // guardia de la proteccion no salta.
    // audio.protection SI esta declarado en Config.qml, asi que aqui el ?. solo
    // cubre el arranque (options aun sin poblar), no una clave inexistente.
    readonly property real volumeCeiling: (Config.options?.audio.protection.enable ?? false) ? Math.max(0, Math.min(1, (Config.options?.audio.protection.maxAllowed ?? 100) / 100)) : 1

    readonly property int availableCount: (root.brightnessAvailable ? 1 : 0) + (root.volumeAvailable ? 1 : 0)

    visible: root.cfgEnable && root.availableCount > 0
    // IMPORTANTE: solo depende de CUANTOS controles hay datos, nunca del hover.
    implicitWidth: root.visible ? (root.availableCount * root.controlSize + Math.max(0, root.availableCount - 1) * root.controlSpacing) : 0
    implicitHeight: Appearance.sizes.baseBarHeight
    // Los hermanos de la barra se pintan por orden de declaracion. Al expandirse
    // la capsula se sale de la celda, asi que hay que subirla por encima de
    // ellos; plegado vuelve a z 0 para no alterar nada.
    z: root.expandedIndex >= 0 ? 10 : 0

    // ─────────────────────────────────────────────────────────────────────
    // Estado de expansion. Solo uno abierto a la vez.
    // Histeresis: abre tras cfgExpandDelay (para no dispararse al cruzar la
    // barra de paso) y cierra tras cfgCollapseDelay (para no parpadear al pasar
    // por encima de una costura). Los dos Timer son de un disparo y solo corren
    // durante la transicion: no hay polling ni animaciones infinitas.
    // ─────────────────────────────────────────────────────────────────────
    property int hoveredIndex: -1
    property int expandedIndex: -1

    onHoveredIndexChanged: {
        if (root.hoveredIndex >= 0) {
            collapseTimer.stop();
            // Se remide justo antes de decidir: la barra recoloca sus secciones
            // (titulo de ventana, bandeja, clima...) y el hueco de hace un rato
            // puede ya no estar.
            root.measureRoom();
            if (!root.canExpand)
                return;
            if (root.expandedIndex >= 0) {
                // Ya hay uno abierto: cambiar de control es inmediato.
                expandTimer.stop();
                root.expandedIndex = root.hoveredIndex;
            } else {
                expandTimer.restart();
            }
        } else {
            expandTimer.stop();
            collapseTimer.restart();
        }
    }

    Timer {
        id: expandTimer
        interval: root.cfgExpandDelay
        repeat: false
        onTriggered: {
            if (root.hoveredIndex >= 0 && root.canExpand)
                root.expandedIndex = root.hoveredIndex;
        }
    }

    Timer {
        id: collapseTimer
        interval: root.cfgCollapseDelay
        repeat: false
        onTriggered: {
            if (root.hoveredIndex < 0)
                root.expandedIndex = -1;
        }
    }

    // Si cambia el monitor (reconfiguracion de pantallas) se tira el valor
    // pendiente: pertenecia a otro dispositivo. Llamada opcional porque este
    // handler puede dispararse antes de que el hijo exista.
    onBrightnessMonitorChanged: brightnessControl?.discardPending()

    // Si una fuente desaparece o vuelve (sink de Pipewire, monitor), se pliega
    // todo: si no, quedaria un expandedIndex apuntando a un control invisible,
    // tapando al otro y dejando el z elevado.
    onAvailableCountChanged: {
        root.hoveredIndex = -1;
        root.expandedIndex = -1;
        expandTimer.stop();
        collapseTimer.stop();
    }

    // ─────────────────────────────────────────────────────────────────────
    // Un solo control, la misma anatomia para brillo y volumen. Lo unico que
    // cambia entre los dos es roleColor (colPrimary vs colSecondaryContainer)
    // y el icono. El color es la señal rapida; el icono y la posicion son la
    // señal redundante que exige el brief cuando la paleta no garantiza
    // contraste entre dos roles.
    // ─────────────────────────────────────────────────────────────────────
    component QuickControl: Item {
        id: ctl

        property int index: 0
        property string iconName: ""
        property color roleColor: Appearance.colors.colPrimary
        property real sourceValue: 0        // valor real de la fuente (0..1)
        property bool muted: false
        property bool iconTogglesMute: false
        property bool coalesce: false       // true -> agrupar escrituras (DDC)

        signal commit(real value)           // escribe de verdad en el hardware
        signal iconActivated()

        // Valor mostrado. Mientras hay una escritura DDC pendiente mandamos
        // nosotros, para que la UI responda al instante aunque el bus i2c vaya
        // cientos de ms por detras. pending < 0 significa "no hay pendiente".
        property real pending: -1
        property real displayValue: ctl.pending >= 0 ? ctl.pending : Math.max(0, Math.min(1, ctl.sourceValue))
        property bool dragging: false
        property real lastCommitMs: 0
        // Acumulador de rueda. Un trackpad de alta resolucion manda rafagas de
        // deltas pequeños; actuar en cada evento (que es lo que hace el
        // FocusedScrollMouseArea de end-4) llevaria del 20 % al 100 % de un
        // gesto. Se acumula hasta completar muescas de 120.
        property real wheelAcc: 0

        readonly property bool expanded: root.expandedIndex === ctl.index
        // Un control queda tapado si la capsula expandida de otro se le echa
        // encima; eso depende del sentido de expansion, no del indice a secas.
        readonly property bool covered: root.expandedIndex >= 0 && root.expandedIndex !== ctl.index && (root.mirrored ? ctl.index < root.expandedIndex : ctl.index > root.expandedIndex)
        readonly property color activeColor: ctl.muted ? Appearance.colors.colSubtext : ctl.roleColor

        implicitWidth: root.controlSize     // CONSTANTE: aqui vive la regla dura
        height: root.height
        z: ctl.expanded ? 2 : 0
        opacity: ctl.covered ? 0 : 1
        enabled: !ctl.covered

        Behavior on opacity {
            NumberAnimation {
                duration: Appearance.animation.elementMoveFast.duration
                easing.type: Appearance.animation.elementMoveFast.type
                easing.bezierCurve: Appearance.animation.elementMoveFast.bezierCurve
            }
        }

        Behavior on displayValue {
            // Arrastrando NO se anima: la manija tiene que ir pegada al dedo.
            // Con la rueda si, para que el salto de 5 % se lea como movimiento.
            enabled: !ctl.dragging
            // Sin alwaysRunToEnd: con la rueda llegan muchos objetivos seguidos
            // y esta animacion tiene que poder reapuntar sin encolarse.
            NumberAnimation {
                duration: Appearance.animation.elementMoveFast.duration
                easing.type: Appearance.animation.elementMoveFast.type
                easing.bezierCurve: Appearance.animation.elementMoveFast.bezierCurve
            }
        }

        function discardPending(): void {
            ctl.pending = -1;
            ddcTimer.stop();
        }

        function flush(): void {
            ddcTimer.stop();
            if (ctl.pending < 0)
                return;
            const v = ctl.pending;
            ctl.pending = -1;
            ctl.lastCommitMs = Date.now();
            ctl.commit(v);
        }

        // Punto unico de entrada: rueda, arrastre y clic pasan por aqui.
        function requestValue(v: real): void {
            v = Math.max(0, Math.min(1, v));
            if (!ctl.coalesce) {
                // Backlight interno (brightnessctl) o Pipewire: escribir en
                // cada evento es barato, se escribe y punto.
                ctl.pending = -1;
                ctl.lastCommitMs = Date.now();
                ctl.commit(v);
                return;
            }
            // DDC/CI: cada setvcp son cientos de ms sobre i2c. Se agrupa con un
            // hibrido de flanco de entrada + cola: la primera escritura sale ya
            // (respuesta inmediata), las siguientes esperan a que haya pasado
            // cfgDdcMinIntervalMs, y el ultimo valor siempre acaba escrito por
            // el temporizador de cola. Un debounce puro de solo cola no escribe
            // nada mientras el usuario siga arrastrando; este si acota el ritmo
            // (~2,5 escrituras/s como mucho) sin quedarse mudo.
            ctl.pending = v;
            if (Date.now() - ctl.lastCommitMs >= root.cfgDdcMinIntervalMs)
                ctl.flush();
            else
                ddcTimer.restart();
        }

        Timer {
            id: ddcTimer
            interval: root.cfgDdcTrailingMs
            repeat: false
            onTriggered: ctl.flush()
        }

        Rectangle {
            id: capsule

            // Al expandirse el borde de origen queda clavado: para "left" es el
            // derecho, para "right" el izquierdo. Asi el icono no salta.
            width: ctl.expanded ? root.expandedWidth : root.controlSize
            height: root.capsuleHeight
            x: root.mirrored ? (root.controlSize - width) : 0
            anchors.verticalCenter: parent.verticalCenter
            radius: Appearance.rounding.full
            color: ctl.expanded ? Appearance.colors.colLayer2 : (controlMouseArea.containsMouse ? Appearance.colors.colLayer1Hover : "transparent")

            readonly property real expandProgress: (capsule.width - root.controlSize) / Math.max(1, root.expandedWidth - root.controlSize)
            readonly property real trackX: root.mirrored ? (root.pad + root.pctBox + root.gap) : (root.pad + root.iconBox + root.gap)
            readonly property real trackW: Math.max(0, capsule.width - root.chromeWidth)
            readonly property real handleCenter: capsule.trackX + root.handleInset + Math.max(0, capsule.trackW - root.handleInset * 2) * ctl.displayValue

            Behavior on width {
                NumberAnimation {
                    duration: Appearance.animation.elementMove.duration
                    easing.type: Appearance.animation.elementMove.type
                    easing.bezierCurve: Appearance.animation.elementMove.bezierCurve
                }
            }

            // Ranura del icono: anclada al borde de origen, es lo unico que no
            // se mueve entre estados.
            Item {
                id: iconSlot
                width: root.iconBox
                height: parent.height
                anchors {
                    verticalCenter: parent.verticalCenter
                    left: root.mirrored ? undefined : parent.left
                    right: root.mirrored ? parent.right : undefined
                    leftMargin: root.mirrored ? 0 : (root.controlSize - root.iconBox) / 2
                    rightMargin: root.mirrored ? (root.controlSize - root.iconBox) / 2 : 0
                }
            }

            // Arco de 270 grados con el hueco abajo. En Qt los angulos de
            // PathAngleArc van en grados y en sentido horario desde las 3 en
            // punto: empezar en 135 y barrer 270 deja el hueco centrado en 90
            // (abajo). Mismo criterio que CircularProgress.qml de end-4.
            Shape {
                id: arcShape
                anchors.centerIn: iconSlot
                width: root.arcSize
                height: root.arcSize
                opacity: 1 - capsule.expandProgress
                visible: arcShape.opacity > 0.01
                preferredRendererType: Shape.CurveRenderer

                ShapePath {
                    strokeColor: Appearance.colors.colOutlineVariant
                    strokeWidth: root.arcWidth
                    capStyle: ShapePath.RoundCap
                    fillColor: "transparent"
                    PathAngleArc {
                        centerX: root.arcSize / 2
                        centerY: root.arcSize / 2
                        radiusX: root.arcRadius
                        radiusY: root.arcRadius
                        startAngle: 135
                        sweepAngle: 270
                    }
                }
                ShapePath {
                    // A valor 0 el RoundCap dejaria un punto suelto; se oculta.
                    strokeColor: ctl.displayValue < 0.005 ? "transparent" : ctl.activeColor
                    strokeWidth: root.arcWidth
                    capStyle: ShapePath.RoundCap
                    fillColor: "transparent"
                    PathAngleArc {
                        centerX: root.arcSize / 2
                        centerY: root.arcSize / 2
                        radiusX: root.arcRadius
                        radiusY: root.arcRadius
                        startAngle: 135
                        sweepAngle: 270 * ctl.displayValue
                    }
                }
            }

            // Via: dos tramos con hueco a ambos lados de la manija, como en
            // StyledSlider. El relleno va siempre de izquierda a derecha en los
            // dos controles y en los dos sentidos de expansion, para que "mas a
            // la derecha = mas" no dependa de donde se haya colocado el widget.
            Rectangle {
                id: fillLeft
                x: capsule.trackX
                width: Math.max(0, capsule.handleCenter - root.handleWidth / 2 - root.handleGap - capsule.trackX)
                height: root.trackHeight
                anchors.verticalCenter: parent.verticalCenter
                color: ctl.activeColor
                topLeftRadius: Appearance.rounding.full
                bottomLeftRadius: Appearance.rounding.full
                topRightRadius: Appearance.rounding.unsharpen
                bottomRightRadius: Appearance.rounding.unsharpen
                opacity: capsule.expandProgress
                visible: fillLeft.opacity > 0.01 && fillLeft.width > 0
            }

            Rectangle {
                id: fillRight
                x: capsule.handleCenter + root.handleWidth / 2 + root.handleGap
                width: Math.max(0, capsule.trackX + capsule.trackW - fillRight.x)
                height: root.trackHeight
                anchors.verticalCenter: parent.verticalCenter
                color: Appearance.colors.colOutlineVariant
                topLeftRadius: Appearance.rounding.unsharpen
                bottomLeftRadius: Appearance.rounding.unsharpen
                topRightRadius: Appearance.rounding.full
                bottomRightRadius: Appearance.rounding.full
                opacity: capsule.expandProgress
                visible: fillRight.opacity > 0.01 && fillRight.width > 0
            }

            // Manija-barra de extremos redondeados (M3 Expressive), no un circulo.
            Rectangle {
                id: handle
                x: capsule.handleCenter - root.handleWidth / 2
                width: root.handleWidth
                height: root.handleHeight
                anchors.verticalCenter: parent.verticalCenter
                radius: Appearance.rounding.full
                color: ctl.activeColor
                opacity: capsule.expandProgress
                visible: handle.opacity > 0.01
            }

            StyledText {
                id: pctLabel
                x: root.mirrored ? root.pad : (capsule.width - root.pad - root.pctBox)
                width: root.pctBox
                anchors.verticalCenter: parent.verticalCenter
                horizontalAlignment: Text.AlignHCenter
                text: `${Math.round(ctl.displayValue * 100)}%`
                font.pixelSize: Appearance.font.pixelSize.smaller
                color: ctl.muted ? Appearance.colors.colSubtext : Appearance.colors.colOnLayer0
                opacity: capsule.expandProgress
                visible: pctLabel.opacity > 0.01
            }

            MaterialSymbol {
                anchors.centerIn: iconSlot
                text: ctl.iconName
                iconSize: root.iconSize
                // fill fijo a proposito: MaterialSymbol anima `fill` remapeando
                // ejes variables de la fuente y end-4 lo marca como "leaky" en
                // su propio codigo. En un elemento que se pasa el dia entrando y
                // saliendo de hover no compensa.
                fill: 0
                color: ctl.muted ? Appearance.colors.colSubtext : Appearance.colors.colOnLayer0
            }

            MouseArea {
                id: controlMouseArea
                anchors.fill: parent
                hoverEnabled: true
                acceptedButtons: Qt.LeftButton
                // Necesario para arrastrar dentro del MouseArea grande que
                // end-4 pone en cada mitad de la barra.
                preventStealing: true
                cursorShape: Qt.PointingHandCursor

                // El icono es el blanco estable: sirve de boton en los dos
                // estados. Plegado, toda la capsula es el icono.
                function pointInIcon(mx: real): bool {
                    if (!ctl.expanded)
                        return true;
                    return mx >= iconSlot.x && mx <= iconSlot.x + iconSlot.width;
                }

                function valueFromX(mx: real): real {
                    const travel = Math.max(1, capsule.trackW - root.handleInset * 2);
                    return (mx - capsule.trackX - root.handleInset) / travel;
                }

                onEntered: {
                    ctl.wheelAcc = 0;   // no arrastrar muescas a medias de la visita anterior
                    root.hoveredIndex = ctl.index;
                }
                onExited: {
                    ctl.wheelAcc = 0;
                    // Durante un arrastre el puntero puede salirse; no se cierra.
                    if (ctl.dragging)
                        return;
                    if (root.hoveredIndex === ctl.index)
                        root.hoveredIndex = -1;
                }

                onWheel: event => {
                    // Se consume SIEMPRE: si no, el FocusedScrollMouseArea de
                    // end-4 que envuelve media barra aplicaria ademas su propio
                    // paso (sin acumular) y el salto seria del doble.
                    event.accepted = true;
                    const d = event.angleDelta.y;
                    if (d === 0)
                        return;
                    // Al cambiar de sentido se tira lo acumulado: invertir tiene
                    // que responder ya, no gastar primero el resto anterior.
                    if (ctl.wheelAcc !== 0 && (d > 0) !== (ctl.wheelAcc > 0))
                        ctl.wheelAcc = 0;
                    ctl.wheelAcc += d;
                    const notches = Math.trunc(ctl.wheelAcc / root.wheelNotch);
                    if (notches === 0)
                        return;
                    ctl.wheelAcc -= notches * root.wheelNotch;
                    ctl.requestValue(ctl.displayValue + notches * root.step);
                }

                onPressed: event => {
                    if (controlMouseArea.pointInIcon(event.x)) {
                        if (ctl.iconTogglesMute)
                            ctl.iconActivated();
                        return;
                    }
                    if (!ctl.expanded)
                        return;
                    ctl.dragging = true;
                    ctl.requestValue(controlMouseArea.valueFromX(event.x));
                }

                onPositionChanged: event => {
                    if (ctl.dragging)
                        ctl.requestValue(controlMouseArea.valueFromX(event.x));
                }

                onReleased: {
                    if (ctl.dragging) {
                        ctl.dragging = false;
                        ctl.flush();    // que el ultimo valor llegue al hardware
                    }
                    if (!controlMouseArea.containsMouse && root.hoveredIndex === ctl.index)
                        root.hoveredIndex = -1;
                }

                onCanceled: {
                    if (ctl.dragging) {
                        ctl.dragging = false;
                        ctl.flush();
                    }
                }
            }
        }
    }

    Row {
        id: controlRow
        anchors.fill: parent
        spacing: root.controlSpacing

        QuickControl {
            id: brightnessControl
            index: 0
            visible: root.brightnessAvailable
            iconName: "light_mode"
            roleColor: Appearance.colors.colPrimary
            sourceValue: root.brightnessMonitor?.brightness ?? 0
            // Solo se agrupa si el monitor va por DDC/CI. En el portatil
            // (backlight interno via brightnessctl) escribe directo.
            coalesce: root.brightnessMonitor?.isDdc ?? false
            onCommit: value => root.brightnessMonitor?.setBrightness(value)
        }

        QuickControl {
            id: volumeControl
            index: 1
            visible: root.volumeAvailable
            iconName: volumeControl.muted ? "volume_off" : "volume_up"
            roleColor: Appearance.colors.colSecondaryContainer
            sourceValue: Audio.value
            muted: Audio.sink?.audio?.muted ?? false
            iconTogglesMute: true
            coalesce: false
            onCommit: value => {
                if (Audio.sink?.audio)
                    Audio.sink.audio.volume = Math.min(value, root.volumeCeiling);
            }
            onIconActivated: Audio.toggleMute()
        }
    }
}
