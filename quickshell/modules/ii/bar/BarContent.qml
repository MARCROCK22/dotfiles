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

            LeftSidebarButton {
                id: leftSidebarButton
                Layout.alignment: Qt.AlignVCenter
                Layout.leftMargin: Appearance.rounding.screenRounding
                colBackground: barLeftSideMouseArea.hovered ? Appearance.colors.colLayer1Hover : ColorUtils.transparentize(Appearance.colors.colLayer1Hover, 1)
            }

            // ── isla izquierda: recursos + multimedia ────────────────────
            IslandGroup {
                id: leftIsland
                outlined: true
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

                StatsIsland {
                    Layout.fillWidth: root.useShortenedForm === 2
                }

                MediaIsland {
                    visible: root.useShortenedForm < 2
                    Layout.fillWidth: true
                }
            }

            // ── isla del título de la ventana enfocada ──────────────────
            // Sin `fillWidth`: con él la isla se estiraría hasta la central y
            // quedaría una píldora enorme medio vacía. El tope de ancho hace
            // que un título largo elide (los textos de dentro ya traen
            // `elide: ElideRight`) en vez de invadir el centro.
            IslandGroup {
                outlined: true
                tint: root.islaTinte
                corner: root.islaRadio
                verticalInset: root.islaInset
                padding: root.islaPadding
                Layout.alignment: Qt.AlignVCenter
                Layout.leftMargin: 10
                Layout.fillWidth: false
                Layout.maximumWidth: 460
                visible: root.useShortenedForm === 0

                ActiveWindow {
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
            outlined: true
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
                            Layout.leftMargin: indicatorsRowLayout.realSpacing
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

            Item {
                Layout.fillWidth: true
                Layout.fillHeight: true
            }
        }
    }
}
