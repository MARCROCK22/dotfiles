import qs.modules.common
import qs.modules.common.widgets
import qs.services
import QtQuick
import Quickshell

/**
 * KeyboardLayoutButton — muestra la distribución activa y la rota al pulsar.
 *
 * OJO con el dialecto: `switchxkblayout` es un COMANDO de hyprctl, no un
 * dispatcher, así que NO pasa por el Lua de `hl.dsp.*` (comprobado: el
 * dispatcher `hl.dsp.keyboard` ni siquiera existe, da «attempt to index a nil
 * value»). Por eso aquí se ejecuta hyprctl directamente y no Hyprland.dispatch.
 *
 * `all` aplica a todos los teclados, así que no hay que cablear el nombre del
 * dispositivo, que cambia de un equipo a otro.
 *
 * Solo se ve si hay MÁS DE UNA distribución configurada — misma condición que
 * usa el HyprlandXkbIndicator de end-4. Con una sola, el botón no tendría nada
 * que alternar. Para añadir otra, en el Lua de Hyprland: kb_layout = "us,es".
 */
MouseArea {
    id: root

    readonly property bool disponible: HyprlandXkb.layoutCodes.length > 1

    visible: root.disponible
    implicitWidth: root.disponible ? etiqueta.implicitWidth + 14 : 0
    implicitHeight: Appearance.sizes.barHeight
    hoverEnabled: true
    onClicked: Quickshell.execDetached(["hyprctl", "switchxkblayout", "all", "next"])

    StyledText {
        id: etiqueta
        anchors.centerIn: parent
        text: (HyprlandXkb.currentLayoutCode || "??").toUpperCase()
        font.pixelSize: Appearance.font.pixelSize.smaller
        font.weight: Font.DemiBold
        color: Appearance.colors.colOnLayer1
    }
}
