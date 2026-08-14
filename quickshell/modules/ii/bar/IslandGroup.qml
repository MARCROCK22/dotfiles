import qs.modules.common
import QtQuick
import QtQuick.Layouts

/**
 * IslandGroup — grupo de barra con tratamiento visual, en vez de solo fondo.
 *
 * Mismo esqueleto que BarGroup.qml de end-4 (Item + Rectangle de fondo +
 * GridLayout con los mismos columnSpacing/rowSpacing), asi que se puede
 * sustituir uno por otro sin que se mueva nada. Lo unico que cambia es el
 * Rectangle: aqui el borde, el radio y el tinte son propiedades.
 *
 * BarGroup no tiene NINGUNA propiedad de borde y su radio es siempre
 * Appearance.rounding.small, por eso reordenar BarContent.qml nunca podia
 * cambiar el aspecto de los grupos: no habia nada que variar.
 *
 * Se respeta `bar.borderless` igual que BarGroup: si el usuario lo activa,
 * desaparecen fondo y borde, no solo el fondo.
 */
Item {
    id: root

    property real padding: 5
    property color tint: Appearance.colors.colLayer1
    property real corner: Appearance.rounding.small
    property bool outlined: false
    property color outlineColor: Appearance.colors.colOutlineVariant
    // Cuanto se encoge el fondo respecto al alto de la barra. BarGroup lo
    // tiene fijo en 4; aqui se puede subir para que la isla parezca mas
    // pequeña y flotante, o bajar para que llene mas.
    property real verticalInset: 4

    implicitWidth: gridLayout.implicitWidth + root.padding * 2
    implicitHeight: Appearance.sizes.baseBarHeight
    default property alias items: gridLayout.children

    Rectangle {
        id: background
        anchors {
            fill: parent
            topMargin: root.verticalInset
            bottomMargin: root.verticalInset
        }
        color: Config.options?.bar.borderless ? "transparent" : root.tint
        radius: root.corner
        border.width: (root.outlined && !(Config.options?.bar.borderless ?? false)) ? 1 : 0
        border.color: root.outlineColor

        // La paleta se regenera con cada wallpaper, asi que el color cambia
        // solo. elementMoveFast es la UNICA animacion del tema que expone
        // colorAnimation; elementMove no la tiene.
        Behavior on color {
            animation: Appearance.animation.elementMoveFast.colorAnimation.createObject(this)
        }
    }

    GridLayout {
        id: gridLayout
        columns: -1
        anchors {
            verticalCenter: parent.verticalCenter
            left: parent.left
            right: parent.right
            margins: root.padding
        }
        columnSpacing: 4
        rowSpacing: 12
    }
}
