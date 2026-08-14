import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import Quickshell.Hyprland
import Quickshell.Services.Pipewire
import qs.services
import qs.modules.common
import qs.modules.common.widgets

/**
 * AlertLine — reportero de excepciones para la barra.
 *
 * Dos piezas en un solo archivo, ambas con ancho 0 cuando no hay nada que decir:
 *
 *   1) EL RENGLON: una linea de texto en minusculas, sin icono, que aparece
 *      cuando una regla de umbral se dispara. Nunca dos a la vez (cola con
 *      prioridad). Se muestra unos segundos y colapsa a un punto mientras la
 *      condicion siga activa. Hover reexpande, clic silencia esa regla un rato.
 *
 *   2) EL TESTIGO: punto rojo + etiqueta corta (MIC / REC / SHARE) que solo
 *      existe mientras hay captura real de microfono o de pantalla.
 *
 * Reglas duras respetadas:
 *   - Cero animaciones infinitas: solo transiciones por cambio de estado.
 *   - Sin polling agresivo: el Timer de 1 s solo corre mientras hay una regla
 *     pendiente o armada; en reposo no hay ningun temporizador vivo salvo el
 *     de disco (opcional, 5 min).
 *   - Histeresis + permanencia minima en todas las reglas.
 *   - Fallo aislado: cada regla se evalua en try/catch; si su fuente no existe
 *     la regla se apaga sola y el resto del widget sigue vivo.
 *   - Nada se dibuja fuera de la caja propia: sin PanelWindow, sin margenes
 *     calculados a mano, sin layer.enabled. Ver "ANCHO Y BORDES" mas abajo.
 */
Item {
    id: root

    // ---------------------------------------------------------------------
    // CONFIGURACION
    // ---------------------------------------------------------------------
    // `Config.options` es un JsonAdapter con propiedades DECLARADAS ESTATICAMENTE:
    // no admite claves dinamicas. Si `bar.alertLine` no esta declarado en
    // Config.qml, vale `undefined` PARA SIEMPRE por mucho que el usuario lo
    // escriba en config.json. El bloque a insertar va en la nota de entrega.
    //
    // Escotilla de emergencia: si prefieres NO tocar Config.qml, pon esto a true
    // y el widget arranca con los defaults de abajo. Si el bloque existe, manda
    // el bloque.
    readonly property bool fallbackEnable: false

    readonly property var cfg: Config.options?.bar?.alertLine ?? null

    readonly property bool enableLine: cfg?.enable ?? root.fallbackEnable
    readonly property bool enableCapture: root.enableLine && (cfg?.capture?.enable ?? true)

    readonly property int showMs: cfg?.showMs ?? 6000            // expandido antes de colapsar
    readonly property int enterMs: cfg?.enterMs ?? 4000          // confirmacion antes de anunciar
    readonly property int minMs: cfg?.minDwellMs ?? 4000         // permanencia minima una vez visible
    readonly property int snoozeMs: cfg?.snoozeMs ?? 600000      // 10 min al hacer clic

    readonly property bool diskEnable: cfg?.disk?.enable ?? true
    readonly property string diskPath: cfg?.disk?.path ?? "/"
    readonly property int diskIntervalMs: cfg?.disk?.intervalMs ?? 300000  // 5 min

    readonly property bool micHideWhenMuted: cfg?.capture?.hideWhenMuted ?? true
    // pgrep se dispara SOLO por evento de Hyprland, nunca en bucle. Lista vacia
    // = no se ejecuta ningun proceso y REC queda desactivado.
    readonly property var recorderProcesses: cfg?.capture?.recorderProcesses ?? ["wf-recorder", "wl-screenrec", "gpu-screen-recorder"]
    readonly property var stopRecorderCommand: cfg?.capture?.stopCommand ?? ["pkill", "-INT", "wf-recorder"]

    // ---------------------------------------------------------------------
    // ANCHO Y BORDES  (anti-recorte)
    // ---------------------------------------------------------------------
    // El renglon es texto CENTRADO: es exactamente la forma del bug de
    // StyledPopup (centrar sin acotar => x negativa => recorte). Aqui no puede
    // pasar porque este widget NUNCA calcula una posicion absoluta: se dibuja
    // en linea dentro del RowLayout de la barra y el layout decide su x.
    // Ademas acotamos su ancho contra la pantalla, no contra el texto.
    readonly property real screenW: root.QsWindow.window?.screen?.width ?? 1920
    readonly property real maxTotalWidth: Math.max(0, Math.min(cfg?.maxWidth ?? 420, Math.round(screenW * 0.26)))
    readonly property real maxCaptureWidth: Math.min(150, root.maxTotalWidth * 0.42)
    // El renglon cede sitio al testigo: la suma nunca puede pasarse del techo.
    readonly property real maxLineWidth: Math.max(0, root.maxTotalWidth - (capturePart.visible ? root.maxCaptureWidth + row.spacing : 0))

    readonly property real padH: 8
    readonly property real dotSize: 8

    implicitWidth: row.implicitWidth
    implicitHeight: Appearance.sizes.baseBarHeight
    visible: row.implicitWidth > 0
    // Garantia final: si la barra se quedara sin sitio y el layout comprimiera
    // este item por debajo de su implicitWidth, el contenido se recorta DENTRO
    // de la caja en vez de desbordarse sobre el systray.
    clip: true

    // Defaults por si se instancia dentro de un Layout (que es el caso normal).
    // Si el padre no es un Layout, estas lineas no hacen nada y el techo lo
    // sigue imponiendo `implicitWidth`.
    Layout.alignment: Qt.AlignVCenter
    Layout.maximumWidth: root.maxTotalWidth
    // minimumWidth 0 = ante falta de sitio cedemos nosotros. Preferimos
    // truncarnos a empujar a los vecinos fuera de la pantalla.
    Layout.minimumWidth: 0
    Layout.fillWidth: false

    // ---------------------------------------------------------------------
    // DETECCION DE CAPTURA  (fuente unica de verdad, compartida con el renglon)
    // ---------------------------------------------------------------------
    // NO se usa el servicio Privacy de end-4: son 16 lineas que declaran
    // `property bool` y le asignan un array filtrado; en JS un array siempre es
    // truthy, asi que screenSharing y micActive valen true de forma permanente.
    // (Ademas no lo usa nadie en todo el shell: es codigo muerto.)

    // Consumidores del microfono. Pedir que el ORIGEN sea un Audio/Source real
    // ya descarta por construccion la trampa clasica de este widget: los
    // medidores de nivel (cava, visualizadores, barras de volumen) capturan del
    // MONITOR de un sink, y en PipeWire los puertos monitor viven en el propio
    // nodo Audio/Sink -> el origen de ese enlace es AudioSink, no AudioSource.
    // Esto importa aqui de verdad: end-4 lanza `cava` desde MediaControls.qml.
    readonly property var micConsumers: {
        if (!Pipewire.ready)
            return [];
        const groups = Pipewire.linkGroups?.values ?? [];
        const out = [];
        for (let i = 0; i < groups.length; i++) {
            const g = groups[i];
            if (!g || !g.source || !g.target)
                continue;
            if (g.source.type !== PwNodeType.AudioSource)
                continue;
            if (g.target.type !== PwNodeType.AudioInStream)
                continue;
            if (out.indexOf(g.target) < 0)
                out.push(g.target);
        }
        return out;
    }

    // Nodos Video/Source con consumidor. xdg-desktop-portal-hyprland publica su
    // stream de screencast justo asi (media.class = "Video/Source"), de modo que
    // un Video/Source ENLAZADO significa que alguien esta recibiendo pantalla.
    readonly property var videoSources: {
        if (!Pipewire.ready)
            return [];
        const groups = Pipewire.linkGroups?.values ?? [];
        const out = [];
        for (let i = 0; i < groups.length; i++) {
            const g = groups[i];
            if (!g || !g.source)
                continue;
            if (g.source.type !== PwNodeType.VideoSource)
                continue;
            if (out.indexOf(g.source) < 0)
                out.push(g.source);
        }
        return out;
    }

    // Enlazamos SOLO los pocos nodos que ya sabemos conectados: acotado y barato.
    // Hace falta para leer `properties` (invalido sin binding) y para poder
    // escribir `audio.muted` en la fuente por defecto.
    PwObjectTracker {
        objects: {
            const list = [];
            if (Pipewire.defaultAudioSource)
                list.push(Pipewire.defaultAudioSource);
            const a = root.micConsumers;
            for (let i = 0; i < a.length; i++)
                list.push(a[i]);
            const b = root.videoSources;
            for (let j = 0; j < b.length; j++)
                list.push(b[j]);
            return list;
        }
    }

    // Misma regla que usa Quickshell en C++ para su `isMonitor` interno
    // (node.cpp: media.category == "Monitor" || "Manager"), pero ese campo NO
    // esta expuesto a QML, asi que lo leemos nosotros. No usamos
    // PwNodeLinkTracker (que si filtra monitores) porque su updateLinks() hace
    // `return` en vez de `continue` al toparse con un monitor: aborta el bucle y
    // deja la lista sin actualizar, justo en el caso que nos interesa.
    readonly property var meterNameRegex: /peak|monitor|cava|visuali|vumeter|level.?meter|pavucontrol/
    function looksLikeMeter(node) {
        if (!node)
            return true;
        const p = node.properties;
        if (p) {
            const cat = p["media.category"];
            if (cat === "Monitor" || cat === "Manager")
                return true;
        }
        const hay = ((node.name ?? "") + " " + (node.description ?? "")).toLowerCase();
        return root.meterNameRegex.test(hay);
    }

    // No prometemos deteccion de camara: Quickshell solo mapea siete media.class
    // y "Stream/Input/Video" no esta entre ellos, ademas de que las webcams V4L2
    // casi nunca aparecen como nodos PipeWire. Lo unico que hacemos es NO
    // etiquetar una camara como SHARE si por configuracion apareciera.
    readonly property var cameraNameRegex: /v4l2|\/dev\/video|webcam|camera|camara|libcamera|integrated.?cam/
    function looksLikeCamera(node) {
        const hay = ((node?.name ?? "") + " " + (node?.description ?? "")).toLowerCase();
        return root.cameraNameRegex.test(hay);
    }

    readonly property bool micMuted: Pipewire.defaultAudioSource?.audio?.muted ?? false
    readonly property bool micActive: {
        if (!root.enableLine)
            return false;
        const a = root.micConsumers;
        let any = false;
        for (let i = 0; i < a.length; i++) {
            if (!root.looksLikeMeter(a[i])) {
                any = true;
                break;
            }
        }
        if (!any)
            return false;
        return !(root.micHideWhenMuted && root.micMuted);
    }

    readonly property bool shareActive: {
        const a = root.videoSources;
        for (let i = 0; i < a.length; i++) {
            if (!root.looksLikeCamera(a[i]))
                return true;
        }
        return false;
    }

    // --- Grabacion (REC) -------------------------------------------------
    // Hyprland 0.55 emite `screencast>>ESTADO,TIPO` (0=monitor, 1=ventana,
    // 2=region). PERO ese evento NO sirve por si solo en esta maquina: el propio
    // shell de end-4 usa ScreencopyView con live:true en el Overview, el Dock, el
    // selector de region y el traductor de pantalla, y todos pasan por
    // ScreenshareManager -> abrir el overview dispararia "REC". Por eso el evento
    // solo se usa como DISPARADOR de una comprobacion puntual del proceso.
    property int hyprCastCount: 0
    property bool recActive: false

    Connections {
        target: Hyprland
        // El socket2 tiene cola de 64 eventos y desconecta al cliente lento:
        // aqui no se hace nada pesado ni sincrono, solo dos comparaciones.
        function onRawEvent(event) {
            if (event.name !== "screencast")
                return;
            const started = (event.data ?? "").charAt(0) === "1";
            root.hyprCastCount = Math.max(0, root.hyprCastCount + (started ? 1 : -1));
            if (root.hyprCastCount === 0) {
                root.recActive = false;
                recProbeDelay.stop();
            } else {
                recProbeDelay.restart();
            }
        }
    }

    Timer {
        id: recProbeDelay
        // 1.2 s: las capturas de un solo fotograma (grim, congelar pantalla) se
        // auto-cierran a los 500 ms por el temporizador interno de Hyprland, y
        // los previews del shell quedan filtrados despues por el pgrep.
        interval: 1200
        repeat: false
        onTriggered: root.probeRecorder()
    }

    function probeRecorder() {
        if (!root.enableCapture || root.recorderProcesses.length === 0) {
            root.recActive = false;
            return;
        }
        recProbe.running = false;
        recProbe.running = true;
    }

    Process {
        id: recProbe
        // `pgrep -x 'a|b|c'`: solo lee /proc, no toca la GPU, no escribe nada y
        // termina en microsegundos. Se lanza por transicion de screencast, jamas
        // en un Timer.
        command: ["pgrep", "-x", root.recorderProcesses.join("|")]
        stdout: StdioCollector {
            id: recProbeOut
            onStreamFinished: root.recActive = (recProbeOut.text ?? "").trim().length > 0
        }
    }

    readonly property string captureLabel: {
        if (!root.enableCapture)
            return "";
        const parts = [];
        if (root.micActive)
            parts.push("MIC");
        if (root.recActive)
            parts.push("REC");
        else if (root.shareActive)
            parts.push("SHARE");
        return parts.join(" · ");
    }

    function cutSource() {
        // "Clic corta la fuente si se puede": el microfono si se puede.
        if (root.micActive && Pipewire.defaultAudioSource?.audio) {
            Pipewire.defaultAudioSource.audio.muted = true;
            return;
        }
        // La grabacion tambien: SIGINT hace que wf-recorder cierre el mp4 bien.
        if (root.recActive && root.stopRecorderCommand.length > 0) {
            Quickshell.execDetached(root.stopRecorderCommand);
            return;
        }
        // Compartir pantalla por portal NO se puede cortar desde aqui: la sesion
        // la posee xdg-desktop-portal, no hay dispatcher de Hyprland ni API de
        // Quickshell para terminarla. No hacemos nada destructivo.
    }

    // ---------------------------------------------------------------------
    // FUENTES NUMERICAS AUXILIARES
    // ---------------------------------------------------------------------
    property var diskUsedFraction: NaN

    Timer {
        id: diskTimer
        // 5 min. `df` sobre un punto de montaje es una llamada statfs: no hay
        // razon para mirarlo mas seguido, un disco no se llena en 3 segundos.
        interval: root.diskIntervalMs
        running: root.enableLine && root.diskEnable
        repeat: true
        triggeredOnStart: true
        onTriggered: {
            dfProbe.running = false;
            dfProbe.running = true;
        }
    }

    Process {
        id: dfProbe
        // `df -P -k <ruta>`: solo lectura, salida POSIX de columnas estables.
        command: ["df", "-P", "-k", root.diskPath]
        stdout: StdioCollector {
            id: dfOut
            onStreamFinished: {
                const lines = (dfOut.text ?? "").trim().split("\n");
                const last = lines[lines.length - 1] ?? "";
                const m = last.match(/(\d+)%/);
                root.diskUsedFraction = m ? (Number(m[1]) / 100) : NaN;
            }
        }
    }

    // Weather solo se DEREFERENCIA si el usuario ya tiene el clima activado.
    // Los singletons de QML se instancian al primer acceso, y tocar `Weather`
    // arranca su fetch periodico a wttr.in: no queremos encenderlo nosotros.
    readonly property bool weatherOn: (Config.options?.bar?.weather?.enable ?? false) && (cfg?.weather?.enable ?? true)
    readonly property var weatherUv: {
        if (!root.weatherOn)
            return NaN;
        const v = Number(Weather.data?.uv ?? NaN);
        return isFinite(v) ? v : NaN;
    }
    readonly property var weatherPrecip: {
        if (!root.weatherOn)
            return NaN;
        // `precip` llega como cadena con unidad ("0.4 mm"); parseFloat basta.
        const v = parseFloat(Weather.data?.precip ?? "");
        return isFinite(v) ? v : NaN;
    }

    // Bluetooth: una desconexion es un EVENTO, no un umbral. Lo enganchamos unos
    // segundos para que la cola de prioridad lo pueda tratar como los demas.
    property var btPrevNames: []
    property bool btSeeded: false
    property string btLostName: ""
    property bool btLostLatch: false

    Timer {
        id: btLatch
        interval: 12000
        repeat: false
        onTriggered: root.btLostLatch = false
    }

    Connections {
        target: BluetoothStatus
        function onConnectedDevicesChanged() {
            root.checkBluetooth();
        }
    }

    function checkBluetooth() {
        // `connectedDevices` esta en el BluetoothStatus de esta maquina pero el
        // brief solo nombra el servicio, no sus propiedades: si no existiera,
        // esto se apaga solo y no arrastra al resto del widget.
        try {
            const listNow = (BluetoothStatus.connectedDevices ?? []).map(d => (d?.name ?? "")).filter(n => n.length > 0);
            const gone = root.btPrevNames.filter(n => listNow.indexOf(n) < 0);
            root.btPrevNames = listNow;
            if (!root.btSeeded) {
                // La primera poblacion no es una desconexion.
                root.btSeeded = true;
                return;
            }
            if (gone.length > 0) {
                root.btLostName = String(gone[0]).toLowerCase();
                root.btLostLatch = true;
                btLatch.restart();
            }
        } catch (e) {
            root.btLostLatch = false;
        }
    }

    // ---------------------------------------------------------------------
    // REGLAS  — extensibles con DATOS, no con codigo.
    // ---------------------------------------------------------------------
    // Descriptor:
    //   id       identificador estable (para el snooze y para elapsed)
    //   prio     0 critico > 1 privacidad > 2 recurso > 3 ambiental
    //   above    true = dispara al SUBIR de `threshold`; false = al BAJAR
    //   threshold umbral de entrada
    //   margin   margen de histeresis: se sale en threshold -+ margin
    //   value()  numero, o NaN si la regla no aplica / la fuente no existe
    //   text()   texto largo, en minusculas, sin icono
    //   short()  variante corta (opcional) para cuando el largo no cabe
    //   persist  true = colapsa a punto; false = se dice una vez y desaparece
    //   enterMs / minMs  overrides del retardo de confirmacion y la permanencia
    readonly property var rules: [
        {
            "id": "bateria",
            "prio": 0,
            "above": false,
            "threshold": (Config.options?.battery?.low ?? 20) / 100,
            "margin": 0.05,
            "enterMs": 1500,
            "value": function () {
                if (!Battery.available || Battery.isCharging)
                    return NaN;
                return Battery.percentage;
            },
            "text": function () {
                const pct = Math.round(Battery.percentage * 100);
                // `timeToEmpty` (segundos, 0 al cargar) existe en el Battery.qml
                // de esta maquina aunque no venga en la lista del brief; si no
                // estuviera, `undefined` cae al ramal corto sin romper nada.
                const t = Battery.timeToEmpty;
                if (typeof t === "number" && isFinite(t) && t > 0)
                    return "batería " + pct + " % · " + root.fmtDur(t);
                return "batería " + pct + " %";
            },
            "short": function () {
                return "batería " + Math.round(Battery.percentage * 100) + " %";
            },
            "persist": true
        },
        {
            "id": "microfono",
            "prio": 1,
            "above": true,
            "threshold": 1,
            "margin": 0,
            "enterMs": 700,
            "minMs": 2500,
            "value": function () {
                return root.micActive ? 1 : 0;
            },
            "text": function () {
                return "micrófono abierto";
            },
            // false: el TESTIGO es la forma persistente de esto. El renglon solo
            // lo anuncia una vez y se quita, para no decir lo mismo dos veces.
            "persist": false
        },
        {
            "id": "pantalla",
            "prio": 1,
            "above": true,
            "threshold": 1,
            "margin": 0,
            "enterMs": 700,
            "minMs": 2500,
            "value": function () {
                return (root.shareActive || root.recActive) ? 1 : 0;
            },
            "text": function () {
                return root.recActive ? "grabando pantalla" : "pantalla compartida";
            },
            "persist": false
        },
        {
            "id": "cpu",
            "prio": 2,
            "above": true,
            "threshold": (Config.options?.bar?.resources?.cpuWarningThreshold ?? 90) / 100,
            "margin": 0.10,
            // 20 s: una compilacion corta o abrir el navegador no es una noticia.
            // Solo reporta carga SOSTENIDA.
            "enterMs": 20000,
            "value": function () {
                return ResourceUsage.cpuUsage;
            },
            "text": function () {
                return "cpu " + Math.round(ResourceUsage.cpuUsage * 100) + " % · " + root.fmtDur(root.elapsedSec("cpu"));
            },
            "short": function () {
                return "cpu " + Math.round(ResourceUsage.cpuUsage * 100) + " %";
            },
            "persist": true
        },
        {
            "id": "ram",
            "prio": 2,
            "above": true,
            "threshold": (Config.options?.bar?.resources?.memoryWarningThreshold ?? 95) / 100,
            "margin": 0.05,
            "enterMs": 10000,
            "value": function () {
                return ResourceUsage.memoryUsedPercentage;
            },
            "text": function () {
                return "ram " + Math.round(ResourceUsage.memoryUsedPercentage * 100) + " %";
            },
            "persist": true
        },
        {
            "id": "swap",
            "prio": 2,
            "above": true,
            "threshold": (Config.options?.bar?.resources?.swapWarningThreshold ?? 85) / 100,
            "margin": 0.05,
            "enterMs": 10000,
            "value": function () {
                // Sin swap configurado, swapTotal vale 1 (kB) por defecto.
                if (!(ResourceUsage.swapTotal > 1))
                    return NaN;
                return ResourceUsage.swapUsedPercentage;
            },
            "text": function () {
                return "swap " + Math.round(ResourceUsage.swapUsedPercentage * 100) + " %";
            },
            "persist": true
        },
        {
            "id": "disco",
            "prio": 2,
            "above": true,
            "threshold": root.cfg?.disk?.threshold ?? 0.92,
            "margin": 0.03,
            "enterMs": 1000,
            "value": function () {
                return root.diskUsedFraction;
            },
            "text": function () {
                return "sin espacio en " + root.diskPath + " · " + Math.round(root.diskUsedFraction * 100) + " %";
            },
            "short": function () {
                return "sin espacio en " + root.diskPath;
            },
            "persist": true
        },
        {
            "id": "bluetooth",
            "prio": 3,
            "above": true,
            "threshold": 1,
            "margin": 0,
            "enterMs": 300,
            "minMs": 3000,
            "value": function () {
                return root.btLostLatch ? 1 : 0;
            },
            "text": function () {
                return "bluetooth: " + root.btLostName + " desconectado";
            },
            "short": function () {
                return "bt: " + root.btLostName;
            },
            "persist": false
        },
        {
            "id": "uv",
            "prio": 3,
            "above": true,
            "threshold": root.cfg?.weather?.uvThreshold ?? 8,
            "margin": 1,
            "enterMs": 1000,
            "value": function () {
                return root.weatherUv;
            },
            "text": function () {
                return "uv " + Math.round(root.weatherUv) + " · protégete";
            },
            "short": function () {
                return "uv " + Math.round(root.weatherUv);
            },
            "persist": true
        },
        {
            "id": "lluvia",
            "prio": 3,
            "above": true,
            "threshold": root.cfg?.weather?.precipThreshold ?? 1.0,
            "margin": 0.4,
            "enterMs": 1000,
            "value": function () {
                return root.weatherPrecip;
            },
            "text": function () {
                return "lluvia · " + root.weatherPrecip + " mm";
            },
            "persist": true
        }
    ]

    // ---------------------------------------------------------------------
    // MAQUINA DE ESTADOS  (histeresis + permanencia minima + cero parpadeo)
    // ---------------------------------------------------------------------
    property var states: []
    property int activeIndex: -1
    property bool showing: false
    property bool hovered: false
    property bool needTick: false
    property string lineTextLong: ""
    property string lineTextShort: ""

    readonly property bool expanded: root.showing || root.hovered

    // Severidad de la regla en pantalla. El color se anima con
    // `elementMoveFast.colorAnimation`, que es la UNICA variante de
    // Appearance.animation que expone colorAnimation.
    readonly property int activePrio: (root.activeIndex >= 0 && root.activeIndex < root.rules.length) ? (root.rules[root.activeIndex].prio ?? 3) : 3
    readonly property color severityColor: {
        if (root.activePrio === 0)
            return Appearance.m3colors.m3error;
        if (root.activePrio === 1)
            return Appearance.m3colors.m3tertiary;
        return Appearance.colors.colOnLayer0;
    }
    // La paleta se regenera con cada wallpaper: no se puede asumir contraste.
    // Segunda senal, independiente del color: el punto de una alerta critica es
    // mas grande que el de una ordinaria.
    readonly property real activeDotSize: root.activePrio === 0 ? root.dotSize + 3 : root.dotSize

    function initStates() {
        const arr = [];
        for (let i = 0; i < root.rules.length; i++) {
            arr.push({
                "armed": false,
                "onSince": 0,
                "armedAt": 0,
                "done": false,
                "snoozeUntil": 0
            });
        }
        root.states = arr;
        root.activeIndex = -1;
    }

    function indexOfRule(id) {
        for (let i = 0; i < root.rules.length; i++) {
            if (root.rules[i].id === id)
                return i;
        }
        return -1;
    }

    function elapsedSec(id) {
        const i = root.indexOfRule(id);
        if (i < 0 || i >= root.states.length)
            return 0;
        const s = root.states[i];
        const t0 = (s.onSince > 0) ? s.onSince : s.armedAt;
        return (t0 > 0) ? ((Date.now() - t0) / 1000) : 0;
    }

    function fmtDur(sec) {
        const s = Math.round(sec);
        if (s < 60)
            return s + " s";
        const m = Math.round(s / 60);
        if (m < 60)
            return m + " min";
        const h = Math.floor(m / 60);
        return h + " h " + (m % 60) + " min";
    }

    function safeText(i, wantShort) {
        try {
            const r = root.rules[i];
            const fn = wantShort ? (r.short ?? r.text) : r.text;
            const t = fn();
            return (typeof t === "string") ? t : "";
        } catch (e) {
            return "";
        }
    }

    function evaluate() {
        if (!root.enableLine) {
            root.activeIndex = -1;
            root.showing = false;
            root.needTick = false;
            return;
        }
        if (root.states.length !== root.rules.length)
            root.initStates();

        const now = Date.now();
        let needTick = false;
        let best = -1;
        let bestKey = Number.MAX_VALUE;

        for (let i = 0; i < root.rules.length; i++) {
            const r = root.rules[i];
            const s = root.states[i];

            // El silencio por clic es TEMPORAL: al vencer se limpia tambien el
            // `done`, si no la regla quedaria muda para siempre. `done` sin
            // `snoozeUntil` es el de las reglas no persistentes (dichas una vez)
            // y ese solo se limpia cuando la condicion se va y vuelve.
            if (s.done && s.snoozeUntil > 0 && now >= s.snoozeUntil) {
                s.done = false;
                s.snoozeUntil = 0;
            }

            // Fallo aislado: si la fuente de esta regla no existe, `value()`
            // lanza o devuelve NaN y la regla simplemente no se dispara.
            let v = NaN;
            try {
                v = r.value();
            } catch (e) {
                v = NaN;
            }
            const usable = (typeof v === "number") && isFinite(v);

            // HISTERESIS: el umbral de salida es distinto del de entrada.
            const m = r.margin ?? 0;
            let on = false;
            if (usable) {
                on = s.armed ? (r.above ? (v >= r.threshold - m) : (v <= r.threshold + m)) : (r.above ? (v >= r.threshold) : (v <= r.threshold));
            }

            if (on) {
                if (s.onSince === 0)
                    s.onSince = now;
                if (!s.armed) {
                    needTick = true;   // hay que volver para completar el retardo
                    if (now - s.onSince >= (r.enterMs ?? root.enterMs)) {
                        s.armed = true;
                        s.armedAt = now;
                        s.done = false;
                    }
                }
            } else {
                s.onSince = 0;
                if (s.armed) {
                    // PERMANENCIA MINIMA: aunque la condicion ya se fue, no se
                    // retira antes de tiempo. Esto es lo que evita el temblor.
                    if (now - s.armedAt >= (r.minMs ?? root.minMs)) {
                        s.armed = false;
                        s.done = false;
                    } else {
                        needTick = true;
                    }
                }
            }

            if (s.armed && !s.done && now >= s.snoozeUntil) {
                // La clase de prioridad manda; dentro de la clase gana la
                // regla que ya esta en pantalla (pegajosidad = cero rebote).
                const key = r.prio * 1000 + ((i === root.activeIndex) ? 0 : (1 + i));
                if (key < bestKey) {
                    bestKey = key;
                    best = i;
                }
            }
        }

        // El tick de 1 s solo hace falta si hay algo que avanzar en el tiempo:
        // un retardo de confirmacion a medias, una permanencia minima corriendo,
        // o un contador de segundos en pantalla. Una regla silenciada NO enciende
        // el tick: su vencimiento lo recoge el siguiente cambio de servicio
        // (ResourceUsage ya late cada 3 s por su cuenta).
        if (best >= 0)
            needTick = true;

        if (best !== root.activeIndex) {
            root.activeIndex = best;
            if (best >= 0) {
                root.showing = true;
                showTimer.restart();
            } else {
                root.showing = false;
                showTimer.stop();
            }
        }

        root.lineTextLong = (best >= 0) ? root.safeText(best, false) : "";
        root.lineTextShort = (best >= 0) ? root.safeText(best, true) : "";
        root.needTick = needTick;
    }

    // Vector de dependencias: al leerlas aqui, QML reevalua este binding cuando
    // cualquiera cambia, y con ello dispara la maquina de estados. No hace falta
    // ningun Timer para "vigilar" los servicios.
    readonly property var watchVector: [root.enableLine, Battery.available, Battery.isCharging, Battery.percentage, ResourceUsage.cpuUsage, ResourceUsage.memoryUsedPercentage, ResourceUsage.swapUsedPercentage, ResourceUsage.swapTotal, root.diskUsedFraction, root.micActive, root.shareActive, root.recActive, root.btLostLatch, root.weatherUv, root.weatherPrecip]
    onWatchVectorChanged: root.evaluate()

    Timer {
        id: tickTimer
        // Solo corre mientras hay algo pendiente o armado: en reposo el widget
        // no tiene ningun temporizador vivo. Sirve para completar los retardos de
        // confirmacion y para refrescar el "· 40 s" del texto.
        interval: 1000
        repeat: true
        running: root.enableLine && root.needTick
        onTriggered: root.evaluate()
    }

    Timer {
        id: showTimer
        interval: root.showMs
        repeat: false
        onTriggered: {
            root.showing = false;
            const i = root.activeIndex;
            if (i >= 0 && i < root.states.length && !(root.rules[i].persist ?? true)) {
                // Regla no persistente: dicha una vez, se retira del turno hasta
                // que la condicion vuelva a empezar de cero.
                root.states[i].done = true;
                root.evaluate();
            }
        }
    }

    function snoozeActive() {
        const i = root.activeIndex;
        if (i < 0 || i >= root.states.length)
            return;
        root.states[i].snoozeUntil = Date.now() + root.snoozeMs;
        root.states[i].done = true;
        root.showing = false;
        root.hovered = false;
        showTimer.stop();
        root.evaluate();
    }

    Component.onCompleted: {
        root.initStates();
        root.checkBluetooth();
        // Una sola comprobacion al arrancar: si ya habia una grabacion en curso
        // antes de que existiera el shell, el evento de Hyprland ya paso.
        if (root.enableCapture && root.recorderProcesses.length > 0)
            root.probeRecorder();
        root.evaluate();
    }

    // ---------------------------------------------------------------------
    // PRESENTACION
    // ---------------------------------------------------------------------
    Row {
        id: row
        anchors.verticalCenter: parent.verticalCenter
        anchors.left: parent.left
        spacing: 6

        // ----- EL RENGLON -----
        Item {
            id: alertPart
            anchors.verticalCenter: parent.verticalCenter
            height: Math.round(Appearance.sizes.baseBarHeight * 0.62)
            // clip acota los hijos a ESTA caja. No es layer.enabled: no hay
            // textura intermedia ni recorte por tamano de elemento.
            clip: true

            readonly property bool reveal: root.enableLine && root.activeIndex >= 0 && root.lineTextLong.length > 0
            readonly property real expandedWidth: Math.min(label.implicitWidth + root.padH * 2, root.maxLineWidth)

            // `visible` NO puede colgar de `reveal` directamente: se apagaria de
            // golpe y la animacion de salida no llegaria a verse (mismo truco que
            // usa el Revealer de end-4).
            opacity: alertPart.reveal ? 1 : 0
            visible: opacity > 0
            implicitWidth: alertPart.reveal ? (root.expanded ? alertPart.expandedWidth : root.activeDotSize + root.padH) : 0
            width: implicitWidth

            // Entrada lenta / salida rapida, en la OPACIDAD: 400 ms con
            // emphasizedDecel al aparecer, 200 ms con emphasizedAccel al irse.
            // `reveal` no cambia durante la animacion, asi que duracion y curva
            // son estables mientras corre.
            Behavior on opacity {
                NumberAnimation {
                    duration: alertPart.reveal ? Appearance.animation.elementMoveEnter.duration : Appearance.animation.elementMoveExit.duration
                    easing.type: Easing.BezierSpline
                    easing.bezierCurve: alertPart.reveal ? Appearance.animationCurves.emphasizedDecel : Appearance.animationCurves.emphasizedAccel
                }
            }
            // El ancho usa siempre la curva corta: ademas de aparecer y
            // colapsar, cambia solo cada segundo cuando el texto lleva un
            // contador ("cpu 92 % · 41 s"), y ahi conviene un ajuste breve.
            Behavior on implicitWidth {
                animation: Appearance.animation.elementMoveFast.numberAnimation.createObject(this)
            }

            Rectangle {
                anchors.fill: parent
                radius: Appearance.rounding.full
                color: alertMouse.containsMouse ? Appearance.colors.colLayer1Hover : "transparent"
                Behavior on color {
                    animation: Appearance.animation.elementMoveFast.colorAnimation.createObject(this)
                }
            }

            // Punto colapsado. Es un punto de 8 px: no puede recortarse en
            // ningun borde, y no parpadea (cero animaciones infinitas).
            Rectangle {
                id: collapsedDot
                anchors.centerIn: parent
                width: root.activeDotSize
                height: root.activeDotSize
                radius: width / 2
                opacity: root.expanded ? 0 : 1
                visible: opacity > 0
                color: root.severityColor
                Behavior on width {
                    animation: Appearance.animation.elementMoveFast.numberAnimation.createObject(this)
                }
                Behavior on height {
                    animation: Appearance.animation.elementMoveFast.numberAnimation.createObject(this)
                }
                Behavior on color {
                    animation: Appearance.animation.elementMoveFast.colorAnimation.createObject(this)
                }
                Behavior on opacity {
                    animation: Appearance.animation.elementMoveFast.numberAnimation.createObject(this)
                }
            }

            // Regla de medida: mide SIEMPRE el texto largo, con la misma clase de
            // texto que se va a pintar, para decidir si cabe. Es un StyledText
            // invisible y no un TextMetrics con `font: label.font` a proposito:
            // StyledText elige familia y ejes variables EN FUNCION DE SU PROPIO
            // texto, asi que atar la fuente del medidor al label -- cuyo texto
            // depende de la medida -- seria un bucle de bindings.
            StyledText {
                id: sizer
                visible: false
                text: root.lineTextLong
                font.pixelSize: Appearance.font.pixelSize.smaller
            }

            StyledText {
                id: label
                anchors.centerIn: parent
                width: Math.max(0, Math.min(implicitWidth, root.maxLineWidth - root.padH * 2))
                horizontalAlignment: Text.AlignHCenter
                elide: Text.ElideRight
                maximumLineCount: 1
                opacity: root.expanded ? 1 : 0
                visible: opacity > 0
                font.pixelSize: Appearance.font.pixelSize.smaller
                color: root.severityColor
                // Truncar con criterio: si el largo no cabe se usa la variante
                // corta del descriptor; el elide es solo la ultima red.
                text: (sizer.implicitWidth + root.padH * 2 <= root.maxLineWidth || root.lineTextShort.length === 0) ? root.lineTextLong : root.lineTextShort
                Behavior on color {
                    animation: Appearance.animation.elementMoveFast.colorAnimation.createObject(this)
                }
                Behavior on opacity {
                    animation: Appearance.animation.elementMoveFast.numberAnimation.createObject(this)
                }
            }

            MouseArea {
                id: alertMouse
                anchors.fill: parent
                hoverEnabled: true
                onEntered: root.hovered = true
                onExited: root.hovered = false
                onClicked: root.snoozeActive()
                // El contenedor de la derecha de la barra es un
                // FocusedScrollMouseArea que convierte la rueda en volumen. No
                // se la robamos: devolvemos el evento para que siga subiendo.
                onWheel: wheelEvent => {
                    wheelEvent.accepted = false;
                }
            }
        }

        // ----- EL TESTIGO -----
        Item {
            id: capturePart
            anchors.verticalCenter: parent.verticalCenter
            height: Math.round(Appearance.sizes.baseBarHeight * 0.62)
            clip: true

            readonly property bool reveal: root.enableCapture && root.captureLabel.length > 0

            opacity: capturePart.reveal ? 1 : 0
            visible: opacity > 0
            implicitWidth: capturePart.reveal ? Math.min(root.dotSize + 5 + captureLabelText.implicitWidth + root.padH * 2, root.maxCaptureWidth) : 0
            width: implicitWidth

            // Misma politica que el renglon: entra en 400 ms (emphasizedDecel),
            // sale en 200 ms (emphasizedAccel).
            Behavior on opacity {
                NumberAnimation {
                    duration: capturePart.reveal ? Appearance.animation.elementMoveEnter.duration : Appearance.animation.elementMoveExit.duration
                    easing.type: Easing.BezierSpline
                    easing.bezierCurve: capturePart.reveal ? Appearance.animationCurves.emphasizedDecel : Appearance.animationCurves.emphasizedAccel
                }
            }
            Behavior on implicitWidth {
                animation: Appearance.animation.elementMoveFast.numberAnimation.createObject(this)
            }

            // La paleta se regenera con el wallpaper, asi que el color rojo no se
            // puede dar por legible: la segunda senal es la FORMA (punto lleno +
            // contorno) y la TIPOGRAFIA (mayusculas, frente al renglon que va en
            // minusculas).
            Rectangle {
                anchors.fill: parent
                radius: Appearance.rounding.full
                color: captureMouse.containsMouse ? Appearance.colors.colLayer1Hover : "transparent"
                border.width: 1
                border.color: Appearance.colors.colOutlineVariant
                Behavior on color {
                    animation: Appearance.animation.elementMoveFast.colorAnimation.createObject(this)
                }
            }

            Row {
                anchors.centerIn: parent
                spacing: 5

                Rectangle {
                    anchors.verticalCenter: parent.verticalCenter
                    width: root.dotSize
                    height: root.dotSize
                    radius: width / 2
                    color: Appearance.m3colors.m3error
                }

                StyledText {
                    id: captureLabelText
                    anchors.verticalCenter: parent.verticalCenter
                    text: root.captureLabel
                    elide: Text.ElideRight
                    maximumLineCount: 1
                    width: Math.max(0, Math.min(implicitWidth, root.maxCaptureWidth - root.dotSize - 5 - root.padH * 2))
                    font.pixelSize: Appearance.font.pixelSize.smallest
                    font.letterSpacing: 0.6
                    color: Appearance.colors.colOnLayer0
                }
            }

            MouseArea {
                id: captureMouse
                anchors.fill: parent
                hoverEnabled: true
                onClicked: root.cutSource()
                onWheel: wheelEvent => {
                    wheelEvent.accepted = false;
                }
            }
        }
    }
}
