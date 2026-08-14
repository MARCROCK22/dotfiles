// GpuWidget.qml — dos piezas independientes que se activan por separado:
//   1) Chip dGPU/iGPU: en qué GPU corre la VENTANA ENFOCADA. Coste ~0, no toca la GPU.
//   2) Telemetría NVIDIA: uso/temp/VRAM, tras una guarda dura de energía.
//
// ═══════════════════════════════════════════════════════════════════════════
// LA INVARIANTE QUE HACE O ROMPE ESTE WIDGET
// ═══════════════════════════════════════════════════════════════════════════
// nvidia-smi DESPIERTA la GPU discreta y la mantiene despierta ~10 s (0 W
// dormida vs ~10 W despierta). Por eso `nvidia-smi` sale de UN SOLO sitio en
// todo el archivo — la función sampleTelemetry() — y esa función retorna antes
// de arrancar nada si el kernel dice que la GPU está dormida. No hay ningún
// Timer que llegue a nvidia-smi sin pasar por ahí.
//
// El estado de energía se lee de /sys/bus/pci/devices/<pci>/power/runtime_status.
// En el kernel (drivers/base/power/sysfs.c, runtime_status_show) es un
// sysfs_emit() de un campo ya cacheado en `dev->power.runtime_status`: no hace
// I/O al dispositivo y no lo despierta. Lo dice bien Noctalia: un atributo
// sysfs que pasa por el driver SÍ lo resume; runtime_status lo sirve el core de
// PM, así que preguntarlo nunca despierta nada. (Por eso este widget NO usa
// /proc/driver/nvidia/gpus/*/power, que parece equivalente pero internamente
// llama a rm_get_power_info(), es decir, entra al driver.)
//
// El chip usa /proc/<pid>/fd. La Arch wiki (PRIME § RTD3) recomienda justo esto
// por encima de nvidia-smi: «Unlike nvidia-smi, it reports every process using
// the device, and it doesn't wake up the GPU.»
//
// Reglas duras del brief que respeta:
//   · CERO animaciones infinitas — solo Behavior por cambio de estado.
//   · Opt-in en DOS niveles, ambos false por defecto (ver Config.qml).
//   · Fallo aislado: sin datos se oculta él solo, no tumba la barra.
//   · Histéresis + permanencia mínima en todo lo que aparece por umbral.
//   · ANCHO INVARIANTE tras el descubrimiento: ver la nota de "Geometría".

import qs.services
import qs.modules.common
import qs.modules.common.widgets
import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io

Item {
    id: root

    // ═══════════════════════════ Config (opt-in) ═══════════════════════════
    // OJO: Config.options es un JsonAdapter con propiedades DECLARADAS
    // ESTÁTICAMENTE. Una clave que no exista en Config.qml es `undefined` para
    // siempre por mucho que el usuario la escriba en config.json. El bloque a
    // insertar en Config.qml va en la nota de entrega — sin él, este widget
    // queda apagado permanentemente y no es un bug del widget.
    readonly property var opts: Config.options?.bar.dgpu ?? null

    // Nivel 1: existir.
    readonly property bool cfgEnable: opts?.enable ?? false
    // Nivel 2: autorizar nvidia-smi. Separado y false por defecto PORQUE
    // despierta la GPU ~10 s. Sin esto el widget funciona entero salvo los
    // números: chip + estado ON/OFF, que salen de sysfs y son gratis.
    readonly property bool cfgAllowSmi: opts?.allowNvidiaSmi ?? false

    readonly property bool cfgChip: opts?.chip ?? true
    // Modos. NINGUNO puede despertar una GPU dormida.
    //   "off"    — nunca se ejecuta nvidia-smi.
    //   "peek"   — solo con clic central. Cero Timers.
    //   "auto"   — DEFECTO, y es lo que hace que el widget se adapte solo:
    //              con batería descargándose degrada a "peek" (la
    //              recomendación honesta en el portátil); enchufado o en un
    //              sobremesa sin batería, sondea de forma continua.
    //   "always" — continuo siempre que la GPU ya esté despierta.
    readonly property string cfgTelemetry: opts?.telemetry ?? "auto"
    readonly property int cfgPowerPollMs: opts?.powerPollInterval ?? 5000
    readonly property int cfgTelemetryMs: opts?.telemetryInterval ?? 5000
    readonly property int cfgChildDepth: opts?.chipChildDepth ?? 1
    readonly property int cfgPermanenceMs: opts?.minPermanenceMs ?? 3000
    readonly property int cfgReleaseAfter: opts?.releaseAfterSamples ?? 6
    readonly property int cfgReleaseMs: opts?.releaseMs ?? 12000

    // ═══════════════════════ Estado descubierto (1 vez) ════════════════════
    property bool discovered: false
    property string nvPath: ""      // /sys/bus/pci/devices/0000:01:00.0
    property string nvAddr: ""      // 0000:01:00.0
    property string otherAddr: ""   // PCI de la integrada (Intel/AMD), si la hay
    property int gpuCount: 0
    property string nvControl: "on" // "auto" = runtime PM activo; "on" = desactivado

    // Estado de energía. Los seis valores reales del kernel (ABI documentada en
    // Documentation/ABI/testing/sysfs-devices-power):
    //   suspended | suspending | resuming | active | error | unsupported
    property string powerState: "unknown"

    // ── Escenario: el widget se adapta solo ───────────────────────────────
    // Portátil híbrido → ≥2 GPUs y runtime PM en "auto".
    // Sobremesa (RTX 4060 única, siempre despierta, sin batería) → 1 GPU, sin
    //   batería, y runtime PM desactivado ("on") o "unsupported". Ahí el chip
    //   dGPU/iGPU no tiene sentido (se oculta solo: hybrid es false) y la
    //   telemetría continua sí es aceptable.
    readonly property bool nvidiaPresent: root.nvAddr !== ""
    readonly property bool hybrid: root.gpuCount >= 2 && root.nvidiaPresent
    readonly property bool runtimePm: root.nvControl === "auto"
                                      && root.powerState !== "unsupported"
    readonly property bool desktopScenario: root.nvidiaPresent
                                            && !Battery.available
                                            && !root.runtimePm

    // ═══════════════════════════ Chip: veredicto ═══════════════════════════
    // "dgpu" = hay fd a /dev/nvidia<N>: el driver tiene una referencia de
    //          energía real sobre esa GPU. Señal fuerte.
    // "igpu" = confirmado en positivo por DRM fdinfo (drm-driver + drm-pdev).
    // "icd"  = SOLO /dev/nvidiactl: enumeración de ICDs, lo hace Electron/
    //          Chromium constantemente. NO cuenta como uso.
    // ""     = todavía sin escanear.
    property string scanVerdict: ""
    property string displayVerdict: ""
    property string pendingVerdict: ""
    property string scanDriver: ""
    property int lastScannedPid: -1

    // ═════════════════════════ Telemetría: valores ═════════════════════════
    property bool smiAvailable: true      // se apaga solo si nvidia-smi no existe
    property int utilPct: -1
    property int tempC: -1
    property real vramUsedMb: -1
    property real vramTotalMb: -1
    property int samplesSinceRelease: 0
    property bool releasing: false
    property bool peekRequested: false
    property bool awakeSticky: false

    // ═══════════════════════════ Derivados de UI ═══════════════════════════
    // Estas dos SOLO dependen de hechos de hardware fijados en el
    // descubrimiento, nunca del veredicto ni de la telemetría. Es lo que
    // mantiene el ancho invariante (ver "Geometría").
    readonly property bool chipShown: root.cfgChip && root.hybrid
    readonly property bool telemetryShown: root.nvidiaPresent
    readonly property bool shown: root.cfgEnable && root.discovered
                                  && (root.chipShown || root.telemetryShown)

    // ── Fail-open DELIBERADO ───────────────────────────────────────────────
    // Solo bloquea lo que el kernel declara EXPLÍCITAMENTE dormido.
    // "unsupported" / "unknown" / "error" / fichero ausente significan «aquí no
    // hay runtime PM» — el caso del sobremesa — y ahí consultar es gratis. Si
    // esto fuera `=== "active"`, el widget quedaría mudo para siempre justo en
    // la máquina donde la telemetría sí merece la pena.
    // Las tres implementaciones que aciertan hacen exactamente esto:
    // PolpOnline/gpu-usage-waybar (is_powered_on: Err(_) => Ok(true)),
    // taffybar PR #691 (missing y unknown preservan el consultar) y
    // Ly-sec/Noctalia (isInactiveRuntimeStatus: solo suspended || suspending).
    readonly property bool knownAsleep: root.powerState === "suspended"
                                        || root.powerState === "suspending"
    readonly property bool safeToQuery: !root.knownAsleep
    readonly property bool gpuAwake: !root.knownAsleep || root.awakeSticky
    readonly property bool smiEnabled: root.cfgAllowSmi
                                       && root.cfgTelemetry !== "off"
                                       && root.smiAvailable
    readonly property bool haveReadout: root.smiEnabled && root.gpuAwake
                                        && root.utilPct >= 0

    // Modo continuo permitido: nunca con batería descargándose salvo "always".
    readonly property bool continuousAllowed: {
        if (!root.smiEnabled) return false;
        if (root.cfgTelemetry === "always") return true;
        if (root.cfgTelemetry === "auto")
            return !Battery.available || Battery.isPluggedIn;
        return false; // "peek" no hace polling nunca
    }

    // ══════════════════════════════ Geometría ═════════════════════════════
    // El widget NO tiene popup ni tooltip: no hay nada que centrar sobre él y
    // por tanto no puede reproducir el fallo de StyledPopup (left negativo al
    // estar a menos de medio popup de un borde). Si algún día se le añade uno,
    // hay que acotarlo en LOS DOS EJES contra la pantalla, con el
    // Math.max(0, Math.min(x, maxX)) que ya se usó allí.
    // Tampoco usa layer.enabled en ningún sitio, así que nada se renderiza en
    // una textura del tamaño exacto del elemento ni se recorta por ese camino.
    //
    // ANCHO INVARIANTE: chipShown y telemetryShown solo dependen de hechos de
    // hardware (cuántas GPUs hay, si una es NVIDIA) que quedan fijados en el
    // descubrimiento. El veredicto del chip, el estado de energía y los números
    // cambian el CONTENIDO, nunca el tamaño: las dos reglas invisibles de abajo
    // clavan el ancho al del texto más largo posible de cada modo. Resultado:
    // el widget pasa de 0 a su ancho final UNA vez, al arrancar el shell, y no
    // se vuelve a mover — ni al dormirse la GPU, ni al cambiar de ventana, ni
    // al alternar dGPU/iGPU. No hay reflujo que empuje a nadie fuera de la
    // barra, así que no hace falta animarlo (y animarlo sería peor: relayout
    // de la barra entera en cada frame de la transición).
    visible: root.shown
    implicitWidth: root.shown ? group.implicitWidth : 0
    implicitHeight: Appearance.sizes.baseBarHeight

    // ══════════════════════════════ Lógica ════════════════════════════════

    // Ventana enfocada: focusHistoryID === 0.
    // Verificado en Hyprland 0.55.4: WindowHistoryTracker.cpp::track() hace
    // m_history.emplace_back(w), o sea el historial va de más ANTIGUA a más
    // reciente; y HyprCtl.cpp::getFocusHistoryID publica `size - i - 1`
    // («reverse order for backwards compat»), con lo que la enfocada da 0.
    // Se filtra el centinela de fullscreen (size[0] <= 1): con una ventana en
    // fullscreen las otras de su columna se aparcan en at ≈ [-100000,-100000].
    function focusedPid() {
        const list = HyprlandData.windowList;
        if (!list || list.length === 0) return -1;
        for (let i = 0; i < list.length; ++i) {
            const w = list[i];
            if (!w || w.focusHistoryID !== 0) continue;
            if ((w.size?.[0] ?? 0) <= 1) continue; // ventana aparcada, no real
            return w.pid ?? -1;
        }
        return -1;
    }

    function requestChipScan() {
        if (!root.cfgEnable || !root.cfgChip || !root.hybrid) return;
        const pid = root.focusedPid();
        if (pid <= 0) return;
        if (fdScanProc.running) return; // nada síncrono ni encolado en el handler
        root.lastScannedPid = pid;
        fdScanProc.command = ["sh", "-c", root.fdScanScript, "gpuchip",
                              String(pid), String(root.cfgChildDepth)];
        fdScanProc.running = true;
    }

    // ►►► ÚNICO camino hacia nvidia-smi en todo el archivo ◄◄◄
    // Si esto retorna antes de tiempo, la GPU no se despierta. Punto.
    function sampleTelemetry() {
        if (!root.cfgEnable) return;
        if (!root.cfgAllowSmi) return;          // opt-in de nivel 2
        if (root.cfgTelemetry === "off") return;
        if (!root.nvidiaPresent || !root.smiAvailable) return;
        if (root.releasing) return;
        // ►►► LA GUARDA ◄◄◄
        // Nunca se consulta una GPU que el kernel declara dormida.
        if (!root.safeToQuery) return;
        if (smiProc.running) return;
        // `timeout 3`: en el PR #1858 de end-4 el mantenedor midió que, con la
        // GPU deshabilitada, nvidia-smi NO falla rápido — se cuelga, y la CPU
        // se va del 1 % al 5 %. Un nvidia-smi sin guarda es doblemente malo: o
        // despierta la GPU (10 W) o cuelga el poller (5 % CPU). El techo duro
        // de 3 s convierte el cuelgue en un fallo limpio que apaga la
        // telemetría en onExited, en vez de quemar CPU indefinidamente.
        smiProc.command = ["timeout", "3", "nvidia-smi", "-i", root.nvAddr,
                           "--query-gpu=utilization.gpu,temperature.gpu,memory.used,memory.total",
                           "--format=csv,noheader,nounits"];
        smiProc.running = true;
    }

    function applyVerdict(v) {
        if (v === "" || v === root.displayVerdict) return;
        if (permanenceTimer.running) {
            root.pendingVerdict = v; // se aplicará al vencer la permanencia
            return;
        }
        root.displayVerdict = v;
        root.pendingVerdict = "";
        permanenceTimer.restart();
    }

    onPowerStateChanged: {
        if (!root.knownAsleep) {
            root.awakeSticky = true;
            stickyTimer.restart();
        } else {
            // La GPU se durmió de verdad: los valores viejos ya no valen.
            root.utilPct = -1;
            root.tempC = -1;
            root.vramUsedMb = -1;
            root.samplesSinceRelease = 0;
        }
    }

    // Re-escanea el chip cuando cambia la ventana enfocada. Sin Timer
    // periódico: HyprlandData ya ejecuta `hyprctl clients -j` en cada evento,
    // así que consumirlo no añade coste de IPC. Solo actúa si el PID cambió de
    // verdad, y lo único que hace en el handler es lanzar un proceso (el
    // socket2 de Hyprland desconecta a los clientes lentos: nada pesado aquí).
    Connections {
        target: HyprlandData
        function onWindowListChanged() {
            if (!root.cfgEnable || !root.cfgChip || !root.hybrid) return;
            const pid = root.focusedPid();
            if (pid <= 0 || pid === root.lastScannedPid) return;
            root.requestChipScan();
            // Un juego puede tardar en abrir su fd a /dev/nvidiaN después de
            // mapear la ventana; un único reintento diferido lo caza.
            confirmTimer.restart();
        }
    }

    // ═══════════════════════════ Descubrimiento ═══════════════════════════
    // Una sola vez, al arrancar. Enumera GPUs PCI leyendo atributos de sysfs
    // con redirección del shell (`read < fichero`): es un builtin, CERO forks,
    // y ninguno de esos ficheros entra al driver.
    //   class 0x0300xx = VGA controller, 0x0302xx = 3D controller
    //   vendor 0x10de = NVIDIA, 0x8086 = Intel, 0x1002 = AMD
    // Se cachea la dirección PCI para no re-enumerar nunca más (es lo que hacen
    // gpu-usage-waybar y Noctalia; re-enumerar en cada tick es el antipatrón).
    readonly property string discoverScript: `
for d in /sys/bus/pci/devices/*/; do
  [ -r "$d/class" ] || continue
  read -r c < "$d/class" || continue
  case "$c" in 0x0300*|0x0302*) ;; *) continue ;; esac
  [ -r "$d/vendor" ] || continue
  read -r v < "$d/vendor" || continue
  a=\${d%/}; a=\${a##*/}
  s=unsupported
  [ -r "$d/power/runtime_status" ] && read -r s < "$d/power/runtime_status"
  ct=on
  [ -r "$d/power/control" ] && read -r ct < "$d/power/control"
  printf 'GPU %s %s %s %s\\n' "$a" "$v" "$s" "$ct"
done
`

    Process {
        id: discoverProc
        // Binding, NO Component.onCompleted: Config carga su JSON de forma
        // asíncrona, así que al construirse el componente `cfgEnable` todavía
        // vale el default (false). Con onCompleted el descubrimiento no se
        // lanzaría nunca aunque el usuario lo tuviera activado en config.json.
        // Es el mismo patrón que usa Updates.qml (running: Config.ready && ...).
        command: ["sh", "-c", root.discoverScript]
        running: root.cfgEnable && !root.discovered
        environment: ({
            LANG: "C",
            LC_ALL: "C"
        })
        stdout: StdioCollector {
            id: discoverOut
            onStreamFinished: {
                let count = 0, nvA = "", othA = "", st = "unsupported", ctl = "on";
                const lines = (discoverOut.text ?? "").split("\n");
                for (let i = 0; i < lines.length; ++i) {
                    const p = lines[i].trim().split(/\s+/);
                    if (p.length < 5 || p[0] !== "GPU") continue;
                    count++;
                    if (p[2] === "0x10de") {
                        nvA = p[1];
                        st = p[3];
                        ctl = p[4];
                    } else if (othA === "") {
                        othA = p[1];
                    }
                }
                root.gpuCount = count;
                root.nvAddr = nvA;
                root.otherAddr = othA;
                root.nvControl = ctl;
                root.nvPath = nvA === "" ? "" : "/sys/bus/pci/devices/" + nvA;
                root.powerState = nvA === "" ? "unknown" : st;
                root.discovered = true;
                if (root.hybrid) root.requestChipScan();
            }
        }
        onExited: (exitCode, exitStatus) => {
            // Degradación limpia: si el descubrimiento falla, `discovered` pasa
            // a true pero nvAddr sigue vacío -> nvidiaPresent y hybrid son
            // false -> `shown` es false -> el widget desaparece él solo.
            if (exitCode !== 0) root.discovered = true;
        }
    }

    // ═══════════════════ Estado de energía (barato y seguro) ═══════════════
    // FileView sobre sysfs. Quickshell tiene una rama específica para ficheros
    // de tamaño 0 (fileview.cpp: «Mostly happens in /proc and friends, which
    // have zero sized files with content»), así que /sys se lee entero.
    // watchChanges NO sirve aquí: es inotify, y sysfs no emite esos eventos.
    // Hay que releer con reload() desde un Timer.
    FileView {
        id: runtimeStatusFile
        path: root.nvPath === "" ? "" : root.nvPath + "/power/runtime_status"
        printErrors: false          // si no existe, silencio: degradamos solos
        onLoaded: {
            const t = (runtimeStatusFile.text() ?? "").trim();
            if (t.length > 0) root.powerState = t;
        }
        onLoadFailed: error => {
            // Fail-open: desconocido NO significa dormida.
            root.powerState = "unknown";
        }
    }

    // ÚNICO Timer recurrente mientras la GPU duerme.
    // Justificación del intervalo (5 s): la lectura es un sysfs_emit() de un
    // campo cacheado — sin I/O al bus, sin despertar nada — así que su coste es
    // el de abrir y leer un fichero de 10 bytes. 5 s da reacción
    // perceptualmente inmediata sin acercarse al 1 % de CPU que el mantenedor
    // de end-4 puso como techo. Y ni siquiera corre si no hay runtime PM que
    // observar (sobremesa): allí el estado no cambia nunca.
    Timer {
        id: powerTimer
        interval: Math.max(1000, root.cfgPowerPollMs)
        repeat: true
        running: root.cfgEnable && root.discovered && root.nvidiaPresent
                 && root.runtimePm
        onTriggered: runtimeStatusFile.reload()
    }

    // ══════════════════════════ Telemetría NVIDIA ══════════════════════════
    // Timer CONDICIONAL: su `running` ya exige cfgAllowSmi y safeToQuery.
    // Aun así llama a sampleTelemetry(), que lo vuelve a comprobar. Doble llave.
    Timer {
        id: telemetryTimer
        interval: Math.max(2000, root.cfgTelemetryMs)
        repeat: true
        running: root.cfgEnable && root.discovered && root.nvidiaPresent
                 && root.continuousAllowed && root.safeToQuery && !root.releasing
        onTriggered: root.sampleTelemetry()
    }

    // ── Ventana de liberación ──────────────────────────────────────────────
    // Trampa sutil que no vi resuelta en ningún repo: si sondeamos cada 5 s una
    // GPU despierta, nuestro propio nvidia-smi renueva la ventana de ~10 s y la
    // GPU no vuelve a dormirse NUNCA, aunque la app que la despertó ya haya
    // salido. La guarda de runtime_status no basta: nosotros mismos mantenemos
    // el estado en "active". Cada N muestras soltamos el gatillo cfgReleaseMs
    // (> 10 s) para que el driver pueda suspenderla si de verdad nadie la usa,
    // y luego releemos runtime_status para enterarnos.
    Timer {
        id: releaseTimer
        interval: Math.max(11000, root.cfgReleaseMs)
        repeat: false
        onTriggered: {
            root.releasing = false;
            root.samplesSinceRelease = 0;
            runtimeStatusFile.reload(); // ¿siguió despierta sin nosotros?
        }
    }

    Process {
        id: smiProc
        running: false
        environment: ({
            LANG: "C",
            LC_ALL: "C"
        })
        stdout: StdioCollector {
            id: smiOut
            onStreamFinished: {
                const parts = (smiOut.text ?? "").trim().split(",");
                if (parts.length < 4) return;
                const u = parseInt(parts[0], 10);
                const t = parseInt(parts[1], 10);
                const mu = parseFloat(parts[2]);
                const mt = parseFloat(parts[3]);
                // Se acotan AMBOS a su rango físico. No es paranoia decorativa:
                // el hueco del texto tiene ancho fijo (la regla invisible), así
                // que un valor de 4 cifras se saldría del hueco y pintaría
                // encima del widget vecino. Acotar aquí lo hace imposible.
                if (!isNaN(u)) root.utilPct = Math.max(0, Math.min(100, u));
                if (!isNaN(t)) root.tempC = Math.max(-99, Math.min(999, t));
                if (!isNaN(mu)) root.vramUsedMb = mu;
                if (!isNaN(mt)) root.vramTotalMb = mt;

                root.samplesSinceRelease++;
                // La ventana de liberación solo tiene sentido donde hay runtime
                // PM que liberar. En el sobremesa (control="on") la GPU no se
                // iba a dormir igualmente: sería un hueco a cambio de nada.
                if (root.runtimePm && root.continuousAllowed
                    && root.cfgReleaseAfter > 0
                    && root.samplesSinceRelease >= root.cfgReleaseAfter) {
                    root.releasing = true;
                    releaseTimer.restart();
                }
            }
        }
        onExited: (exitCode, exitStatus) => {
            // nvidia-smi ausente, roto o colgado (timeout -> 124): se desactiva
            // la telemetría para el resto de la sesión. Nunca se reintenta en
            // bucle. El chip y el estado ON/OFF siguen funcionando.
            if (exitCode !== 0) {
                root.smiAvailable = false;
                root.utilPct = -1;
            }
        }
    }

    // ═════════════════════════ Escaneo de /proc/fd ═════════════════════════
    // No despierta la GPU. Solo lee el directorio de descriptores del proceso
    // en primer plano (y opcionalmente sus hijos, para el proceso GPU de
    // Chromium/Electron, que es hijo del proceso de la ventana).
    //
    // Detalle deliberado: fdinfo SOLO se lee para los fd de /dev/dri/*, nunca
    // para los de /dev/nvidia*. Da igual que nvidia-drm no exponga fdinfo
    // (verificado: cero apariciones de show_fdinfo en todo
    // open-gpu-kernel-modules/kernel-open/nvidia-drm/, y las fops del char
    // device en nv.c tampoco lo tienen) — no tocarlos es gratis y elimina la
    // duda entera. Hay una prueba dedicada a esto en test_gpu_scripts.sh.
    readonly property string fdScanScript: `
P=$1
D=$2
pids=$P
lvl=$P
i=0
while [ "$i" -lt "$D" ]; do
  next=""
  for p in $lvl; do
    for f in /proc/$p/task/*/children; do
      [ -r "$f" ] || continue
      read -r kids < "$f" || continue
      next="$next $kids"
    done
  done
  [ -n "$next" ] || break
  pids="$pids $next"
  lvl="$next"
  i=$((i+1))
done
dirs=""
for p in $pids; do
  [ -d "/proc/$p/fd" ] && dirs="$dirs /proc/$p/fd"
done
[ -n "$dirs" ] || exit 0
find $dirs -maxdepth 1 -type l -printf '%h %f %l\\n' 2>/dev/null | while read -r h f l; do
  case "$l" in
    /dev/nvidiactl) echo "NVCTL" ;;
    /dev/nvidia[0-9]*) echo "NVDEV $l" ;;
    /dev/dri/*)
      drv=""
      pdev=""
      while read -r k val; do
        case "$k" in
          drm-driver:) drv="$val" ;;
          drm-pdev:) pdev="$val" ;;
        esac
      done < "\${h}info/$f"
      [ -n "$drv" ] && echo "DRM $drv $pdev"
      ;;
  esac
done
`

    Process {
        id: fdScanProc
        running: false
        environment: ({
            LANG: "C",
            LC_ALL: "C"
        })
        stdout: StdioCollector {
            id: fdScanOut
            onStreamFinished: {
                let nvdev = 0, nvctl = 0, drv = "", pdevOther = "";
                const lines = (fdScanOut.text ?? "").split("\n");
                for (let i = 0; i < lines.length; ++i) {
                    const p = lines[i].trim().split(/\s+/);
                    if (p[0] === "NVDEV") nvdev++;
                    else if (p[0] === "NVCTL") nvctl++;
                    else if (p[0] === "DRM" && p.length >= 2) {
                        // Si algún día nvidia-drm expusiera fdinfo, no queremos
                        // que cuente como confirmación de integrada.
                        if (p[1] !== "nvidia-drm" && p[1] !== "nvidia") {
                            drv = p[1];
                            if (p.length >= 3) pdevOther = p[2];
                        }
                    }
                }
                root.scanDriver = drv;
                let v;
                if (nvdev > 0) v = "dgpu";           // referencia de energía real
                else if (drv !== "") v = "igpu";     // confirmado por DRM fdinfo
                else if (nvctl > 0) v = "icd";       // solo enumeración de ICDs
                else v = "igpu";                     // ni nvidia ni DRM: integrada
                root.scanVerdict = v;
                root.applyVerdict(v);
            }
        }
        onExited: (exitCode, exitStatus) => {
            // Si el escaneo falla NO se borra el veredicto anterior: colapsarlo
            // haría desaparecer contenido por un fallo transitorio.
        }
    }

    // ══════════════════════════════ Timers UI ═════════════════════════════
    // Permanencia mínima del veredicto: sin esto el chip vibra si un proceso
    // abre y cierra fds. Entra al instante, pero no puede volver a cambiar
    // hasta pasados cfgPermanenceMs.
    Timer {
        id: permanenceTimer
        interval: Math.max(500, root.cfgPermanenceMs)
        repeat: false
        onTriggered: {
            if (root.pendingVerdict !== "" && root.pendingVerdict !== root.displayVerdict) {
                root.displayVerdict = root.pendingVerdict;
                root.pendingVerdict = "";
                permanenceTimer.restart();
            }
        }
    }

    // Permanencia mínima del estado "despierta", para que el bloque de
    // telemetría no parpadee entre ON y OFF en los bordes de la suspensión.
    Timer {
        id: stickyTimer
        interval: Math.max(500, root.cfgPermanenceMs)
        repeat: false
        onTriggered: root.awakeSticky = !root.knownAsleep
    }

    // Reintento único tras cambiar de ventana. No es polling: repeat false.
    Timer {
        id: confirmTimer
        interval: 1500
        repeat: false
        onTriggered: {
            root.lastScannedPid = -1; // fuerza que el escaneo se repita
            root.requestChipScan();
        }
    }

    // Da tiempo a que reload() actualice powerState antes de decidir el peek.
    Timer {
        id: peekTimer
        interval: 120
        repeat: false
        onTriggered: {
            if (root.peekRequested) {
                root.peekRequested = false;
                root.sampleTelemetry();
            }
        }
    }

    // ═══════════════════════════════ Visual ════════════════════════════════

    // Reglas invisibles: fijan el ancho al del texto más largo posible de cada
    // modo, para que el widget NO baile cuando la GPU se duerme (OFF) ni cuando
    // cambian los números. Se miden con el mismo StyledText del tema, así que
    // sobreviven a cualquier cambio de fuente o de tamaño del Material You
    // regenerado con el wallpaper.
    StyledText {
        id: readoutRuler
        visible: false
        // Sin nvidia-smi autorizado el texto más ancho posible es "OFF"; con él,
        // "100% 100°". El ancho es constante DENTRO de cada modo, y el modo es
        // una opción de config que no cambia en caliente.
        text: root.cfgAllowSmi ? "100% 100°" : "OFF"
        font.pixelSize: Appearance.font.pixelSize.smaller
    }
    StyledText {
        id: chipRuler
        visible: false
        text: "dGPU"
        font.pixelSize: Appearance.font.pixelSize.smaller
    }

    BarGroup {
        id: group
        anchors.verticalCenter: parent.verticalCenter

        // ── Chip dGPU / iGPU ──────────────────────────────────────────────
        // La paleta se regenera con cada wallpaper, así que NO se puede
        // depender del color para distinguir los dos estados. Van TRES señales
        // además del color: glifo distinto, relleno del icono (fill 1 vs 0) y
        // el propio texto. Cualquiera de las tres basta para leerlo de un
        // vistazo aunque el contraste salga malo.
        RowLayout {
            id: chipRow
            visible: root.chipShown
            spacing: 3
            Layout.alignment: Qt.AlignVCenter

            MaterialSymbol {
                Layout.alignment: Qt.AlignVCenter
                text: root.displayVerdict === "dgpu" ? "bolt" : "eco"
                fill: root.displayVerdict === "dgpu" ? 1 : 0
                iconSize: Appearance.font.pixelSize.normal
                color: root.displayVerdict === "dgpu"
                       ? Appearance.colors.colPrimary
                       : Appearance.colors.colSubtext
                Behavior on color {
                    animation: Appearance.animation.elementMoveFast.colorAnimation.createObject(this)
                }
            }

            Item { // ancho fijo: "dGPU" e "iGPU" no miden igual en toda fuente
                Layout.alignment: Qt.AlignVCenter
                implicitWidth: chipRuler.implicitWidth
                implicitHeight: chipRuler.implicitHeight
                StyledText {
                    anchors.fill: parent
                    horizontalAlignment: Text.AlignHCenter
                    elide: Text.ElideRight
                    // Hasta el primer escaneo no se afirma nada: "—".
                    text: root.displayVerdict === "" ? "—"
                          : (root.displayVerdict === "dgpu" ? "dGPU" : "iGPU")
                    font.pixelSize: Appearance.font.pixelSize.smaller
                    color: root.displayVerdict === "dgpu"
                           ? Appearance.colors.colOnLayer1
                           : Appearance.colors.colSubtext
                    Behavior on color {
                        animation: Appearance.animation.elementMoveFast.colorAnimation.createObject(this)
                    }
                }
            }

            // Matiz honesto: solo /dev/nvidiactl. El driver NO tiene referencia
            // de energía; es la enumeración de ICDs que hace Electron. Un punto
            // pequeño, no un color: se ve aunque la paleta salga sin contraste.
            // Reserva su hueco SIEMPRE (opacity, no visible) para no cambiar el
            // ancho del widget al alternar de ventana.
            Rectangle {
                Layout.alignment: Qt.AlignVCenter
                implicitWidth: 3
                implicitHeight: 3
                radius: Appearance.rounding.full
                color: Appearance.colors.colSubtext
                opacity: root.displayVerdict === "icd" ? 1 : 0
                Behavior on opacity {
                    animation: Appearance.animation.elementMoveFast.numberAnimation.createObject(this)
                }
            }
        }

        // ── Telemetría / estado de energía ────────────────────────────────
        RowLayout {
            id: telemetryRow
            visible: root.telemetryShown
            spacing: 3
            Layout.alignment: Qt.AlignVCenter
            Layout.leftMargin: root.chipShown ? 6 : 0

            MaterialSymbol {
                Layout.alignment: Qt.AlignVCenter
                text: "memory"
                fill: root.gpuAwake ? 1 : 0
                iconSize: Appearance.font.pixelSize.normal
                color: root.gpuAwake ? Appearance.colors.colOnLayer1
                                     : Appearance.colors.colSubtext
                Behavior on color {
                    animation: Appearance.animation.elementMoveFast.colorAnimation.createObject(this)
                }
            }

            // Ancho CLAVADO al de la regla: dormida u ocupada, el widget ocupa
            // exactamente lo mismo y nada a su derecha se mueve.
            Item {
                Layout.alignment: Qt.AlignVCenter
                implicitWidth: readoutRuler.implicitWidth
                implicitHeight: readoutRuler.implicitHeight

                StyledText {
                    // Segundo cinturón: el texto se recorta al hueco en vez de
                    // desbordarlo. Ancho fijo + elide = imposible pintar fuera
                    // aunque el contenido crezca por donde no se espera.
                    anchors.fill: parent
                    horizontalAlignment: Text.AlignHCenter
                    elide: Text.ElideRight
                    font.pixelSize: Appearance.font.pixelSize.smaller
                    color: root.haveReadout ? Appearance.colors.colOnLayer1
                                            : Appearance.colors.colSubtext
                    text: {
                        if (!root.gpuAwake) return "OFF";
                        if (!root.smiEnabled) return "ON";
                        if (root.releasing) return "···";
                        if (!root.haveReadout) return "···";
                        return root.utilPct + "% " + (root.tempC >= 0 ? root.tempC + "°" : "");
                    }
                    Behavior on color {
                        animation: Appearance.animation.elementMoveFast.colorAnimation.createObject(this)
                    }
                }
            }
        }
    }

    // Clic CENTRAL: muestrea una vez bajo demanda ("peek").
    // Se usa el botón central a propósito: en la barra este widget vive dentro
    // de un FocusedScrollMouseArea, que fija acceptedButtons: Qt.LeftButton y
    // usa el clic izquierdo para abrir el sidebar. Aceptar el izquierdo aquí se
    // lo robaría. El central no lo escucha nadie.
    // Sigue pasando por sampleTelemetry(), así que sobre una GPU dormida no
    // hace nada: la invariante se mantiene también por esta vía.
    MouseArea {
        anchors.fill: parent
        enabled: root.telemetryShown && root.cfgAllowSmi
        acceptedButtons: Qt.MiddleButton
        onClicked: {
            runtimeStatusFile.reload();
            root.peekRequested = true;
            peekTimer.restart();
        }
    }
}
