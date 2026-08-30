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

    // Deja fijar el reproductor desde fuera; sin esto la barra no puede pedir
    // "ensename Spotify" y se queda con el que MprisController tenga por activo.
    property alias reproductorFijo: media.reproductorFijo

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
        // El popup tiene que ensenar el MISMO reproductor que la isla; si no,
        // la barra pone Spotify y el detalle al hover otra cosa.
        reproductorFijo: root.reproductorFijo
    }
}
