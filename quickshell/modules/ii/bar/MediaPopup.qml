import qs.modules.common
import qs.modules.common.widgets
import qs.modules.common.functions
import qs.services
import QtQuick
import QtQuick.Layouts
import Quickshell.Services.Mpris

/**
 * MediaPopup — el reproductor entero al pasar el ratón, con controles que se
 * pueden usar: `StyledPopup` se mantiene abierto mientras el ratón esté sobre
 * el widget o sobre el propio popup, así que se llega a los botones.
 *
 * NO hay lista de reproducción, y no es un descuido: Quickshell 0.3.0 expone de
 * MPRIS el objeto `MprisPlayer` con metadatos, estado y control, pero **no**
 * las interfaces `TrackList` ni `Playlists` (comprobado en
 * quickshell-service-mpris.qmltypes: no existen ni la propiedad ni el método).
 * Sin eso no hay forma de leer la cola del reproductor desde aquí. Lo que sí
 * hay es todo lo demás: aleatorio, repetición, volumen, velocidad, búsqueda y
 * cambio entre reproductores.
 */
StyledPopup {
    id: root

    readonly property MprisPlayer player: MprisController.activePlayer
    readonly property bool hasPlayer: root.player !== null
    readonly property list<MprisPlayer> players: MprisController.players

    ColumnLayout {
        anchors.centerIn: parent
        spacing: 10

        // La posición de MPRIS no emite cambios sola: hay que pedírsela (mismo
        // truco que end-4 en PlayerControl.qml:53). Va DENTRO del contenido:
        // la propiedad por defecto de StyledPopup es `contentItem`, de tipo
        // Item, y un Timer suelto ahí no compila.
        Timer {
            running: root.player?.playbackState == MprisPlaybackState.Playing
            interval: Config.options.resources.updateInterval
            repeat: true
            onTriggered: root.player.positionChanged()
        }

        // ── sin reproductor ──────────────────────────────────────────────
        StyledText {
            visible: !root.hasPlayer
            Layout.alignment: Qt.AlignHCenter
            text: "Sin multimedia"
            color: Appearance.colors.colSubtext
        }

        // ── carátula + datos de la pista ─────────────────────────────────
        RowLayout {
            visible: root.hasPlayer
            spacing: 12

            Rectangle {
                Layout.alignment: Qt.AlignVCenter
                implicitWidth: 76
                implicitHeight: 76
                radius: Appearance.rounding.small
                color: Appearance.colors.colLayer2
                clip: true

                Image {
                    id: artImage
                    anchors.fill: parent
                    // Ternario y no `??`: el operador produce un
                    // QJSPrimitiveValue que no convierte a QUrl limpiamente.
                    source: root.player ? root.player.trackArtUrl : ""
                    fillMode: Image.PreserveAspectCrop
                    asynchronous: true
                    visible: status === Image.Ready
                }
                MaterialSymbol {
                    anchors.centerIn: parent
                    text: "music_note"
                    iconSize: 32
                    color: Appearance.colors.colSubtext
                    // Por id, no por children[0]: el orden de los hijos cambia
                    // en cuanto alguien añada algo y el fallo sería mudo.
                    visible: !artImage.visible
                }
            }

            ColumnLayout {
                Layout.alignment: Qt.AlignVCenter
                spacing: 2

                StyledText {
                    Layout.maximumWidth: 340
                    text: root.player?.trackTitle || "—"
                    font.pixelSize: Appearance.font.pixelSize.normal
                    font.weight: Font.DemiBold
                    color: Appearance.colors.colOnLayer1
                    elide: Text.ElideRight
                }
                StyledText {
                    Layout.maximumWidth: 340
                    visible: (root.player?.trackArtist ?? "") !== ""
                    text: root.player?.trackArtist ?? ""
                    font.pixelSize: Appearance.font.pixelSize.small
                    color: Appearance.colors.colSubtext
                    elide: Text.ElideRight
                }
                StyledText {
                    Layout.maximumWidth: 340
                    visible: (root.player?.trackAlbum ?? "") !== ""
                    text: root.player?.trackAlbum ?? ""
                    font.pixelSize: Appearance.font.pixelSize.smaller
                    color: Appearance.colors.colSubtext
                    elide: Text.ElideRight
                }
                StyledText {
                    Layout.topMargin: 2
                    text: root.player?.identity ?? ""
                    font.pixelSize: Appearance.font.pixelSize.smaller
                    color: Appearance.colors.colSubtext
                }
            }
        }

        // ── posición ─────────────────────────────────────────────────────
        RowLayout {
            visible: root.hasPlayer && (root.player?.lengthSupported ?? false)
            Layout.fillWidth: true
            spacing: 8

            StyledText {
                text: StringUtils.friendlyTimeForSeconds(root.player?.position ?? 0)
                font.pixelSize: Appearance.font.pixelSize.smaller
                color: Appearance.colors.colSubtext
            }
            StyledSlider {
                Layout.fillWidth: true
                Layout.minimumWidth: 260
                enabled: root.player?.canSeek ?? false
                value: (root.player?.length ?? 0) > 0 ? (root.player.position / root.player.length) : 0
                onMoved: if (root.player)
                    root.player.position = value * root.player.length
            }
            StyledText {
                text: StringUtils.friendlyTimeForSeconds(root.player?.length ?? 0)
                font.pixelSize: Appearance.font.pixelSize.smaller
                color: Appearance.colors.colSubtext
            }
        }

        // ── controles ────────────────────────────────────────────────────
        RowLayout {
            visible: root.hasPlayer
            Layout.alignment: Qt.AlignHCenter
            spacing: 6

            CircleUtilButton {
                enabled: root.player?.shuffleSupported ?? false
                onClicked: MprisController.setShuffle(!MprisController.hasShuffle)
                MaterialSymbol {
                    text: "shuffle"
                    iconSize: Appearance.font.pixelSize.large
                    color: MprisController.hasShuffle ? Appearance.colors.colPrimary : Appearance.colors.colSubtext
                }
            }
            CircleUtilButton {
                enabled: root.player?.canGoPrevious ?? false
                onClicked: root.player?.previous()
                MaterialSymbol {
                    text: "skip_previous"
                    iconSize: Appearance.font.pixelSize.large
                    color: Appearance.colors.colOnLayer1
                }
            }
            CircleUtilButton {
                enabled: root.player?.canTogglePlaying ?? false
                onClicked: root.player?.togglePlaying()
                MaterialSymbol {
                    text: (root.player?.isPlaying ?? false) ? "pause" : "play_arrow"
                    iconSize: Appearance.font.pixelSize.huge
                    fill: 1
                    color: Appearance.colors.colPrimary
                }
            }
            CircleUtilButton {
                enabled: root.player?.canGoNext ?? false
                onClicked: root.player?.next()
                MaterialSymbol {
                    text: "skip_next"
                    iconSize: Appearance.font.pixelSize.large
                    color: Appearance.colors.colOnLayer1
                }
            }
            CircleUtilButton {
                enabled: root.player?.loopSupported ?? false
                // None -> Playlist -> Track -> None
                onClicked: {
                    const s = MprisController.loopState;
                    MprisController.setLoopState(s === MprisLoopState.None ? MprisLoopState.Playlist : s === MprisLoopState.Playlist ? MprisLoopState.Track : MprisLoopState.None);
                }
                MaterialSymbol {
                    text: MprisController.loopState === MprisLoopState.Track ? "repeat_one" : "repeat"
                    iconSize: Appearance.font.pixelSize.large
                    color: MprisController.loopState === MprisLoopState.None ? Appearance.colors.colSubtext : Appearance.colors.colPrimary
                }
            }
        }

        // ── volumen ──────────────────────────────────────────────────────
        RowLayout {
            visible: root.hasPlayer && (root.player?.volumeSupported ?? false)
            Layout.fillWidth: true
            spacing: 8

            MaterialSymbol {
                text: "volume_up"
                iconSize: Appearance.font.pixelSize.normal
                color: Appearance.colors.colSubtext
            }
            StyledSlider {
                Layout.fillWidth: true
                value: root.player?.volume ?? 0
                onMoved: if (root.player)
                    root.player.volume = value
            }
            StyledText {
                text: `${Math.round((root.player?.volume ?? 0) * 100)}%`
                font.pixelSize: Appearance.font.pixelSize.smaller
                color: Appearance.colors.colSubtext
            }
        }

        // ── cambiar de reproductor (solo si hay más de uno) ──────────────
        RowLayout {
            visible: root.players.length > 1
            Layout.alignment: Qt.AlignHCenter
            spacing: 6

            Repeater {
                model: root.players
                delegate: CircleUtilButton {
                    id: playerButton
                    required property MprisPlayer modelData
                    onClicked: MprisController.trackedPlayer = playerButton.modelData
                    MaterialSymbol {
                        text: "album"
                        iconSize: Appearance.font.pixelSize.normal
                        color: MprisController.activePlayer === playerButton.modelData ? Appearance.colors.colPrimary : Appearance.colors.colSubtext
                    }
                }
            }
        }
    }
}
