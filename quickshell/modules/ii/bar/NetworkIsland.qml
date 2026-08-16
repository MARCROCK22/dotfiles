import qs.modules.common
import qs.modules.common.widgets
import qs.services
import QtQuick

/**
 * NetworkIsland — el icono de red con detalle al pasar el ratón.
 *
 * En la barra de end-4 la red es solo un `MaterialSymbol` suelto dentro del
 * botón de la barra lateral: no tiene popup ni nada que consultar. Aquí es un
 * widget con su propio hover.
 */
MouseArea {
    id: root

    implicitWidth: icono.implicitWidth + 12
    implicitHeight: Appearance.sizes.barHeight
    hoverEnabled: !Config.options.bar.tooltips.clickToShow
    acceptedButtons: Qt.NoButton

    MaterialSymbol {
        id: icono
        anchors.centerIn: parent
        text: Network.materialSymbol
        iconSize: Appearance.font.pixelSize.large
        color: Appearance.colors.colOnLayer1
    }

    NetworkPopup {
        hoverTarget: root
    }
}
