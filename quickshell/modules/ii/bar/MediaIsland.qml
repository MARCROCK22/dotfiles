import qs.modules.common
import QtQuick

/**
 * MediaIsland — el widget de media de end-4 tal cual, más el popup de hover.
 *
 * `Media.qml` es un Item, no un MouseArea, así que no tiene `containsMouse` y
 * StyledPopup no puede engancharse a él. Este envoltorio aporta el hover sin
 * tocar el archivo de end-4.
 *
 * `acceptedButtons: Qt.NoButton` es lo que hace que siga funcionando lo de
 * antes: el MouseArea interno de Media (clic = panel, medio = play/pausa,
 * derecho/adelante = siguiente, atrás = anterior) sigue recibiendo todos los
 * botones. Este de fuera solo escucha el paso del ratón.
 */
MouseArea {
    id: root

    implicitWidth: media.implicitWidth
    implicitHeight: media.implicitHeight

    hoverEnabled: !Config.options.bar.tooltips.clickToShow
    acceptedButtons: Qt.NoButton

    Media {
        id: media
        anchors.fill: parent
    }

    MediaPopup {
        hoverTarget: root
    }
}
