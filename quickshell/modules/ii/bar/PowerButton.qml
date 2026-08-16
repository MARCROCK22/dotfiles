import qs
import qs.modules.common
import qs.modules.common.widgets
import QtQuick

/**
 * PowerButton — NO apaga: abre el menú de sesión de end-4.
 *
 * `GlobalStates.sessionOpen` es la misma señal que usa la barra lateral
 * derecha (SidebarRightContent.qml:293), así que sale el menú de siempre con
 * bloquear / suspender / reiniciar / apagar y un clic de más antes de nada
 * irreversible.
 */
CircleUtilButton {
    id: root
    onClicked: GlobalStates.sessionOpen = true

    MaterialSymbol {
        text: "power_settings_new"
        iconSize: Appearance.font.pixelSize.large
        color: Appearance.colors.colOnLayer1
    }
}
