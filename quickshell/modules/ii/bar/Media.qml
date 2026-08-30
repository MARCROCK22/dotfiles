import qs.modules.common
import qs.modules.common.widgets
import qs.services
import qs
import qs.modules.common.functions

import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Services.Mpris
import Quickshell.Hyprland

Item {
    id: root
    property bool borderless: Config.options.bar.borderless
    // CUARTO cambio sobre end-4: se puede fijar QUE reproductor se muestra.
    // Por defecto sigue siendo el activo, que es lo que hacia siempre; la barra
    // lo usa para clavar el del centro a Spotify.
    //
    // Hace falta porque `activePlayer` sigue a lo ULTIMO que sono: al darle a
    // un video de YouTube el activo pasa a ser Firefox, y al pausarlo se queda
    // ahi. Spotify podia seguir sonando y el reproductor del centro no volvia.
    // Ruta del icono de la aplicacion que suena, o "" si no se resuelve.
    //
    // Se busca por ENTRADA .DESKTOP y no adivinando por el nombre, porque con
    // Spotify adivinar no funciona: el icono no se llama «spotify» sino
    // «spotify-launcher», y esa correspondencia solo la conoce el .desktop
    // (`StartupWMClass=spotify` -> `Icon=spotify-launcher`). El reproductor
    // publica `DesktopEntry = "spotify"`, que es justo la pista que hace falta.
    //
    // `guessIcon` queda de ultimo recurso para reproductores sin .desktop.
    readonly property string rutaIcono: {
        const p = activePlayer;
        if (!p)
            return "";
        const e = DesktopEntries.heuristicLookup(p.desktopEntry ?? "") ?? DesktopEntries.heuristicLookup(p.identity ?? "");
        return Quickshell.iconPath(e?.icon ?? AppSearch.guessIcon(p.identity ?? ""), "");
    }

    property MprisPlayer reproductorFijo: null
    readonly property MprisPlayer activePlayer: reproductorFijo ?? MprisController.activePlayer
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

        // QUINTO cambio sobre end-4: el icono de la APLICACION -Spotify- en
        // vez del glifo generico de pausa. El anillo de progreso se queda:
        // sigue marcando por donde va la cancion, que el icono no dice.
        //
        // El icono va FUERA del ClippedFilledCircularProgress y superpuesto,
        // no dentro. Dentro no se veia: ese componente recorta su contenido con
        // una mascara, y eso mata a un Kirigami.Icon aunque el glifo de texto
        // que habia antes si sobreviviera. Se perdio un rato buscandolo en el
        // tamano y en la ruta, que estaban bien -el diagnostico daba
        // `image://icon/spotify-launcher`, correcto-.
        Item {
            Layout.alignment: Qt.AlignVCenter
            implicitWidth: 20
            implicitHeight: 20

            ClippedFilledCircularProgress {
                id: mediaCircProg
                anchors.fill: parent
                lineWidth: Appearance.rounding.unsharpen
                value: activePlayer?.position / activePlayer?.length
                implicitSize: 20
                colPrimary: Appearance.colors.colOnSecondaryContainer
                enableAnimation: false
            }

            AppIcon {
                id: iconoApp
                anchors.centerIn: parent
                // Se mira si la RUTA resolvio, no el `status`: AppIcon es un
                // Kirigami.Icon, no un Image, asi que comparar contra
                // Image.Ready dejaba el anillo sin icono Y sin reserva.
                visible: root.rutaIcono !== ""
                implicitSize: 13
                source: root.rutaIcono
            }

            // Reserva para reproductores sin entrada .desktop que resolver.
            MaterialSymbol {
                anchors.centerIn: parent
                visible: !iconoApp.visible
                fill: 1
                text: activePlayer?.isPlaying ? "pause" : "music_note"
                iconSize: Appearance.font.pixelSize.normal
                color: Appearance.m3colors.m3onSecondaryContainer
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
