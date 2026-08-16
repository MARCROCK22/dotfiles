import QtQuick
import Quickshell.Io

/**
 * StatsProbe — fuente de datos para StatsIsland. Sin UI.
 *
 * GPU: `nvidia-smi`. En ESTA máquina eso es barato y no despierta nada, y no es
 * una suposición: el panel interno `eDP-2` cuelga de `card1`, cuyo driver es
 * `nvidia` (o sea, la RTX conduce la pantalla), y su
 * `/sys/bus/pci/devices/0000:01:00.0/power/runtime_status` es `active` con
 * `runtime_suspended_time = 0` — nunca se ha suspendido desde el arranque.
 * Medido: 33 ms por llamada. La advertencia clásica de portátil híbrido
 * («nvidia-smi despierta la dGPU ~10 s y se nota en la batería») NO aplica
 * aquí. Si el equipo se pasa alguna vez a modo híbrido de verdad, subir
 * `gpuIntervalMs` o poner `gpuEnabled: false`.
 *
 * Temperatura de CPU: se resuelve la ruta de `coretemp` UNA vez con un
 * proceso, porque la numeración de `/sys/class/hwmon/hwmonN` cambia entre
 * arranques y fijarla sería un fallo silencioso tras el primer reinicio.
 * Después son lecturas de archivo, sin procesos.
 */
Item {
    id: root
    visible: false
    implicitWidth: 0
    implicitHeight: 0

    property int gpuIntervalMs: 3000
    property bool gpuEnabled: true

    // ── GPU ──────────────────────────────────────────────────────────────
    property bool gpuAvailable: true
    property string gpuName: ""
    property int gpuUtilPct: -1
    property int gpuTempC: -1
    property real gpuVramUsedMb: -1
    property real gpuVramTotalMb: -1
    property real gpuPowerW: -1
    property int gpuClockMhz: -1

    readonly property real gpuVramFreeMb: (gpuVramTotalMb > 0 && gpuVramUsedMb >= 0) ? (gpuVramTotalMb - gpuVramUsedMb) : -1
    readonly property real gpuVramFraction: (gpuVramTotalMb > 0 && gpuVramUsedMb >= 0) ? (gpuVramUsedMb / gpuVramTotalMb) : 0
    readonly property real gpuUtilFraction: gpuUtilPct >= 0 ? (gpuUtilPct / 100) : 0
    readonly property bool gpuHasData: root.gpuAvailable && root.gpuVramTotalMb > 0

    // ── CPU ──────────────────────────────────────────────────────────────
    property int cpuTempC: -1
    property int cpuCores: 0

    // nvidia-smi devuelve "[N/A]" en campos que la GPU no reporta; parseFloat
    // de eso da NaN y NaN se propaga a toda la UI sin avisar. -1 = sin dato.
    function num(s) {
        const v = parseFloat(s);
        return isNaN(v) ? -1 : v;
    }

    function mbToGbString(mb) {
        return mb < 0 ? "--" : (mb / 1024).toFixed(1) + " GB";
    }

    Process {
        id: smiProc
        command: ["env", "LC_ALL=C", "timeout", "3", "nvidia-smi",
            "--query-gpu=name,utilization.gpu,temperature.gpu,memory.used,memory.total,power.draw,clocks.gr",
            "--format=csv,noheader,nounits"]
        onExited: (exitCode, exitStatus) => {
            // 127 = no existe; 124 = timeout; cualquier otro = roto.
            // Apagarlo evita que el Timer siga quemando procesos para nada.
            if (exitCode !== 0)
                root.gpuAvailable = false;
        }
        stdout: StdioCollector {
            onStreamFinished: {
                const linea = text.trim().split("\n")[0];
                if (!linea)
                    return;
                const c = linea.split(",").map(s => s.trim());
                if (c.length < 7)
                    return;
                root.gpuName = c[0];
                root.gpuUtilPct = root.num(c[1]);
                root.gpuTempC = root.num(c[2]);
                root.gpuVramUsedMb = root.num(c[3]);
                root.gpuVramTotalMb = root.num(c[4]);
                root.gpuPowerW = root.num(c[5]);
                root.gpuClockMhz = root.num(c[6]);
                root.gpuAvailable = true;
            }
        }
    }

    Timer {
        running: root.gpuEnabled && root.gpuAvailable
        interval: root.gpuIntervalMs
        repeat: true
        triggeredOnStart: true
        // Sin solapes: si la llamada anterior sigue viva, se salta este turno.
        onTriggered: if (!smiProc.running)
            smiProc.running = true
    }

    // ── resolución de la ruta de coretemp, una sola vez ───────────────────
    Process {
        running: true
        command: ["sh", "-c",
            "for d in /sys/class/hwmon/hwmon*; do [ \"$(cat $d/name 2>/dev/null)\" = coretemp ] && { echo $d/temp1_input; break; }; done; nproc"]
        stdout: StdioCollector {
            onStreamFinished: {
                const l = text.trim().split("\n");
                if (l.length >= 2) {
                    fileCpuTemp.path = l[0];
                    root.cpuCores = parseInt(l[1]) || 0;
                } else if (l.length === 1 && l[0]) {
                    root.cpuCores = parseInt(l[0]) || 0;
                }
            }
        }
    }

    FileView {
        id: fileCpuTemp
        path: ""
    }

    Timer {
        running: fileCpuTemp.path !== ""
        interval: 3000
        repeat: true
        triggeredOnStart: true
        onTriggered: {
            fileCpuTemp.reload();
            const t = parseInt(fileCpuTemp.text());
            root.cpuTempC = isNaN(t) ? -1 : Math.round(t / 1000);
        }
    }
}
