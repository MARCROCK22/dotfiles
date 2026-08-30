import qs.modules.ii.bar.weather
import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Services.UPower
import qs
import qs.services
import qs.modules.common
import qs.modules.common.widgets
import qs.modules.common.functions

/**
 * Diseño 11 — Islas sobre banda.
 *
 * La barra es una banda sólida de borde a borde y encima flotan los grupos como
 * píldoras rellenas, un punto más claras que la banda y SIN contorno.
 *
 * Los tres valores salen de medir el diseño de referencia, no de estimarlos:
 * banda rgb(26,27,29), píldora rgb(40,40,40), y en el corte del borde de una
 * píldora se pasa del fondo al relleno en un solo píxel de suavizado — o sea,
 * no hay anillo de contorno.
 *
 * La banda pide `bar.cornerStyle` a 0: con 1 se dibuja con los márgenes de
 * Hyprland y esquinas redondeadas, que es un rectángulo flotante con borde, y
 * la referencia llega hasta x=0 sin margen.
 *
 * Reparto pedido:
 *   izquierda  RAM / GPU / swap en anillos + multimedia
 *   centro     espacios de trabajo + clima
 *   derecha    hora con día, utilidades, teclado, batería, red y sesión
 *
 * Todo lo que no sean los espacios de trabajo tiene detalle al pasar el ratón.
 * El de multimedia además se puede TOCAR: controles, búsqueda y
 * volumen. Los espacios de trabajo se quedan sin popup a propósito.
 *
 * La franja de la ventana enfocada (ActiveWindow) se conserva aunque no
 * estuviera en la lista: quitarla sería perder algo que ya tenías.
 */
Item { // Bar content region
    id: root

    property var screen: root.QsWindow.window?.screen
    property var brightnessMonitor: Brightness.getMonitorForScreen(screen)
    property real useShortenedForm: (Appearance.sizes.barHellaShortenScreenWidthThreshold >= screen?.width) ? 2 : (Appearance.sizes.barShortenScreenWidthThreshold >= screen?.width) ? 1 : 0
    readonly property int centerSideModuleWidth: (useShortenedForm == 2) ? Appearance.sizes.barCenterSideModuleWidthHellaShortened : (useShortenedForm == 1) ? Appearance.sizes.barCenterSideModuleWidthShortened : Appearance.sizes.barCenterSideModuleWidth

    // Ajustes comunes a todas las islas, en un solo sitio para que no deriven.
    // colLayer0 es el color de la BANDA: con él las píldoras se fundirían con
    // ella. Y colLayer1 a pelo salta +70 en vez del +14 de la referencia,
    // porque su valor crudo está pensado para componerse con alfa
    // (`solveOverlayColor`) y opacarlo tal cual lo deja mucho más claro.
    // El 0.8 mezcla 80% banda + 20% colLayer1 y reproduce ese +14.
    // `applyAlpha(...,1)` porque `appearance.transparency` deja la paleta con
    // alfa, y sin eso el fondo de pantalla se cuela y tiñe la banda a lo largo
    // de la barra (medido: rgb(22,29,41) sobre lo azul, rgb(53,33,30) sobre lo rojo).
    readonly property color islaTinte: ColorUtils.applyAlpha(ColorUtils.mix(Appearance.colors.colLayer0, Appearance.colors.colLayer1, 0.8), 1)
    readonly property bool islaContorno: false
    readonly property int islaRadio: Appearance.rounding.full
    readonly property int islaInset: 5
    // `Appearance.rounding.full` es 9999: Qt lo acota a la mitad de la altura,
    // así que el radio real de la píldora es (baseBarHeight - 2*inset)/2 = 15.
    // Con el `padding: 5` de fábrica de IslandGroup el texto de la hora se
    // quedaba a 4 px del borde y chocaba con la curva. 12 despeja la curva por
    // los dos extremos (medido: la curva se come ~4 px a la altura del texto).
    readonly property int islaPadding: 12

    // Fondo de la barra, igual que en el BarContent de end-4. Se había quitado
    // cuando esto era solo islas sobre el fondo de pantalla; vuelve porque el
    // diseño de referencia lleva banda. Sigue colgando de `showBackground` y de
    // `cornerStyle`, así que no se le roba el control a los ajustes.
    Loader { // Sombra del fondo
        active: Config.options.bar.showBackground && Config.options.bar.cornerStyle === 1 && Config.options.bar.floatStyleShadow
        anchors.fill: barBackground
        sourceComponent: StyledRectangularShadow {
            anchors.fill: undefined // El Loader ancla por él; no debe anclarse solo
            target: barBackground
        }
    }
    Rectangle {
        id: barBackground
        anchors {
            fill: parent
            margins: Config.options.bar.cornerStyle === 1 ? (Appearance.sizes.hyprlandGapsOut) : 0
        }
        color: Config.options.bar.showBackground ? ColorUtils.applyAlpha(Appearance.colors.colLayer0, 1) : "transparent"
        radius: Config.options.bar.cornerStyle === 1 ? Appearance.rounding.windowRounding : 0
        border.width: Config.options.bar.cornerStyle === 1 ? 1 : 0
        border.color: Appearance.colors.colLayer0Border
    }

    FocusedScrollMouseArea { // Left side | scroll to change brightness
        id: barLeftSideMouseArea

        anchors {
            top: parent.top
            bottom: parent.bottom
            left: parent.left
            right: middleSection.left
        }
        implicitWidth: leftSectionRowLayout.implicitWidth
        implicitHeight: Appearance.sizes.baseBarHeight

        onScrollDown: Brightness.decreaseBrightness()
        onScrollUp: Brightness.increaseBrightness()
        onMovedAway: GlobalStates.osdBrightnessOpen = false
        onPressed: event => {
            if (event.button === Qt.LeftButton)
                GlobalStates.sidebarLeftOpen = !GlobalStates.sidebarLeftOpen;
        }

        ScrollHint {
            reveal: barLeftSideMouseArea.hovered
            icon: Hyprsunset.gamma === 100 ? "light_mode" : "wb_twilight"
            tooltipText: Translation.tr("Scroll to change brightness")
            side: "left"
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
        }

        RowLayout {
            id: leftSectionRowLayout
            anchors.fill: parent
            spacing: 0

            LeftSidebarButton {
                id: leftSidebarButton
                Layout.alignment: Qt.AlignVCenter
                Layout.leftMargin: Appearance.rounding.screenRounding
                colBackground: barLeftSideMouseArea.hovered ? Appearance.colors.colLayer1Hover : ColorUtils.transparentize(Appearance.colors.colLayer1Hover, 1)
            }

            // ── isla izquierda: recursos + multimedia ────────────────────
            IslandGroup {
                id: leftIsland
                outlined: root.islaContorno
                tint: root.islaTinte
                corner: root.islaRadio
                verticalInset: root.islaInset
                padding: root.islaPadding
                Layout.alignment: Qt.AlignVCenter
                // Con LeftSidebarButton oculto esta isla queda la primera de la
                // fila: sin este margen su contorno se dibuja fuera de la
                // esquina redondeada de la pantalla. Mismo valor que usa
                // RippleButton en el extremo contrario, así queda simétrico.
                Layout.leftMargin: leftSidebarButton.visible ? 0 : Appearance.rounding.screenRounding
                // Las dos islas de ancho variable —esta y la del título—
                // COMPARTEN el hueco, y por eso las dos llevan `fillWidth`.
                //
                // Que esto faltara es toda la historia de los dos fallos que
                // hubo aquí. Sin `fillWidth`, Qt le concede a UNA su ancho
                // natural completo y la otra se queda con las sobras. Primero
                // le tocó al título, que bajó a 40 px, solo el icono. Al
                // arreglarlo dándole prioridad al título, le tocó al
                // reproductor, que desapareció entero con Spotify enfocado
                // —su título de ventana es la canción, larguísimo—.
                //
                // Dar prioridad a una isla deja a la otra vacía en algún caso,
                // siempre. Con las dos en `fillWidth` y cada una topada a su
                // ancho natural, Qt reparte el déficit entre ambas: ceden los
                // TEXTOS a la vez, que para eso llevan recorte y deslizamiento,
                // y ninguna isla se queda en blanco.
                //
                // El suelo son los anillos: pueden quedarse sin texto de
                // canción al lado, pero no desaparecer.
                Layout.fillWidth: true
                Layout.minimumWidth: anillos.implicitWidth + root.islaPadding * 2
                Layout.maximumWidth: barLeftSideMouseArea.width

                StatsIsland {
                    id: anillos
                    Layout.fillWidth: root.useShortenedForm === 2
                }

                MediaIsland {
                    visible: root.useShortenedForm < 2
                    Layout.fillWidth: true
                }
            }

            // ── isla del título de la ventana enfocada ──────────────────
            // El tope tiene que salir del CONTENIDO, no ser un número fijo.
            // Con `maximumWidth: 460` a pelo la isla no sabía cuánto hueco
            // quedaba hasta la isla central y se le metía encima (medido: con
            // un título de 96 caracteres la franja iba de x=424 a x=1146 sin
            // separación, y la central lo tapaba por ir declarada después).
            //
            // `fillWidth: true` + máximo atado al ancho natural del contenido
            // da exactamente lo que se quiere: ancho = min(hueco, contenido).
            // Título corto -> se ciñe al texto, sin píldora medio vacía.
            // Título largo -> lo limita el hueco y el texto se DESLIZA dentro
            // (TituloDeslizante recorta y anima), en vez de cortarse.
            // `minimumWidth: 0` es lo que le permite encoger de verdad.
            IslandGroup {
                id: islaTitulo
                outlined: root.islaContorno
                tint: root.islaTinte
                corner: root.islaRadio
                verticalInset: root.islaInset
                padding: root.islaPadding
                Layout.alignment: Qt.AlignVCenter
                Layout.leftMargin: 10
                Layout.fillWidth: true
                Layout.minimumWidth: 0
                Layout.maximumWidth: ventanaActiva.implicitWidth + root.islaPadding * 2
                visible: root.useShortenedForm === 0

                TituloDeslizante {
                    id: ventanaActiva
                    Layout.fillWidth: true
                }
            }

            // Empuja la isla del título contra la de recursos en vez de dejarla
            // centrada en el hueco.
            Item {
                Layout.fillWidth: true
            }
        }
    }

    // ── isla central: espacios de trabajo + clima ────────────────────────
    Row {
        id: middleSection
        anchors {
            top: parent.top
            bottom: parent.bottom
            horizontalCenter: parent.horizontalCenter
        }
        spacing: 6

        IslandGroup {
            id: middleIsland
            anchors.verticalCenter: parent.verticalCenter
            padding: root.islaPadding
            outlined: root.islaContorno
            tint: root.islaTinte
            corner: root.islaRadio
            verticalInset: root.islaInset

            Workspaces {
                id: workspacesWidget
                Layout.fillHeight: true
                MouseArea {
                    // Right-click to toggle overview
                    anchors.fill: parent
                    acceptedButtons: Qt.RightButton

                    onPressed: event => {
                        if (event.button === Qt.RightButton) {
                            GlobalStates.overviewOpen = !GlobalStates.overviewOpen;
                        }
                    }
                }
            }

            Loader {
                active: Config.options.bar.weather.enable
                Layout.alignment: Qt.AlignVCenter
                Layout.leftMargin: active ? 6 : 0
                sourceComponent: WeatherBar {}
            }
        }
    }

    FocusedScrollMouseArea { // Right side | scroll to change volume
        id: barRightSideMouseArea

        anchors {
            top: parent.top
            bottom: parent.bottom
            left: middleSection.right
            right: parent.right
        }
        implicitWidth: rightSectionRowLayout.implicitWidth
        implicitHeight: Appearance.sizes.baseBarHeight

        onScrollDown: Audio.decrementVolume()
        onScrollUp: Audio.incrementVolume()
        onMovedAway: GlobalStates.osdVolumeOpen = false
        onPressed: event => {
            if (event.button === Qt.LeftButton) {
                GlobalStates.sidebarRightOpen = !GlobalStates.sidebarRightOpen;
            }
        }

        ScrollHint {
            reveal: barRightSideMouseArea.hovered
            icon: "volume_up"
            tooltipText: Translation.tr("Scroll to change volume")
            side: "right"
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
        }

        RowLayout {
            id: rightSectionRowLayout
            anchors.fill: parent
            spacing: 6
            layoutDirection: Qt.RightToLeft

            // Primero en RightToLeft = pegado al borde derecho, y por eso es
            // este el que lleva el margen de la esquina de pantalla.
            // ── isla del botón de la barra lateral ──────────────────────
            // Lleva los avisos de silencio, micro y notificaciones, y el
            // bluetooth. Antes flotaba suelto al borde: ahora es una isla más.
            IslandGroup {
                outlined: root.islaContorno
                tint: root.islaTinte
                corner: root.islaRadio
                verticalInset: root.islaInset
                padding: root.islaPadding
                Layout.alignment: Qt.AlignVCenter
                Layout.rightMargin: Appearance.rounding.screenRounding
                RippleButton { // Right sidebar button
                    id: rightSidebarButton

                    Layout.alignment: Qt.AlignRight | Qt.AlignVCenter
                    Layout.fillWidth: false

                    implicitWidth: indicatorsRowLayout.implicitWidth + 10 * 2
                    implicitHeight: indicatorsRowLayout.implicitHeight + 5 * 2

                    buttonRadius: Appearance.rounding.full
                    colBackground: barRightSideMouseArea.hovered ? Appearance.colors.colLayer1Hover : ColorUtils.transparentize(Appearance.colors.colLayer1Hover, 1)
                    colBackgroundHover: Appearance.colors.colLayer1Hover
                    colRipple: Appearance.colors.colLayer1Active
                    colBackgroundToggled: Appearance.colors.colSecondaryContainer
                    colBackgroundToggledHover: Appearance.colors.colSecondaryContainerHover
                    colRippleToggled: Appearance.colors.colSecondaryContainerActive
                    toggled: GlobalStates.sidebarRightOpen
                    property color colText: toggled ? Appearance.m3colors.m3onSecondaryContainer : Appearance.colors.colOnLayer0

                    Behavior on colText {
                        animation: Appearance.animation.elementMoveFast.colorAnimation.createObject(this)
                    }

                    onPressed: {
                        GlobalStates.sidebarRightOpen = !GlobalStates.sidebarRightOpen;
                    }

                    RowLayout {
                        id: indicatorsRowLayout
                        anchors.centerIn: parent
                        property real realSpacing: 15
                        spacing: 0

                        Revealer {
                            reveal: Audio.sink?.audio?.muted ?? false
                            Layout.fillHeight: true
                            Layout.rightMargin: reveal ? indicatorsRowLayout.realSpacing : 0
                            Behavior on Layout.rightMargin {
                                animation: Appearance.animation.elementMoveFast.numberAnimation.createObject(this)
                            }
                            MaterialSymbol {
                                text: "volume_off"
                                iconSize: Appearance.font.pixelSize.larger
                                color: rightSidebarButton.colText
                            }
                        }
                        Revealer {
                            reveal: Audio.source?.audio?.muted ?? false
                            Layout.fillHeight: true
                            Layout.rightMargin: reveal ? indicatorsRowLayout.realSpacing : 0
                            Behavior on Layout.rightMargin {
                                animation: Appearance.animation.elementMoveFast.numberAnimation.createObject(this)
                            }
                            MaterialSymbol {
                                text: "mic_off"
                                iconSize: Appearance.font.pixelSize.larger
                                color: rightSidebarButton.colText
                            }
                        }
                        Revealer {
                            reveal: Notifications.silent || Notifications.unread > 0
                            Layout.fillHeight: true
                            implicitHeight: reveal ? notificationUnreadCount.implicitHeight : 0
                            implicitWidth: reveal ? notificationUnreadCount.implicitWidth : 0
                            // Cada revelador aporta SU propia separación por la
                            // derecha. Este la había perdido en una edición mía y
                            // se quedó un `Behavior` sobre una propiedad que ya
                            // no se asignaba: código muerto, y sin hueco cuando
                            // el aviso aparece.
                            Layout.rightMargin: reveal ? indicatorsRowLayout.realSpacing : 0
                            Behavior on Layout.rightMargin {
                                animation: Appearance.animation.elementMoveFast.numberAnimation.createObject(this)
                            }
                            NotificationUnreadCount {
                                id: notificationUnreadCount
                            }
                        }
                        // El icono de red sale de aquí a propósito: ahora vive en la
                        // isla de la derecha con su propio detalle al hover, y
                        // tenerlo dos veces sería ruido.
                        MaterialSymbol {
                            // SIN margen izquierdo. En end-4 lo llevaba para
                            // separarse del icono de red que iba justo antes;
                            // al mover la red a la isla derecha, el bluetooth
                            // quedó el primero y esos 15 px pasaron a ser hueco
                            // por delante. Como la fila va centrada en el botón,
                            // el icono salía descuadrado a la derecha.
                            // La separación, cuando hace falta, la ponen los
                            // reveladores con su `rightMargin`.
                            visible: BluetoothStatus.available
                            text: BluetoothStatus.connected ? "bluetooth_connected" : BluetoothStatus.enabled ? "bluetooth" : "bluetooth_disabled"
                            iconSize: Appearance.font.pixelSize.larger
                            color: rightSidebarButton.colText
                        }
                    }
                }
            }

            // ── isla derecha: hora, utilidades, teclado, red, batería, sesión
            IslandGroup {
                id: rightIsland
                outlined: root.islaContorno
                tint: root.islaTinte
                corner: root.islaRadio
                verticalInset: root.islaInset
                padding: root.islaPadding
                Layout.alignment: Qt.AlignVCenter

                ClockWidget {
                    showDate: (Config.options.bar.verbose && root.useShortenedForm < 2)
                    Layout.alignment: Qt.AlignVCenter
                }

                UtilButtons {
                    visible: (Config.options.bar.verbose && root.useShortenedForm === 0)
                    Layout.alignment: Qt.AlignVCenter
                }

                KeyboardLayoutButton {
                    Layout.alignment: Qt.AlignVCenter
                }

                NetworkIsland {
                    Layout.alignment: Qt.AlignVCenter
                }

                BatteryIndicator {
                    visible: (root.useShortenedForm < 2 && Battery.available)
                    Layout.alignment: Qt.AlignVCenter
                }

                PowerButton {
                    Layout.alignment: Qt.AlignVCenter
                }
            }

            // La bandeja como isla propia: no la pediste, pero quitarla sería
            // perder los iconos de las aplicaciones que ya tienes ahí.
            IslandGroup {
                // Vacía si no hay iconos: sin esto quedaría una píldora hueca
                // flotando. `implicitWidth` del propio SysTray es la señal, y
                // no hace falta importar el servicio para leerla.
                visible: root.useShortenedForm === 0 && bandeja.implicitWidth > 0
                outlined: root.islaContorno
                tint: root.islaTinte
                corner: root.islaRadio
                verticalInset: root.islaInset
                padding: root.islaPadding
                Layout.alignment: Qt.AlignVCenter

                SysTray {
                    id: bandeja
                    visible: root.useShortenedForm === 0
                    Layout.fillHeight: true
                    invertSide: Config?.options.bar.bottom
                }
            }

            Item {
                Layout.fillWidth: true
                Layout.fillHeight: true
            }
        }
    }
}
