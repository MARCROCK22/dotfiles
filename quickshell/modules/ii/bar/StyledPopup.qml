import qs.modules.common
import qs.modules.common.widgets
import qs.modules.common.functions
import QtQuick
import QtQuick.Effects
import Quickshell
import Quickshell.Wayland

/**
 * StyledPopup — popup de barra que SE MANTIENE mientras el ratón está dentro.
 *
 * El original de end-4 era `active: hoverTarget.containsMouse`: bastaba salir
 * del widget para destruirlo, así que al bajar el ratón hacia el popup este
 * desaparecía a mitad de camino y nunca se podía leer entero ni tocar nada.
 *
 * Dos cosas lo arreglan, y hacen falta las dos:
 *
 *  1. `popupHovered` — el propio popup avisa cuando el ratón está encima, con
 *     un HoverHandler. Tiene que ser un *handler* y no un MouseArea hijo: la
 *     línea `children: [root.contentItem]` de abajo ASIGNA la lista de hijos
 *     entera y se lleva por delante cualquier hijo declarado aquí, sin dejar
 *     rastro en el log. Los handlers viven en otra lista y sobreviven.
 *
 *  2. Sin `mask` — antes la zona sensible era solo `popupBackground`, y entre
 *     la barra y ese rectángulo quedaba una franja muerta de
 *     `elevationMargin` (10 px) donde el puntero no estaba ni en el widget ni
 *     en el popup. Con la ventana entera sensible esa franja desaparece.
 *
 * El margen de gracia cubre lo que aún queda de recorrido entre el borde de
 * abajo del widget y el borde de arriba de la ventana del popup.
 *
 * `hoverTarget` se queda declarado como `Item` a propósito: SysTray le pasa un
 * `RippleButton`, que no es un MouseArea. Tiparlo más estrecho lo rompería.
 */
LazyLoader {
    id: root

    property Item hoverTarget
    default property Item contentItem
    property real popupBackgroundMargin: 0
    property int graceMs: 450

    // DOS fuentes de hover, y hacen falta las dos:
    //  · `hoverInterior` va en popupBackground, que es el PADRE del contenido:
    //    el hover propaga hacia arriba, así que sigue contando cuando el ratón
    //    está sobre un botón o un deslizador de dentro.
    //  · `hoverMarco` va en un Item que cubre la ventana entera, para la franja
    //    transparente de `elevationMargin` que queda fuera del fondo.
    // Ponerlo SOLO en el Item de la ventana no vale: al estar por debajo del
    // contenido, cualquier hijo que acepte hover se lo queda y el handler de
    // abajo se apaga en cada paso del ratón (medido: parpadeaba 12 veces al
    // recorrer el popup, y el popup se cerraba a mitad de camino).
    property bool hoverInterior: false
    property bool hoverMarco: false
    readonly property bool popupHovered: root.hoverInterior || root.hoverMarco

    readonly property bool wantOpen: (root.hoverTarget?.containsMouse ?? false) || root.popupHovered
    onWantOpenChanged: {
        if (root.wantOpen) {
            graceTimer.stop();
            // Solo un popup a la vez: al abrirse este, el anterior pierde su
            // margen de gracia y se va sin esperar.
            PopupState.reclamar(root);
        } else {
            graceTimer.restart();
        }
    }

    // Lo llama PopupState cuando otro popup toma el relevo. No toca `active`
    // directamente: parar la gracia basta, porque `wantOpen` ya es false (el
    // ratón está en otro widget).
    function cerrarYa(): void {
        graceTimer.stop();
    }

    onActiveChanged: if (!root.active)
        PopupState.soltar(root)

    active: root.wantOpen || graceTimer.running

    // La propiedad por defecto de LazyLoader es `component`: un `Timer { }`
    // suelto no sería un hijo, se asignaría ahí y competiría con el
    // PanelWindow. Por eso va como valor de una propiedad con nombre.
    readonly property Timer graceTimer: Timer {
        interval: root.graceMs
        repeat: false
    }

    component: PanelWindow {
        id: popupWindow
        color: "transparent"

        anchors.left: !Config.options.bar.vertical || (Config.options.bar.vertical && !Config.options.bar.bottom)
        anchors.right: Config.options.bar.vertical && Config.options.bar.bottom
        anchors.top: Config.options.bar.vertical || (!Config.options.bar.vertical && !Config.options.bar.bottom)
        anchors.bottom: !Config.options.bar.vertical && Config.options.bar.bottom

        implicitWidth: popupBackground.implicitWidth + Appearance.sizes.elevationMargin * 2 + root.popupBackgroundMargin
        implicitHeight: popupBackground.implicitHeight + Appearance.sizes.elevationMargin * 2 + root.popupBackgroundMargin

        exclusionMode: ExclusionMode.Ignore
        exclusiveZone: 0
        margins {
            left: {
                if (!Config.options.bar.vertical) {
                    // Centrado sobre el widget, pero sin salirse de la pantalla:
                    // un widget pegado a un borde daba un valor negativo y el
                    // popup se recortaba.
                    const x = root.QsWindow?.mapFromItem(root.hoverTarget, (root.hoverTarget.width - popupBackground.implicitWidth) / 2, 0).x ?? 0;
                    const maxX = (popupWindow.screen?.width ?? 0) - popupWindow.implicitWidth;
                    return Math.max(0, Math.min(x, maxX));
                }
                return Appearance.sizes.verticalBarWidth;
            }
            top: {
                if (!Config.options.bar.vertical)
                    return Appearance.sizes.barHeight;
                return root.QsWindow?.mapFromItem(root.hoverTarget, (root.hoverTarget.height - popupBackground.implicitHeight) / 2, 0).y;
            }
            right: Appearance.sizes.verticalBarWidth
            bottom: Appearance.sizes.barHeight
        }
        WlrLayershell.namespace: "quickshell:popup"
        WlrLayershell.layer: WlrLayer.Overlay

        // Si la ventana muere con el ratón dentro, `popupHovered` se quedaría
        // en true para siempre y el popup no volvería a cerrarse nunca.
        Component.onDestruction: {
            root.hoverInterior = false;
            root.hoverMarco = false;
        }

        StyledRectangularShadow {
            target: popupBackground
        }

        Rectangle {
            id: popupBackground
            readonly property real margin: 10
            anchors {
                fill: parent
                leftMargin: Appearance.sizes.elevationMargin + root.popupBackgroundMargin * (!popupWindow.anchors.left)
                rightMargin: Appearance.sizes.elevationMargin + root.popupBackgroundMargin * (!popupWindow.anchors.right)
                topMargin: Appearance.sizes.elevationMargin + root.popupBackgroundMargin * (!popupWindow.anchors.top)
                bottomMargin: Appearance.sizes.elevationMargin + root.popupBackgroundMargin * (!popupWindow.anchors.bottom)
            }
            implicitWidth: root.contentItem.implicitWidth + margin * 2
            implicitHeight: root.contentItem.implicitHeight + margin * 2
            color: Appearance.m3colors.m3surfaceContainer
            radius: Appearance.rounding.small
            children: [root.contentItem]

            border.width: 1
            border.color: Appearance.colors.colLayer0Border

            HoverHandler {
                onHoveredChanged: root.hoverInterior = hovered
            }
        }

        // Cubre la ventana ENTERA, no solo el fondo: así la franja transparente
        // de elevationMargin también cuenta como «estoy en el popup» y el
        // recorrido desde la barra no pasa por ningún punto muerto.
        // Va sobre un Item propio y no colgando del PanelWindow (que no es un
        // Item) ni de popupBackground (que solo cubre el interior).
        // `blocking` se queda en false: así no le roba el hover a los botones
        // que haya dentro del contenido.
        Item {
            anchors.fill: parent
            z: -1
            HoverHandler {
                onHoveredChanged: root.hoverMarco = hovered
            }
        }
    }
}
