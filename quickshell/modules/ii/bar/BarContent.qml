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
 * Diseño 11 — Islas.
 *
 * La barra deja de ser una banda: no se dibuja `barBackground` (ni su sombra),
 * así que el fondo es el fondo de pantalla y cada grupo flota como una isla con
 * su propio relleno, su contorno y su forma de píldora.
 *
 * Reparto:
 *   izquierda  hora con día, espacios de trabajo y ventana enfocada
 *   centro     vacío
 *   derecha    anillos, multimedia, clima, avisos, utilidades, teclado,
 *              red, batería y sesión
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
    readonly property color islaTinte: Appearance.colors.colLayer0
    readonly property int islaRadio: Appearance.rounding.full
    readonly property int islaInset: 5
    // `Appearance.rounding.full` es 9999: Qt lo acota a la mitad de la altura,
    // así que el radio real de la píldora es (baseBarHeight - 2*inset)/2 = 15.
    // Con el `padding: 5` de fábrica de IslandGroup el texto de la hora se
    // quedaba a 4 px del borde y chocaba con la curva. 12 despeja la curva por
    // los dos extremos (medido: la curva se come ~4 px a la altura del texto).
    readonly property int islaPadding: 12

    // Sin `barBackground` ni su sombra: eso es lo que convierte la banda en
    // islas. El resto del archivo no toca `Config.options.bar.showBackground`,
    // así que los otros diseños siguen comportándose igual.

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

            // El reloj abre la fila, suelto y sin isla: es el ancla del
            // extremo izquierdo, y por eso lleva él el margen de la esquina de
            // pantalla que antes llevaba LeftSidebarButton.
            ClockWidget {
                showDate: (Config.options.bar.verbose && root.useShortenedForm < 2)
                Layout.alignment: Qt.AlignVCenter
                Layout.leftMargin: Appearance.rounding.screenRounding
            }

            // ── isla de espacios de trabajo ─────────────────────────────
            // Salen como puntos sin tocar Workspaces.qml: con
            // `alwaysShowNumbers` y `showAppIcons` apagados en config.json,
            // NumberWorkspaceItem cae a su `Circle` de 5 px y del activo se
            // encarga TrailingIndicator, que ya era la píldora alargada.
            IslandGroup {
                outlined: true
                tint: root.islaTinte
                corner: root.islaRadio
                verticalInset: root.islaInset
                padding: root.islaPadding
                Layout.alignment: Qt.AlignVCenter
                Layout.leftMargin: 10

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

                // El botón de la barra lateral entra en esta isla en vez de ir
                // suelto contra el borde: ahí es donde lo pone el diseño, justo
                // detrás de los puntos.
                LeftSidebarButton {
                    id: leftSidebarButton
                    Layout.alignment: Qt.AlignVCenter
                    Layout.leftMargin: 6
                    colBackground: barLeftSideMouseArea.hovered ? Appearance.colors.colLayer1Hover : ColorUtils.transparentize(Appearance.colors.colLayer1Hover, 1)
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
                outlined: true
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

    // Divisoria estructural, no un contenedor. De sus bordes cuelgan los
    // anclajes de las dos mitades (`barLeftSideMouseArea.right` y
    // `barRightSideMouseArea.left`), así que no se puede borrar aunque el
    // centro quede vacío: con ancho cero es lo que parte la barra por la mitad.
    Item {
        id: middleSection
        anchors {
            top: parent.top
            bottom: parent.bottom
            horizontalCenter: parent.horizontalCenter
        }
        implicitWidth: 0
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
                outlined: true
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
                outlined: true
                tint: root.islaTinte
                corner: root.islaRadio
                verticalInset: root.islaInset
                padding: root.islaPadding
                Layout.alignment: Qt.AlignVCenter

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
                outlined: true
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

            // ── isla de anillos, multimedia y clima ─────────────────────
            // Vienen de la izquierda, que se vació para el reloj y los
            // espacios de trabajo. El tope de ancho se ata ahora a la mitad
            // DERECHA: es el mismo razonamiento que tenía en la izquierda (un
            // título de canción largo la hacía crecer sin freno y cruzaba la
            // barra), sólo que cambia la referencia contra la que se mide.
            IslandGroup {
                outlined: true
                tint: root.islaTinte
                corner: root.islaRadio
                verticalInset: root.islaInset
                padding: root.islaPadding
                Layout.alignment: Qt.AlignVCenter
                Layout.minimumWidth: 0
                Layout.maximumWidth: barRightSideMouseArea.width

                StatsIsland {
                    Layout.fillWidth: root.useShortenedForm === 2
                }

                MediaIsland {
                    visible: root.useShortenedForm < 2
                    Layout.fillWidth: true
                }

                Loader {
                    active: Config.options.bar.weather.enable
                    Layout.alignment: Qt.AlignVCenter
                    Layout.leftMargin: active ? 6 : 0
                    sourceComponent: WeatherBar {}
                }
            }

            Item {
                Layout.fillWidth: true
                Layout.fillHeight: true
            }
        }
    }
}
