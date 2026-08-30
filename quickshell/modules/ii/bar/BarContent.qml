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
 * Reparto, copiado del diseño de referencia (20260830):
 *   izquierda  píldora con la hora · píldora con los puntos de workspace y el
 *              botón de la barra lateral · ventana enfocada SIN píldora
 *   centro     vacío
 *   derecha    píldora de recursos · bandeja · píldora de avisos, red,
 *              bluetooth y volumen · píldora de batería y sesión
 *
 * Lo que la referencia NO tiene y por tanto se fue: el reproductor, el clima,
 * la fecha del reloj, el teclado y las utilidades. Está todo en la rama
 * `respaldo-barra-20260830-0124` si hay que recuperarlo.
 *
 * Su píldora de tokens de Claude es un widget del fork de nao que aquí no
 * existe; en su sitio van los anillos de recursos, a petición.
 *
 * Todo lo que no sean los espacios de trabajo tiene detalle al pasar el ratón.
 * El de multimedia además se puede TOCAR: controles, búsqueda y
 * volumen. Los espacios de trabajo se quedan sin popup a propósito.
 *
 * La franja de la ventana enfocada se RETIRÓ el 20260830, a petición. Con ella
 * fuera, `TituloDeslizante.qml` se quedó sin usuarios y también salió del repo;
 * sigue en el historial de git por si vuelve.
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

            // ── píldora del reloj ───────────────────────────────────────
            // Sólo la hora, sin fecha: es lo que enseña el diseño de
            // referencia, y así le deja el ancho al título de la ventana.
            IslandGroup {
                outlined: root.islaContorno
                tint: root.islaTinte
                corner: root.islaRadio
                verticalInset: root.islaInset
                padding: root.islaPadding
                Layout.alignment: Qt.AlignVCenter
                // Esta isla abre la fila, así que hereda el margen de la
                // esquina redondeada de pantalla que llevaba LeftSidebarButton.
                Layout.leftMargin: Appearance.rounding.screenRounding

                ClockWidget {
                    showDate: false
                    Layout.alignment: Qt.AlignVCenter
                }
            }

            // ── espacios de trabajo, SIN píldora ────────────────────────
            // Van sueltos sobre la banda, sin fondo propio: sólo el reloj lleva
            // píldora en todo el lado izquierdo.
            //
            // Con NÚMEROS y no con los puntos de la guía, a petición: es la
            // única cosa del diseño de referencia que se deja de lado. Sale de
            // `alwaysShowNumbers` y `showAppIcons` en config.json, así que
            // Workspaces.qml se queda como lo trae end-4, sin adoptar.
            Workspaces {
                id: workspacesWidget
                Layout.fillHeight: true
                Layout.leftMargin: 14
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

            // ── botón del overview ──────────────────────────────────────
            // El círculo con el icono de capas que hay en la guía. No se usa
            // LeftSidebarButton: ése abre la barra lateral y además sólo se ve
            // si tienes activados el chat de IA, el traductor o lo de anime,
            // así que en esta máquina no se veía nunca.
            Item {
                Layout.alignment: Qt.AlignVCenter
                Layout.leftMargin: 14
                implicitWidth: 26
                implicitHeight: 26

                Rectangle {
                    anchors.fill: parent
                    radius: width / 2
                    color: botonOverview.containsMouse ? Appearance.colors.colLayer1Hover : "transparent"
                    border.width: 1
                    border.color: Appearance.colors.colOutlineVariant
                }

                MaterialSymbol {
                    anchors.centerIn: parent
                    text: "layers"
                    iconSize: 15
                    fill: GlobalStates.overviewOpen ? 1 : 0
                    color: Appearance.colors.colOnLayer0
                }

                MouseArea {
                    id: botonOverview
                    anchors.fill: parent
                    hoverEnabled: true
                    onPressed: GlobalStates.overviewOpen = !GlobalStates.overviewOpen
                }
            }

            // ── ventana enfocada, SIN píldora ───────────────────────────
            // En la referencia el icono y las dos líneas van sueltos sobre la
            // banda, sin fondo propio. TituloDeslizante ya trae el icono y las
            // dos líneas; aquí sólo se le da sitio.
            TituloDeslizante {
                id: ventanaActiva
                Layout.alignment: Qt.AlignVCenter
                Layout.leftMargin: 12
                Layout.fillWidth: true
                Layout.minimumWidth: 0
                Layout.maximumWidth: ventanaActiva.implicitWidth
            }

            // Empuja las islas contra el borde izquierdo en vez de dejarlas
            // centradas en el hueco.
            Item {
                Layout.fillWidth: true
            }
        }
    }

    // Divisoria estructural, no un contenedor. De sus bordes cuelgan los
    // anclajes de las dos mitades (`barLeftSideMouseArea.right` y
    // `barRightSideMouseArea.left`), así que no se puede borrar aunque el
    // centro quede vacío: con ancho cero es lo que parte la barra por la mitad.
    //
    // Va vacío porque los espacios de trabajo se han ido a la izquierda,
    // siguiendo el diseño de referencia.
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
            // ── lado derecho: SIN islas, separado por barras ────────────
            // La guía no lleva píldoras aquí: los iconos van sueltos sobre la
            // banda y los grupos se separan con una barra fina. Por eso este
            // lado no usa IslandGroup, al revés que el reloj de la izquierda.
            //
            // Orden en RightToLeft: lo PRIMERO declarado queda pegado al borde
            // derecho, así que se lee de derecha a izquierda.

            PowerButton {
                Layout.alignment: Qt.AlignVCenter
                Layout.rightMargin: Appearance.rounding.screenRounding
                Layout.leftMargin: 10
            }

            Separador {}

            // La batería y su separador desaparecen juntos: este equipo es un
            // sobremesa y `Battery.available` es false, y un separador suelto
            // sin nada al lado sería una raya en el aire.
            BatteryIndicator {
                visible: root.useShortenedForm < 2 && Battery.available
                Layout.alignment: Qt.AlignVCenter
                Layout.leftMargin: 10
                Layout.rightMargin: 10
            }

            Separador {
                visible: root.useShortenedForm < 2 && Battery.available
            }

            // ── avisos, red, bluetooth y volumen ────────────────────────
            RowLayout {
                Layout.alignment: Qt.AlignVCenter
                Layout.leftMargin: 10
                Layout.rightMargin: 10
                spacing: 12
                layoutDirection: Qt.LeftToRight

                Revealer {
                    reveal: Notifications.silent || Notifications.unread > 0
                    Layout.fillHeight: true
                    implicitWidth: reveal ? notificationUnreadCount.implicitWidth : 0
                    NotificationUnreadCount {
                        id: notificationUnreadCount
                    }
                }

                NetworkIsland {
                    Layout.alignment: Qt.AlignVCenter
                }

                MaterialSymbol {
                    visible: BluetoothStatus.available
                    text: BluetoothStatus.connected ? "bluetooth_connected" : BluetoothStatus.enabled ? "bluetooth" : "bluetooth_disabled"
                    iconSize: Appearance.font.pixelSize.larger
                    color: Appearance.colors.colOnLayer0
                }

                MaterialSymbol {
                    text: (Audio.sink?.audio?.muted ?? false) ? "volume_off" : "volume_up"
                    iconSize: Appearance.font.pixelSize.larger
                    color: Appearance.colors.colOnLayer0
                }

                // El micro va en circulo relleno cuando esta silenciado, que es
                // como lo marca la guia: ahi es el unico icono con fondo.
                Item {
                    implicitWidth: 24
                    implicitHeight: 24
                    Layout.alignment: Qt.AlignVCenter

                    Rectangle {
                        anchors.fill: parent
                        radius: width / 2
                        visible: Audio.source?.audio?.muted ?? false
                        color: Appearance.colors.colOnLayer0
                    }

                    MaterialSymbol {
                        anchors.centerIn: parent
                        text: (Audio.source?.audio?.muted ?? false) ? "mic_off" : "mic"
                        iconSize: Appearance.font.pixelSize.larger
                        color: (Audio.source?.audio?.muted ?? false) ? Appearance.colors.colLayer0 : Appearance.colors.colOnLayer0
                    }
                }
            }

            Separador {}

            // ── bandeja del sistema ─────────────────────────────────────
            SysTray {
                id: bandeja
                visible: root.useShortenedForm === 0 && bandeja.implicitWidth > 0
                Layout.alignment: Qt.AlignVCenter
                Layout.leftMargin: 12
                Layout.rightMargin: 12
                Layout.fillHeight: true
                invertSide: Config?.options.bar.bottom
            }

            // ── recursos ────────────────────────────────────────────────
            // En la guía este sitio lo ocupa el gasto de tokens de Claude, que
            // es un widget del fork de nao y aquí no existe. Sustituido a
            // petición por el uso de recursos de la máquina.
            StatsIsland {
                Layout.alignment: Qt.AlignVCenter
                Layout.leftMargin: 8
            }

            Item {
                Layout.fillWidth: true
                Layout.fillHeight: true
            }
        }
    }

    // `NotificationUnreadCount` de end-4 tiene el color cableado a
    // `rightSidebarButton.colText`, un id de la estructura que tenía la barra
    // antes. Ese botón ya no existe, y el componente resuelve los ids por el
    // contexto del fichero que lo instancia, así que basta con ofrecerle aquí
    // lo que busca. Se hace así en vez de adoptar NotificationUnreadCount.qml
    // como un reemplazo más: serían seis archivos de end-4 que revisar en cada
    // actualización, por cambiar una línea de color.
    QtObject {
        id: rightSidebarButton
        readonly property color colText: Appearance.colors.colOnLayer0
    }

    // La barra fina que separa grupos en el lado derecho. Es el mismo glifo de
    // la guía, no una línea dibujada: así hereda tamaño y color del tema sin
    // tener que cuadrar alturas a mano.
    component Separador: StyledText {
        Layout.alignment: Qt.AlignVCenter
        text: "/"
        color: Appearance.colors.colOnLayer1Inactive
        font.pixelSize: Appearance.font.pixelSize.larger
    }
}
