import qs.modules.common
import qs.services
import QtQuick
import Quickshell.Io

/**
 * NetworkPopup — detalle de la conexión al pasar el ratón.
 *
 * El servicio `Network` de end-4 da SSID, señal, estado y el punto de acceso
 * activo (con bssid, frecuencia y seguridad), pero NO la dirección IP: eso hay
 * que preguntárselo al sistema. El proceso solo corre mientras el popup está
 * abierto (`running: root.active`), así que no hay ningún sondeo de fondo
 * cuando nadie está mirando.
 */
StyledPopup {
    id: root

    property string ip: "--"
    property string iface: "--"

    readonly property var ap: Network.active
    readonly property bool conectado: Network.ethernet || (Network.wifiStatus === "connected" || (Network.networkName ?? "") !== "")

    function banda(mhz) {
        if (!mhz || mhz <= 0)
            return "--";
        return mhz >= 5900 ? "6 GHz" : mhz >= 4900 ? "5 GHz" : "2,4 GHz";
    }

    Column {
        anchors.centerIn: parent
        spacing: 8

        Process {
            // `ip -br -4 addr` da una línea por interfaz: nombre, estado y CIDR.
            // Se descarta loopback y se coge la primera que esté UP con dirección.
            running: root.active
            command: ["sh", "-c", "ip -br -4 addr show scope global up | head -1"]
            stdout: StdioCollector {
                onStreamFinished: {
                    const partes = text.trim().split(/\s+/);
                    if (partes.length >= 3) {
                        root.iface = partes[0];
                        root.ip = partes[2];
                    } else {
                        root.iface = "--";
                        root.ip = "sin dirección";
                    }
                }
            }
        }

        StyledPopupHeaderRow {
            icon: Network.materialSymbol
            label: Network.ethernet ? "Cableado" : (Network.networkName || (root.conectado ? "Wi-Fi" : "Sin conexión"))
        }

        Column {
            spacing: 4

            StyledPopupValueRow {
                icon: "lan"
                label: "Estado:"
                value: Network.ethernet ? "conectado (cable)" : Network.wifiStatus
            }
            StyledPopupValueRow {
                visible: !Network.ethernet
                icon: "network_wifi"
                label: "Señal:"
                value: Network.networkStrength > 0 ? `${Network.networkStrength}%` : "--"
            }
            StyledPopupValueRow {
                visible: !Network.ethernet && (root.ap?.frequency ?? 0) > 0
                icon: "graphic_eq"
                label: "Banda:"
                value: root.banda(root.ap?.frequency ?? 0)
            }
            StyledPopupValueRow {
                visible: !Network.ethernet
                icon: "lock"
                label: "Seguridad:"
                value: (root.ap?.security ?? "") !== "" ? root.ap.security : "abierta"
            }
            StyledPopupValueRow {
                icon: "cable"
                label: "Interfaz:"
                value: root.iface
            }
            StyledPopupValueRow {
                icon: "language"
                label: "IP:"
                value: root.ip
            }
            StyledPopupValueRow {
                visible: !Network.ethernet && (root.ap?.bssid ?? "") !== ""
                icon: "router"
                label: "BSSID:"
                value: root.ap?.bssid ?? "--"
            }
        }
    }
}
