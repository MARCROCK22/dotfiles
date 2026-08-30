import qs.modules.common
import qs.modules.common.widgets
import qs.services
import qs
import qs.modules.common.functions

import QtQuick
import QtQuick.Layouts
import Quickshell.Services.Mpris
import Quickshell.Hyprland

Item {
    id: root
    property bool borderless: Config.options.bar.borderless
    readonly property MprisPlayer activePlayer: MprisController.activePlayer
    // TERCER cambio sobre end-4. Antes esto era el titulo del reproductor
    // activo a secas, sin mirar si estaba sonando, asi que al parar la barra se
    // quedaba clavada con lo ultimo. Caso real que lo destapo -dos
    // reproductores MPRIS, los dos parados-:
    //
    //     firefox (audio de WhatsApp)  Paused   titulo "WhatsApp"
    //     spotify                      Paused   titulo "Escapism (feat...)"
    //
    // El de Firefox era legitimo: un audio de WhatsApp que ya habia terminado.
    // El problema no es de donde viene el titulo, es que se seguia enseniando
    // despues de parar, y encima MprisController prefirio ese, asi que la barra
    // ponia «WhatsApp» como si estuviera sonando algo.
    //
    // El texto va literal y no por `Translation.tr`: no existe el fichero de
    // traduccion es_MX -el shell avisa al arrancar-, asi que tr() devolveria
    // el original en ingles, que es justo lo que no se quiere.
    readonly property string cleanedTitle: activePlayer?.playbackState === MprisPlaybackState.Playing ? (StringUtils.cleanMusicTitle(activePlayer?.trackTitle) || "Nada reproduciendo") : "Nada reproduciendo"

    Layout.fillHeight: true
    implicitWidth: rowLayout.implicitWidth + rowLayout.spacing * 2
    implicitHeight: Appearance.sizes.barHeight

    Timer {
        running: activePlayer?.playbackState == MprisPlaybackState.Playing
        interval: Config.options.resources.updateInterval
        repeat: true
        onTriggered: activePlayer.positionChanged()
    }

    MouseArea {
        anchors.fill: parent
        acceptedButtons: Qt.MiddleButton | Qt.BackButton | Qt.ForwardButton | Qt.RightButton | Qt.LeftButton
        onPressed: (event) => {
            if (event.button === Qt.MiddleButton) {
                activePlayer.togglePlaying();
            } else if (event.button === Qt.BackButton) {
                activePlayer.previous();
            } else if (event.button === Qt.ForwardButton || event.button === Qt.RightButton) {
                activePlayer.next();
            } else if (event.button === Qt.LeftButton) {
                GlobalStates.mediaControlsOpen = !GlobalStates.mediaControlsOpen
            }
        }
    }

    RowLayout { // Real content
        id: rowLayout

        spacing: 4
        anchors.fill: parent

        ClippedFilledCircularProgress {
            id: mediaCircProg
            Layout.alignment: Qt.AlignVCenter
            lineWidth: Appearance.rounding.unsharpen
            value: activePlayer?.position / activePlayer?.length
            implicitSize: 20
            colPrimary: Appearance.colors.colOnSecondaryContainer
            enableAnimation: false

            Item {
                anchors.centerIn: parent
                width: mediaCircProg.implicitSize
                height: mediaCircProg.implicitSize
                
                MaterialSymbol {
                    anchors.centerIn: parent
                    fill: 1
                    text: activePlayer?.isPlaying ? "pause" : "music_note"
                    iconSize: Appearance.font.pixelSize.normal
                    color: Appearance.m3colors.m3onSecondaryContainer
                }
            }
        }

        StyledText {
            visible: Config.options.bar.verbose
            // SEGUNDO cambio sobre end-4, y es un fallo suyo: aqui habia un
            // `width:` explicito dentro de un Layout, que pelea con el propio
            // Layout, y encima restaba `CircularProgress.size`, una referencia
            // ESTATICA a un tipo que no resuelve. La resta daba NaN, el ancho
            // quedaba invalido y `elide` no tenia contra que recortar: con la
            // isla apretada el texto se desbordaba y se dibujaba ENCIMA de los
            // anillos de RAM/GPU/CPU en vez de truncarse.
            //
            // No se veia porque hasta ahora la isla siempre recibia su ancho
            // natural completo; solo aparece al ponerle un tope.
            //
            // Se quita el `width:` y manda `Layout.fillWidth`, que es lo que
            // debia mandar desde el principio.
            Layout.alignment: Qt.AlignVCenter
            Layout.fillWidth: true // Ensures the text takes up available space
            Layout.rightMargin: rowLayout.spacing
            horizontalAlignment: Text.AlignHCenter
            elide: Text.ElideRight // Truncates the text on the right
            color: Appearance.colors.colOnLayer1
            // UNICO cambio sobre el archivo de end-4: el artista pasa a ser
            // opcional. Se deja como una sola linea y colgando de un ajuste a
            // proposito, para que volver a aplicarlo tras una actualizacion de
            // end-4 sea trivial y se vea de un vistazo en el diff.
            // Acceso opcional en toda la cadena: `Config.options` se carga de
            // forma asincrona y al arrancar `bar.media` aun no existe. Sin los
            // `?.` la excepcion rompe el enlace y el titulo se queda VACIO para
            // siempre, no solo durante el arranque (comprobado).
            text: `${cleanedTitle}${(Config.options?.bar?.media?.showArtist && activePlayer?.trackArtist) ? ' • ' + activePlayer.trackArtist : ''}`
        }

    }

}
