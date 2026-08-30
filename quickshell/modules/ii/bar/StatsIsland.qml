import qs.modules.common
import qs.services
import QtQuick
import QtQuick.Layouts

/**
 * StatsIsland — RAM, GPU y swap como anillos de progreso, con detalle al hover.
 *
 * Reutiliza `Resource.qml` de end-4 tal cual: ya dibuja el anillo con
 * `ClippedFilledCircularProgress`, el icono dentro y el porcentaje al lado, y
 * ya trae la animación de aparición/desaparición. Escribir un anillo propio
 * habría duplicado eso y se habría desincronizado con el tema.
 *
 * Orden: RAM, GPU, swap, CPU y la bateria del casco. CPU se deja encendido
 * porque es lo que la barra mostraba antes; apagarlo es `showCpu: false`.
 *
 * La del casco va la ULTIMA y desaparece sola cuando el casco esta apagado o
 * fuera de alcance, para no dejar un anillo a cero fingiendo que sabe algo.
 */
MouseArea {
    id: root

    property bool showCpu: true
    property bool showGpu: true
    property bool showSwap: true
    property bool showCasco: true

    implicitWidth: rowLayout.implicitWidth + rowLayout.anchors.leftMargin + rowLayout.anchors.rightMargin
    implicitHeight: Appearance.sizes.barHeight
    // Config.options.bar.tooltips.clickToShow está en false, así que esto es
    // hover de verdad. Si el usuario lo pone en true, todos los popups de la
    // barra pasan a clic a la vez, incluido este.
    hoverEnabled: !Config.options.bar.tooltips.clickToShow

    StatsProbe {
        id: probe
        gpuEnabled: root.showGpu
    }

    RowLayout {
        id: rowLayout
        spacing: 0
        anchors.fill: parent
        anchors.leftMargin: 4
        anchors.rightMargin: 4

        Resource {
            iconName: "memory"
            percentage: ResourceUsage.memoryUsedPercentage
            warningThreshold: Config.options.bar.resources.memoryWarningThreshold
        }

        Resource {
            iconName: "developer_board"
            percentage: probe.gpuUtilFraction
            shown: root.showGpu && probe.gpuHasData
            Layout.leftMargin: shown ? 6 : 0
            warningThreshold: 90
        }

        Resource {
            iconName: "swap_horiz"
            percentage: ResourceUsage.swapUsedPercentage
            shown: root.showSwap && ResourceUsage.swapTotal > 0
            Layout.leftMargin: shown ? 6 : 0
            warningThreshold: Config.options.bar.resources.swapWarningThreshold
        }

        Resource {
            iconName: "planner_review"
            percentage: ResourceUsage.cpuUsage
            shown: root.showCpu
            Layout.leftMargin: shown ? 6 : 0
            warningThreshold: Config.options.bar.resources.cpuWarningThreshold
        }

        // Bateria del casco. `Resource` pinta en rojo cuando el valor es ALTO,
        // que vale para RAM o CPU y es justo al reves para una bateria. En vez
        // de adoptar Resource.qml de end-4 solo para invertir esa regla, el
        // aviso se da cambiando el ICONO, y el umbral se pone en 101 para que
        // el camino de "alto es malo" no se dispare nunca.
        Resource {
            iconName: probe.cascoCargando ? "battery_charging_full" : (probe.cascoNivel >= 0 && probe.cascoNivel <= 20) ? "battery_alert" : "headphones"
            percentage: probe.cascoFraccion
            shown: root.showCasco && probe.cascoHayDato
            Layout.leftMargin: shown ? 6 : 0
            warningThreshold: 101
        }
    }

    StatsPopup {
        hoverTarget: root
        probe: probe
        showCpu: root.showCpu
        showGpu: root.showGpu
    }
}
