import qs.modules.common
import qs.services
import QtQuick

/**
 * StatsPopup — el detalle que sale al pasar el ratón por StatsIsland.
 *
 * Ojo con una etiqueta heredada: `ResourceUsage.memoryFree` NO es MemFree, es
 * **MemAvailable** (ver ResourceUsage.qml:74). El ResourcesPopup de end-4 lo
 * rotula «Free», lo cual miente por exceso: MemAvailable incluye la caché
 * reclamable. Aquí se rotula «Disponible», que es lo que realmente es.
 */
StyledPopup {
    id: root

    // Tipado como StatsProbe y no como Item: así el analizador resuelve
    // gpuVramUsedMb y compañía en vez de tragarse 20 accesos a ciegas.
    required property StatsProbe probe
    property bool showCpu: true
    property bool showGpu: true

    function gb(kb) {
        return (kb / (1024 * 1024)).toFixed(1) + " GB";
    }
    function pct(f) {
        return `${Math.round(f * 100)}%`;
    }

    Row {
        anchors.centerIn: parent
        spacing: 14

        // ── RAM ──────────────────────────────────────────────────────────
        Column {
            anchors.top: parent.top
            spacing: 8

            StyledPopupHeaderRow {
                icon: "memory"
                label: "RAM"
            }
            Column {
                spacing: 4
                StyledPopupValueRow {
                    icon: "clock_loader_60"
                    label: "Usada:"
                    value: root.gb(ResourceUsage.memoryUsed)
                }
                StyledPopupValueRow {
                    icon: "check_circle"
                    label: "Disponible:"
                    value: root.gb(ResourceUsage.memoryFree)
                }
                StyledPopupValueRow {
                    icon: "empty_dashboard"
                    label: "Total:"
                    value: root.gb(ResourceUsage.memoryTotal)
                }
                StyledPopupValueRow {
                    icon: "percent"
                    label: "Uso:"
                    value: root.pct(ResourceUsage.memoryUsedPercentage)
                }
            }
        }
        // ── GPU ──────────────────────────────────────────────────────────
        Column {
            visible: root.showGpu && root.probe.gpuHasData
            anchors.top: parent.top
            spacing: 8

            StyledPopupHeaderRow {
                icon: "developer_board"
                // "NVIDIA GeForce RTX 3050 Laptop GPU" no cabe: se recorta al
                // modelo, que es lo único que distingue una GPU de otra.
                label: root.probe.gpuName.replace(/^NVIDIA GeForce /, "").replace(/ Laptop GPU$/, "") || "GPU"
            }
            Column {
                spacing: 4
                StyledPopupValueRow {
                    icon: "bolt"
                    label: "Uso:"
                    value: root.probe.gpuUtilPct >= 0 ? `${root.probe.gpuUtilPct}%` : "--"
                }
                StyledPopupValueRow {
                    icon: "clock_loader_60"
                    label: "VRAM usada:"
                    value: root.probe.mbToGbString(root.probe.gpuVramUsedMb)
                }
                StyledPopupValueRow {
                    icon: "check_circle"
                    label: "VRAM libre:"
                    value: root.probe.mbToGbString(root.probe.gpuVramFreeMb)
                }
                StyledPopupValueRow {
                    icon: "empty_dashboard"
                    label: "VRAM total:"
                    value: root.probe.mbToGbString(root.probe.gpuVramTotalMb)
                }
                StyledPopupValueRow {
                    icon: "thermostat"
                    label: "Temperatura:"
                    value: root.probe.gpuTempC >= 0 ? `${root.probe.gpuTempC} °C` : "--"
                }
                StyledPopupValueRow {
                    icon: "battery_charging_full"
                    label: "Potencia:"
                    value: root.probe.gpuPowerW >= 0 ? `${root.probe.gpuPowerW.toFixed(1)} W` : "--"
                }
                StyledPopupValueRow {
                    icon: "speed"
                    label: "Reloj:"
                    value: root.probe.gpuClockMhz >= 0 ? `${root.probe.gpuClockMhz} MHz` : "--"
                }
            }
        }
        // ── Swap ─────────────────────────────────────────────────────────
        Column {
            visible: ResourceUsage.swapTotal > 0
            anchors.top: parent.top
            spacing: 8

            StyledPopupHeaderRow {
                icon: "swap_horiz"
                label: "Swap"
            }
            Column {
                spacing: 4
                StyledPopupValueRow {
                    icon: "clock_loader_60"
                    label: "Usada:"
                    value: root.gb(ResourceUsage.swapUsed)
                }
                StyledPopupValueRow {
                    icon: "check_circle"
                    label: "Libre:"
                    value: root.gb(ResourceUsage.swapFree)
                }
                StyledPopupValueRow {
                    icon: "empty_dashboard"
                    label: "Total:"
                    value: root.gb(ResourceUsage.swapTotal)
                }
                StyledPopupValueRow {
                    icon: "percent"
                    label: "Uso:"
                    value: root.pct(ResourceUsage.swapUsedPercentage)
                }
            }
        }
        // ── CPU ──────────────────────────────────────────────────────────
        Column {
            visible: root.showCpu
            anchors.top: parent.top
            spacing: 8

            StyledPopupHeaderRow {
                icon: "planner_review"
                label: "CPU"
            }
            Column {
                spacing: 4
                StyledPopupValueRow {
                    icon: "bolt"
                    label: "Carga:"
                    value: root.pct(ResourceUsage.cpuUsage)
                }
                StyledPopupValueRow {
                    icon: "thermostat"
                    label: "Temperatura:"
                    value: root.probe.cpuTempC >= 0 ? `${root.probe.cpuTempC} °C` : "--"
                }
                StyledPopupValueRow {
                    icon: "grid_view"
                    label: "Hilos:"
                    value: root.probe.cpuCores > 0 ? `${root.probe.cpuCores}` : "--"
                }
            }
        }

        // ── casco ────────────────────────────────────────────────────────
        // El anillo solo da el porcentaje; lo interesante es la AUTONOMÍA, que
        // headsetcontrol calcula y no se ve en ningún otro sitio. Todo esto
        // sale del mismo JSON que ya se pide para el anillo, así que no cuesta
        // ni una llamada más.
        Column {
            anchors.top: parent.top
            spacing: 8
            visible: root.probe.cascoHayDato

            StyledPopupHeaderRow {
                icon: "headphones"
                label: "Casco"
            }
            Column {
                spacing: 4
                StyledPopupValueRow {
                    icon: "battery_full"
                    label: "Batería:"
                    value: `${root.probe.cascoNivel}%`
                }
                StyledPopupValueRow {
                    icon: root.probe.cascoCargando ? "bolt" : "schedule"
                    label: root.probe.cascoCargando ? "Estado:" : "Autonomía:"
                    // Cargando no tiene sentido dar una autonomía que baja a
                    // cero: se dice que está cargando y punto.
                    value: root.probe.cascoCargando ? "Cargando" : root.probe.cascoAutonomia
                }
                StyledPopupValueRow {
                    icon: "electric_bolt"
                    label: "Voltaje:"
                    value: `${root.probe.cascoVoltajeMv} mV`
                }
            }
        }
    }
}
