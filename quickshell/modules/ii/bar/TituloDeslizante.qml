import qs.services
import qs.modules.common
import qs.modules.common.widgets
import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Wayland
import Quickshell.Hyprland

/**
 * TituloDeslizante — como ActiveWindow de end-4, pero el texto que no cabe se
 * desliza en vez de cortarse con puntos suspensivos.
 *
 * Se replica en vez de editar `ActiveWindow.qml` para no adueñarse de un
 * archivo más de end-4 (mismo criterio que MediaIsland). La lógica de qué
 * texto mostrar es la suya, copiada tal cual.
 *
 * El contenedor RECORTA (`clip: true`), y eso importa más de lo que parece:
 * sin recorte, cuando el layout aprieta esta isla por falta de sitio, el texto
 * se seguía pintando fuera de ella, por debajo de las islas vecinas. Con
 * recorte, apretarla simplemente enseña menos texto.
 *
 * La animación solo corre cuando el texto NO cabe. Es un bucle infinito en una
 * barra de portátil: si cupiera y siguiera animando, serían repintados
 * constantes a cambio de nada.
 */
Item {
    id: root

    readonly property HyprlandMonitor monitor: Hyprland.monitorFor(root.QsWindow.window?.screen)
    readonly property Toplevel activeWindow: ToplevelManager.activeToplevel
    property bool focusingThisMonitor: HyprlandData.activeWorkspace?.monitor == monitor?.name
    property var biggestWindow: HyprlandData.biggestWindowForWorkspace(HyprlandData.monitors[root.monitor?.id]?.activeWorkspace.id)

    // Velocidad y pausas del deslizamiento.
    property int pausaInicialMs: 2000
    property int pausaFinalMs: 1200
    property real pixelesPorSegundo: 45

    implicitWidth: colLayout.implicitWidth
    implicitHeight: colLayout.implicitHeight

    component Deslizante: Item {
        id: cont
        // Propiedades explícitas en vez de `property alias ... : texto.algo`:
        // StyledText viene de un import `qs.*` que el analizador no resuelve, y
        // un alias hacia dentro de un tipo irresoluble no se puede comprobar.
        property string contenido
        property color colorTexto
        property int tamanoTexto

        clip: true
        implicitWidth: texto.implicitWidth
        implicitHeight: texto.implicitHeight

        readonly property real sobrante: Math.max(0, texto.implicitWidth - cont.width)
        readonly property bool desborda: cont.sobrante > 0 && cont.width > 0

        StyledText {
            id: texto
            x: 0
            width: implicitWidth
            text: cont.contenido
            color: cont.colorTexto
            font.pixelSize: cont.tamanoTexto
            // Sin `elide`: aquí el texto completo existe y se mueve; recortar la
            // cadena haría imposible llegar a leer el final.
        }

        // Reposicionar al principio en cuanto deja de desbordar, o el texto se
        // quedaría congelado a medio recorrer.
        onDesbordaChanged: if (!cont.desborda)
            texto.x = 0

        SequentialAnimation {
            running: cont.desborda && cont.visible
            loops: Animation.Infinite
            onRunningChanged: if (!running)
                texto.x = 0

            PauseAnimation {
                duration: root.pausaInicialMs
            }
            NumberAnimation {
                target: texto
                property: "x"
                from: 0
                to: -cont.sobrante
                duration: Math.max(300, cont.sobrante / root.pixelesPorSegundo * 1000)
                easing.type: Easing.Linear
            }
            PauseAnimation {
                duration: root.pausaFinalMs
            }
            NumberAnimation {
                target: texto
                property: "x"
                to: 0
                duration: 350
                easing.type: Easing.InOutQuad
            }
        }
    }

    ColumnLayout {
        id: colLayout
        anchors.verticalCenter: parent.verticalCenter
        anchors.left: parent.left
        anchors.right: parent.right
        spacing: -4

        Deslizante {
            Layout.fillWidth: true
            tamanoTexto: Appearance.font.pixelSize.smaller
            colorTexto: Appearance.colors.colSubtext
            contenido: root.focusingThisMonitor && root.activeWindow?.activated && root.biggestWindow ? root.activeWindow?.appId : ((root.biggestWindow?.class) ?? Translation.tr("Desktop"))
        }

        Deslizante {
            Layout.fillWidth: true
            tamanoTexto: Appearance.font.pixelSize.small
            colorTexto: Appearance.colors.colOnLayer0
            contenido: root.focusingThisMonitor && root.activeWindow?.activated && root.biggestWindow ? root.activeWindow?.title : ((root.biggestWindow?.title) ?? `${Translation.tr("Workspace")} ${monitor?.activeWorkspace?.id ?? 1}`)
        }
    }
}
