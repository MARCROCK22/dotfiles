import qs.modules.common
import qs.modules.common.widgets
import qs.services
import QtQuick
import QtQuick.Layouts
import Quickshell.Io

/*
 * SysReadouts — tres lecturas de instrumento para la barra de end-4/illogical-impulse.
 *
 *   NET  caudal de red   -> derivada de /proc/net/dev (Network no expone throughput)
 *   DSK  espacio libre   -> df sobre / (y /home si es otra partición)
 *   PKG  actualizaciones -> Updates.count (repos) + paru -Qua (AUR)
 *
 * Cada lectura es opt-in independiente y se oculta sola si su fuente no está.
 * Con las tres desactivadas el componente no crea NI un Timer NI un Process.
 *
 * Reglas que se respetan aquí:
 *  - Cero animaciones infinitas. Solo transiciones por cambio de estado.
 *  - Nada parpadea: los estados transitorios mantienen el último valor en vez
 *    de vaciar el campo (ver comentarios en sampleNet y en el nivel de disco).
 *  - Ancho fijo por campo vía TextMetrics + fuente monoespaciada, igual que
 *    hace el propio end-4 en modules/ii/bar/Resource.qml con "100".
 */
Item {
    id: root

    // ─────────────────────────────────────────────────────────────────────────
    // Opciones.
    //
    // Config.options es un JsonAdapter con propiedades DECLARADAS de forma
    // estática: una clave que no esté escrita en Config.qml vale undefined para
    // siempre, por mucho que aparezca en config.json. Por eso hay DOS caminos y
    // los dos funcionan:
    //
    //  1) Sin tocar nada de end-4: estas son propiedades normales, así que se
    //     sobreescriben en la propia línea de instanciación de BarContent.qml
    //     -> `SysReadouts { netEnabled: true }`. El ?? de abajo es el valor por
    //     defecto y todo queda apagado si no se dice lo contrario.
    //  2) Declarando el bloque `readouts` en Config.qml (va en la nota final):
    //     entonces manda config.json y se puede cambiar en caliente.
    //
    // El encadenamiento opcional es obligatorio en el camino 1: sin él, leer
    // .network sobre un undefined revienta la evaluación de la binding.
    // ─────────────────────────────────────────────────────────────────────────
    property bool netEnabled: Config.options?.bar?.readouts?.network?.enable ?? false
    property int netIntervalMs: Config.options?.bar?.readouts?.network?.intervalMs ?? 2000

    property bool diskEnabled: Config.options?.bar?.readouts?.disk?.enable ?? false
    property int diskIntervalMs: Config.options?.bar?.readouts?.disk?.intervalMs ?? 300000
    property int diskWarnFreePercent: Config.options?.bar?.readouts?.disk?.warnFreePercent ?? 15
    property int diskAlarmFreePercent: Config.options?.bar?.readouts?.disk?.alarmFreePercent ?? 7
    property int diskHysteresisMargin: Config.options?.bar?.readouts?.disk?.hysteresisMargin ?? 2
    property int diskMinDwellMs: Config.options?.bar?.readouts?.disk?.minDwellMs ?? 60000

    property bool pkgEnabled: Config.options?.bar?.readouts?.packages?.enable ?? false
    property int pkgIntervalMs: Config.options?.bar?.readouts?.packages?.intervalMs ?? 900000
    property string pkgAurHelper: Config.options?.bar?.readouts?.packages?.aurHelper ?? "paru"
    // Si es true, este widget también fuerza el refresco del servicio Updates
    // (repos oficiales). Es un efecto lateral sobre un singleton compartido:
    // deja Updates.count más fresco de lo que pide updates.checkInterval.
    property bool pkgDriveRepoRefresh: Config.options?.bar?.readouts?.packages?.driveRepoRefresh ?? true

    // Tipografía de las cifras. Monoespaciada para que los dígitos sean
    // tabulares de verdad: con la fuente "main" un 1 y un 8 no miden igual y
    // el número baila dentro de su propio campo aunque el campo no cambie.
    property string figureFont: Appearance.font.family.monospace
    property int figureSize: Appearance.font.pixelSize.smaller

    readonly property bool netActive: root.netEnabled && root.netSourceOk
    readonly property bool diskActive: root.diskEnabled && root.dfAvailable && root.diskRows.length > 0
    readonly property bool pkgActive: root.pkgEnabled && (root.repoOk || root.aurOk)

    implicitWidth: layout.implicitWidth
    implicitHeight: Appearance.sizes.baseBarHeight
    visible: root.netActive || root.diskActive || root.pkgActive

    // ═════════════════════════════════════════════════════════════════════════
    // Campo de ancho fijo.
    //
    // Es un componente inline SIN referencias a ids externos (los inline
    // components no comparten el ámbito de ids del archivo, así que todo lo que
    // necesita entra por propiedad; los singletons como Appearance sí son
    // accesibles porque son globales).
    //
    // `gauge` es el gálibo: la cadena más ancha que este campo podrá mostrar.
    // El ancho sale de medir el gálibo en NEGRITA, que es el peso más ancho que
    // el campo puede llegar a usar en estado de alarma; así ni siquiera engordar
    // la letra mueve a los vecinos.
    // El texto se alinea a la DERECHA: con monoespaciada, las unidades y los
    // dígitos caen siempre en la misma columna.
    // ═════════════════════════════════════════════════════════════════════════
    component FixedField: Item {
        id: field
        property string value: ""
        property string gauge: "000"
        property color textColor: Appearance.colors.colOnLayer1
        property string fam: Appearance.font.family.monospace
        property int px: Appearance.font.pixelSize.smaller
        property int wt: Font.Normal

        // El ancho es el del GÁLIBO, salvo que llegue un valor que no quepa en
        // él (p.ej. un Arch abandonado medio año: "1500·120"). En ese caso
        // manda el valor. Consecuencia: en operación normal el ancho es una
        // constante y nada baila con el refresco; y en el caso patológico el
        // número se muestra entero en vez de recortarse. El ancho nunca depende
        // de que yo haya acertado con el gálibo.
        implicitWidth: Math.max(gaugeMetrics.width, valueMetrics.width)
        implicitHeight: gaugeMetrics.height
        // Red de seguridad: aunque algo se saliera de la cuenta, se recorta
        // dentro de su propia caja en vez de pintar sobre el widget vecino.
        // Mismo recurso que usa end-4 en modules/ii/bar/Resource.qml.
        clip: true

        TextMetrics {
            id: gaugeMetrics
            text: field.gauge
            font.family: field.fam
            font.pixelSize: field.px
            font.weight: Font.Bold
        }

        // Mide el valor vivo con el peso más ancho (negrita), que es el que
        // puede aparecer en estado de alarma.
        TextMetrics {
            id: valueMetrics
            text: field.value
            font.family: field.fam
            font.pixelSize: field.px
            font.weight: Font.Bold
        }

        StyledText {
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            horizontalAlignment: Text.AlignRight
            text: field.value
            color: field.textColor
            font.family: field.fam
            font.pixelSize: field.px
            font.weight: field.wt
            // StyledText fija font.variableAxes a los ejes de la fuente "main"
            // (wght 450) para cualquier texto que no sea solo dígitos. En una
            // fuente variable eso PISA font.weight y la negrita no se aplica.
            // Vaciando los ejes, font.weight vuelve a mandar.
            font.variableAxes: ({})

            Behavior on color {
                animation: Appearance.animation.elementMoveFast.colorAnimation.createObject(this)
            }
        }
    }

    // Barra fina de ocupación. Sin animaciones en bucle: solo una transición
    // de ancho cuando llega una medición nueva (cada 5 min por defecto).
    component OccupancyBar: Rectangle {
        id: bar
        property real fraction: 0
        property color fillColor: Appearance.colors.colPrimary
        property bool emphasized: false

        implicitHeight: bar.emphasized ? 3 : 2
        radius: Appearance.rounding.full
        color: Appearance.colors.colOutlineVariant

        Behavior on implicitHeight {
            animation: Appearance.animation.elementMoveFast.numberAnimation.createObject(this)
        }

        Rectangle {
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            height: parent.height
            width: parent.width * Math.max(0, Math.min(1, bar.fraction))
            radius: parent.radius
            color: bar.fillColor

            Behavior on width {
                animation: Appearance.animation.elementMove.numberAnimation.createObject(this)
            }
            Behavior on color {
                animation: Appearance.animation.elementMoveFast.colorAnimation.createObject(this)
            }
        }
    }

    // ═════════════════════════════════════════════════════════════════════════
    // NET — derivada de /proc/net/dev
    // ═════════════════════════════════════════════════════════════════════════

    property bool netSourceOk: false
    property bool netLinkUp: false
    property int netDownStreak: 0        // permanencia mínima antes de dar el enlace por caído
    property real netRx: -1              // B/s, -1 = sin dato
    property real netTx: -1
    property var netPrev: null           // { iface, rx, tx, t }

    // El enlace se da por caído solo tras 2 muestras seguidas sin ruta por
    // defecto. Un flap de un tick (roaming wifi, VPN que renegocia) no debe
    // vaciar el campo: vaciar y volver a llenar ES un parpadeo.
    readonly property bool netShowDown: root.netDownStreak >= 2

    /* /proc/net/route lo imprime el kernel en fib_trie.c como
     *   "%s\t%08X\t%08X\t%04X\t%d\t%u\t%u\t%08X\t%d\t%u\t%u"
     *   Iface Destination Gateway Flags RefCnt Use Metric Mask MTU Window IRTT
     * La ruta por defecto es la que tiene Destination == 00000000.
     * Puede haber VARIAS (wifi + VPN + ethernet a la vez): gana la de menor
     * métrica, que es la que realmente cursa el tráfico. */
    function defaultIface(routeText) {
        try {
            const lines = routeText.split("\n");
            let best = "";
            let bestMetric = Infinity;
            for (let i = 1; i < lines.length; i++) {
                const f = lines[i].trim().split(/\s+/);
                if (f.length < 7)
                    continue;
                if (f[1] !== "00000000")
                    continue;
                const metric = parseInt(f[6]);
                const m = isFinite(metric) ? metric : 0;
                if (m < bestMetric) {
                    bestMetric = m;
                    best = f[0];
                }
            }
            return best;
        } catch (e) {
            return "";
        }
    }

    /* /proc/net/dev: 2 líneas de cabecera y luego "%6s: %7llu %7llu ..."
     * (net/core/net-procfs.c). El nombre va alineado a la DERECHA en 6
     * caracteres, así que "    lo:" lleva espacios delante y "wlp0s20f3:" no:
     * hay que cortar por el primer ':' y hacer trim, nunca partir por espacios.
     * Tras el nombre, el campo 1 es rx_bytes y el campo 9 es tx_bytes. */
    function ifaceCounters(devText, iface) {
        try {
            const lines = devText.split("\n");
            for (let i = 2; i < lines.length; i++) {
                const line = lines[i];
                const c = line.indexOf(":");
                if (c < 0)
                    continue;
                if (line.slice(0, c).trim() !== iface)
                    continue;
                const f = line.slice(c + 1).trim().split(/\s+/);
                if (f.length < 9)
                    return null;
                const rx = Number(f[0]);
                const tx = Number(f[8]);
                if (!isFinite(rx) || !isFinite(tx))
                    return null;
                return { rx: rx, tx: tx };
            }
            return null;
        } catch (e) {
            return null;
        }
    }

    function sampleNet() {
        const now = Date.now();
        // La ruta puede ir un tick desfasada respecto a los contadores: es
        // irrelevante, la tabla de rutas no cambia entre dos muestras salvo
        // justo en el instante del cambio, que ya se descarta más abajo.
        const iface = root.defaultIface(routeView.text());

        if (iface === "") {
            const streak = Math.min(root.netDownStreak + 1, 2);
            root.netDownStreak = streak;
            root.netPrev = null;
            // Se evalúa la racha en local en vez de leer netShowDown, para no
            // depender del momento en que QML reevalúa la binding.
            if (streak >= 2) {
                root.netRx = -1;
                root.netTx = -1;
            }
            return;
        }
        root.netDownStreak = 0;

        const cur = root.ifaceCounters(devView.text(), iface);
        if (!cur) {
            // La interfaz de la ruta no aparece en /proc/net/dev (carrera al
            // crearse/destruirse). Se descarta la muestra sin tocar lo mostrado.
            root.netPrev = null;
            return;
        }

        const prev = root.netPrev;
        root.netPrev = { iface: iface, rx: cur.rx, tx: cur.tx, t: now };

        if (!prev)
            return;                              // primera muestra: no hay derivada
        if (prev.iface !== iface)
            return;                              // cambió la interfaz: los contadores no son comparables
        if (cur.rx < prev.rx || cur.tx < prev.tx)
            return;                              // el contador RETROCEDIÓ (interfaz recreada, driver
        // recargado, VPN que rebota). Nunca se extrapola:
        // se salta la muestra y se conserva el valor anterior
        // un tick, que es preferible a inventar un pico.
        const dt = (now - prev.t) / 1000;
        if (dt <= 0)
            return;

        root.netRx = (cur.rx - prev.rx) / dt;
        root.netTx = (cur.tx - prev.tx) / dt;
    }

    /* Siempre B/s con letra de escala, base 1000 (convención de red).
     * 1 decimal por debajo de 10, 0 por encima -> máximo 4 caracteres
     * ("9.9M", "999M", "  --"), que es el gálibo del campo. */
    function fmtRate(bps) {
        if (bps < 0)
            return "--";
        const u = ["B", "k", "M", "G", "T"];
        let v = bps;
        let i = 0;
        while (v >= 1000 && i < u.length - 1) {
            v /= 1000;
            i++;
        }
        return (v < 10 ? v.toFixed(1) : Math.round(v).toString()) + u[i];
    }

    // Un único Timer para las dos lecturas. 2 s: son dos ficheros de procfs de
    // ~1 kB servidos desde memoria, sin E/S de disco, del mismo orden que el
    // Timer de 3 s que ResourceUsage ya tiene para /proc/meminfo y /proc/stat.
    // Bajar a 1 s duplicaría el coste sin que un caudal se lea mejor de un
    // vistazo; subir a 5 s haría perder ráfagas cortas.
    Timer {
        interval: root.netIntervalMs
        repeat: true
        running: root.netEnabled
        triggeredOnStart: true
        onTriggered: {
            routeView.reload();
            devView.reload();
        }
    }

    FileView {
        id: routeView
        path: "/proc/net/route"
        printErrors: false
    }

    FileView {
        id: devView
        path: "/proc/net/dev"
        printErrors: false
        // El cálculo va en onLoaded, no justo después de reload(): reload() es
        // asíncrono, así que leer text() acto seguido devuelve la muestra
        // ANTERIOR. En onLoaded el contenido ya está fresco y Date.now() marca
        // el instante real de la muestra, que es lo que se divide.
        onLoaded: {
            root.netSourceOk = true;
            root.sampleNet();
        }
        // Sin /proc/net/dev no hay lectura posible: la fuente no está y NET
        // desaparece sin tocar al resto de la barra.
        onLoadFailed: root.netSourceOk = false
    }

    // ═════════════════════════════════════════════════════════════════════════
    // DSK — df sobre / y /home
    // ═════════════════════════════════════════════════════════════════════════

    property bool dfAvailable: false
    property var diskRows: []            // [{ source, usedPct, avail, target }]
    property int diskLevel: 0            // 0 normal | 1 precaución | 2 alarma, para /
    property int diskHomeLevel: 0        // idem para /home cuando es otra partición
    // real, no int: Date.now() son ~1.7e12 ms y no cabe en un int de QML.
    property real diskLevelSince: 0
    property real diskHomeLevelSince: 0

    // El icono resume el estado PEOR de las particiones mostradas: si /home se
    // llena y / está bien, el aviso tiene que salir igual.
    readonly property int diskWorstLevel: root.diskHome ? Math.max(root.diskLevel, root.diskHomeLevel) : root.diskLevel

    readonly property var diskRoot: root.diskRows.length > 0 ? root.diskRows[0] : null
    // /home solo se muestra si está en otra partición: se compara el DISPOSITIVO,
    // no el punto de montaje (df imprime dos filas aunque sea el mismo sistema
    // de ficheros, porque se le pasan dos argumentos explícitos).
    readonly property var diskHome: (root.diskRows.length > 1 && root.diskRows[1].source !== root.diskRows[0].source) ? root.diskRows[1] : null

    /* 3 cifras significativas, base 1024 (es lo que muestra `df -h`: 214G).
     * Máximo 5 caracteres: "9.99G". */
    function fmtSize3(bytes) {
        if (!(bytes >= 0))
            return "--";
        const u = ["B", "K", "M", "G", "T", "P"];
        let v = bytes;
        let i = 0;
        while (v >= 1024 && i < u.length - 1) {
            v /= 1024;
            i++;
        }
        if (v >= 100)
            return Math.round(v).toString() + u[i];
        if (v >= 10)
            return v.toFixed(1) + u[i];
        return v.toFixed(2) + u[i];
    }

    /* Histéresis: se ENTRA en el umbral y se SALE en umbral + margen. Sin esto,
     * un disco parado justo en el 15.0 % libre alternaría de nivel en cada
     * medición. Los umbrales son de espacio LIBRE, que es lo que se muestra. */
    function levelFor(freePct, prev) {
        if (freePct < root.diskAlarmFreePercent)
            return 2;
        if (prev === 2 && freePct < root.diskAlarmFreePercent + root.diskHysteresisMargin)
            return 2;
        if (freePct < root.diskWarnFreePercent)
            return 1;
        if (prev >= 1 && freePct < root.diskWarnFreePercent + root.diskHysteresisMargin)
            return 1;
        return 0;
    }

    /* Permanencia mínima: subir de nivel es inmediato (es una advertencia, no
     * puede esperar), bajar exige que el nivel lleve puesto diskMinDwellMs.
     * Con el intervalo por defecto de 5 min casi nunca se nota; existe para que
     * bajar diskIntervalMs no vuelva inestable el indicador.
     * Devuelve el par {level, since} en vez de escribir en una propiedad fija,
     * para poder aplicarlo por separado a / y a /home. */
    function nextLevel(freePct, prevLevel, since) {
        const now = Date.now();
        const target = root.levelFor(freePct, prevLevel);
        if (target > prevLevel)
            return { level: target, since: now };
        if (target < prevLevel && (now - since) >= root.diskMinDwellMs)
            return { level: target, since: now };
        return { level: prevLevel, since: since };
    }

    function colorForLevel(level) {
        if (level === 2)
            return Appearance.m3colors.m3error;
        if (level === 1)
            return Appearance.m3colors.m3tertiary;
        return Appearance.colors.colOnLayer1;
    }

    // df --output es una extensión de GNU coreutils (la que trae Arch). Se pide
    // `target` AL FINAL a propósito: si un punto de montaje llevara espacios,
    // solo se descuadraría el último campo, no las cifras.
    // No hace falta shell: sin tuberías, Process ejecuta el binario directo.
    Process {
        id: dfProbe
        running: root.diskEnabled
        command: ["which", "df"]
        onExited: (exitCode, exitStatus) => {
            root.dfAvailable = (exitCode === 0);
            if (root.dfAvailable)
                dfProc.running = true;
        }
    }

    Process {
        id: dfProc
        command: ["df", "-B1", "--output=source,pcent,avail,target", "/", "/home"]
        // LANG/LC_ALL en C igual que hace end-4 en ResourceUsage y Network:
        // sin esto, el locale puede cambiar cabeceras y separadores decimales.
        environment: ({
                LANG: "C",
                LC_ALL: "C"
            })
        stdout: StdioCollector {
            onStreamFinished: {
                try {
                    const lines = text.trim().split("\n");
                    const rows = [];
                    for (let i = 1; i < lines.length; i++) {
                        const f = lines[i].trim().split(/\s+/);
                        if (f.length < 4)
                            continue;
                        const pct = parseInt(f[1]);      // "42%" -> 42
                        const avail = Number(f[2]);
                        if (!isFinite(pct) || !isFinite(avail))
                            continue;
                        rows.push({
                            source: f[0],
                            usedPct: pct,
                            avail: avail,
                            target: f.slice(3).join(" ")
                        });
                    }
                    root.diskRows = rows;
                    if (rows.length > 0) {
                        const r = root.nextLevel(100 - rows[0].usedPct, root.diskLevel, root.diskLevelSince);
                        root.diskLevel = r.level;
                        root.diskLevelSince = r.since;
                    }
                    if (rows.length > 1) {
                        const h = root.nextLevel(100 - rows[1].usedPct, root.diskHomeLevel, root.diskHomeLevelSince);
                        root.diskHomeLevel = h.level;
                        root.diskHomeLevelSince = h.since;
                    }
                } catch (e) {
                    // Un df ilegible no puede tumbar la barra: se conserva la
                    // lectura anterior y DSK se oculta solo si nunca hubo datos.
                }
            }
        }
    }

    // 5 minutos. El espacio libre cambia en escala geológica salvo durante una
    // descarga o una compilación grandes, y ninguna de las dos se decide mirando
    // la barra: lo que importa es enterarse ANTES de quedarse sin disco, no en
    // tiempo real. Un fork de df cada 300 s es ~0.001 % de CPU; a 5 s serían 60
    // veces más forks por exactamente la misma información.
    Timer {
        interval: root.diskIntervalMs
        repeat: true
        running: root.diskEnabled && root.dfAvailable
        onTriggered: dfProc.running = true
    }

    // ═════════════════════════════════════════════════════════════════════════
    // PKG — repos (servicio Updates) + AUR (paru)
    // ═════════════════════════════════════════════════════════════════════════

    property int aurCount: 0
    property bool aurOk: false
    property bool aurAvailable: false

    // Los repos oficiales salen del servicio Updates que ya existe, para no
    // duplicar `checkupdates`. OJO: Updates.available solo se pone a true si
    // Config.options.updates.enableCheck es true, porque su propio sondeo
    // `which checkupdates` está condicionado a esa opción.
    readonly property bool repoOk: Updates.available
    readonly property int repoCount: Updates.available ? Updates.count : 0

    readonly property int pkgTotal: (root.repoOk ? root.repoCount : 0) + (root.aurOk ? root.aurCount : 0)
    // Formato repos·AUR. Sin AUR disponible se muestra solo el número de repos,
    // sin separador, para no fingir un dato que no se tiene.
    readonly property string pkgLabel: root.pkgTotal === 0 ? "-" : (root.aurOk ? `${root.repoCount}·${root.aurCount}` : `${root.repoCount}`)

    function refreshPackages() {
        if (root.pkgDriveRepoRefresh)
            Updates.refresh();          // no hace nada si Updates.available es false
        if (root.aurAvailable)
            aurProc.running = true;
    }

    Process {
        id: aurProbe
        running: root.pkgEnabled
        command: ["which", root.pkgAurHelper]
        onExited: (exitCode, exitStatus) => {
            root.aurAvailable = (exitCode === 0);
            if (root.aurAvailable)
                aurProc.running = true;
        }
    }

    // `paru -Qua` sale con código 1 cuando NO hay actualizaciones (hereda la
    // semántica de `pacman -Q`, que devuelve 1 si nada coincide). Por eso el
    // conteo se saca de wc -l y el código de salida se ignora: la tubería
    // termina en wc, que siempre sale 0. Es una consulta, no pide root ni
    // abre prompt; el 2>/dev/null calla los avisos de RPC del AUR.
    Process {
        id: aurProc
        command: ["bash", "-c", `${root.pkgAurHelper} -Qua 2>/dev/null | wc -l`]
        environment: ({
                LANG: "C",
                LC_ALL: "C"
            })
        stdout: StdioCollector {
            onStreamFinished: {
                const n = parseInt(text.trim());
                if (isFinite(n)) {
                    root.aurCount = n;
                    root.aurOk = true;
                }
            }
        }
    }

    // 15 min. `checkupdates` sincroniza una base temporal y `paru -Qua` consulta
    // el RPC del AUR: son dos accesos a red, no dos lecturas locales. 15 min es
    // el compromiso que pide el brief; el disparo por cambio en la base de
    // pacman (abajo) es el que hace que el número sea correcto justo después de
    // instalar algo, que es cuando de verdad importa.
    Timer {
        interval: root.pkgIntervalMs
        repeat: true
        running: root.pkgEnabled
        triggeredOnStart: true
        onTriggered: root.refreshPackages()
    }

    /* Disparo por cambio en la base de datos local de pacman.
     *
     * Quickshell 0.3.0 NO tiene un tipo watcher de ficheros: el módulo
     * Quickshell.Io son DataStream, DataStreamParser, FileView, FileViewAdapter,
     * FileViewError, IpcHandler, JsonAdapter, JsonObject, Process, Socket,
     * SocketServer, SplitParser y StdioCollector. El único mecanismo es
     * FileView.watchChanges.
     *
     * FileView lo implementa con QFileSystemWatcher y añade DOS rutas: la propia
     * y su directorio padre (src/io/fileview.cpp, updateWatchedFiles). Como aquí
     * `path` es un DIRECTORIO, los cambios llegan por directoryChanged, y
     * onWatchedDirectoryChanged emite fileChanged() porque el path existe y no
     * está registrado como fichero. Resultado: se notifica cuando pacman crea o
     * borra el directorio de un paquete en local/, y también cuando aparece o
     * desaparece /var/lib/pacman/db.lck (el padre vigilado), que marca el
     * principio y el final de una transacción.
     *
     * preload: false es lo que hace esto gratis: sin él, FileView intentaría
     * LEER el directorio y fallaría con NotAFile. Con preload en false no se
     * lee nunca (y no se llama a text() ni a reload()), pero el watcher se crea
     * igual. printErrors: false por si acaso.
     *
     * Es un uso lateral de la API. Si un día dejara de emitir, lo único que se
     * pierde es la inmediatez: el Timer de 15 min sigue cubriendo el caso.
     */
    FileView {
        id: pacmanDbWatcher
        path: "/var/lib/pacman/local"
        watchChanges: root.pkgEnabled
        preload: false
        printErrors: false
        onFileChanged: pkgDebounce.restart()
    }

    // Antirrebote. Una actualización grande crea y borra cientos de directorios:
    // sin esto se lanzarían cientos de checkupdates. Se refresca 5 s después del
    // ÚLTIMO cambio, es decir una sola vez al terminar la transacción.
    Timer {
        id: pkgDebounce
        interval: 5000
        repeat: false
        onTriggered: root.refreshPackages()
    }

    // ═════════════════════════════════════════════════════════════════════════
    // Presentación
    // ═════════════════════════════════════════════════════════════════════════

    RowLayout {
        id: layout
        anchors.verticalCenter: parent.verticalCenter
        spacing: 10

        // ── NET ──────────────────────────────────────────────────────────────
        RowLayout {
            spacing: 2
            visible: root.netActive

            MaterialSymbol {
                Layout.alignment: Qt.AlignVCenter
                text: "arrow_downward"
                iconSize: root.figureSize
                fill: root.netShowDown ? 0 : 1
                // Flechas apagadas cuando no hay enlace. El color no es la única
                // señal: el relleno del icono cambia y el campo pasa a "--".
                color: Appearance.colors.colSubtext
                opacity: root.netShowDown ? 0.4 : 1
                Behavior on opacity {
                    animation: Appearance.animation.elementMoveFast.numberAnimation.createObject(this)
                }
            }

            FixedField {
                Layout.alignment: Qt.AlignVCenter
                gauge: "999M"
                fam: root.figureFont
                px: root.figureSize
                value: root.fmtRate(root.netRx)
                textColor: root.netShowDown ? Appearance.colors.colSubtext : Appearance.colors.colOnLayer1
            }

            MaterialSymbol {
                Layout.alignment: Qt.AlignVCenter
                Layout.leftMargin: 4
                text: "arrow_upward"
                iconSize: root.figureSize
                fill: root.netShowDown ? 0 : 1
                color: Appearance.colors.colSubtext
                opacity: root.netShowDown ? 0.4 : 1
                Behavior on opacity {
                    animation: Appearance.animation.elementMoveFast.numberAnimation.createObject(this)
                }
            }

            FixedField {
                Layout.alignment: Qt.AlignVCenter
                gauge: "999M"
                fam: root.figureFont
                px: root.figureSize
                value: root.fmtRate(root.netTx)
                textColor: root.netShowDown ? Appearance.colors.colSubtext : Appearance.colors.colOnLayer1
            }
        }

        // ── DSK ──────────────────────────────────────────────────────────────
        RowLayout {
            spacing: 4
            visible: root.diskActive

            MaterialSymbol {
                Layout.alignment: Qt.AlignVCenter
                // Segunda señal, independiente del color: en alarma cambia el
                // GLIFO (otra forma), en precaución cambia el relleno.
                text: root.diskWorstLevel === 2 ? "warning" : "hard_drive"
                iconSize: root.figureSize
                fill: root.diskWorstLevel >= 1 ? 1 : 0
                color: root.colorForLevel(root.diskWorstLevel)
                Behavior on color {
                    animation: Appearance.animation.elementMoveFast.colorAnimation.createObject(this)
                }
            }

            // Columna por partición: cifra de espacio LIBRE y, debajo, la barra
            // de ocupación con el ancho exacto del campo.
            ColumnLayout {
                Layout.alignment: Qt.AlignVCenter
                spacing: 2

                FixedField {
                    id: rootFreeField
                    Layout.alignment: Qt.AlignHCenter
                    gauge: "9.99G"
                    fam: root.figureFont
                    px: root.figureSize
                    value: root.diskRoot ? root.fmtSize3(root.diskRoot.avail) : "--"
                    textColor: root.colorForLevel(root.diskLevel)
                    wt: root.diskLevel === 2 ? Font.Bold : Font.Normal
                }

                OccupancyBar {
                    Layout.preferredWidth: rootFreeField.implicitWidth
                    fraction: root.diskRoot ? root.diskRoot.usedPct / 100 : 0
                    fillColor: root.colorForLevel(root.diskLevel)
                    emphasized: root.diskLevel >= 1
                }
            }

            ColumnLayout {
                Layout.alignment: Qt.AlignVCenter
                spacing: 2
                visible: root.diskHome !== null

                FixedField {
                    id: homeFreeField
                    Layout.alignment: Qt.AlignHCenter
                    gauge: "9.99G"
                    fam: root.figureFont
                    px: root.figureSize
                    value: root.diskHome ? root.fmtSize3(root.diskHome.avail) : "--"
                    textColor: root.colorForLevel(root.diskHomeLevel)
                    wt: root.diskHomeLevel === 2 ? Font.Bold : Font.Normal
                }

                OccupancyBar {
                    Layout.preferredWidth: homeFreeField.implicitWidth
                    fraction: root.diskHome ? root.diskHome.usedPct / 100 : 0
                    fillColor: root.colorForLevel(root.diskHomeLevel)
                    emphasized: root.diskHomeLevel >= 1
                }
            }
        }

        // ── PKG ──────────────────────────────────────────────────────────────
        RowLayout {
            spacing: 2
            visible: root.pkgActive

            MaterialSymbol {
                Layout.alignment: Qt.AlignVCenter
                text: "deployed_code_update"
                iconSize: root.figureSize
                fill: root.pkgTotal > 0 ? 1 : 0
                color: root.pkgTotal > 0 ? Appearance.colors.colOnLayer1 : Appearance.colors.colSubtext
                opacity: root.pkgTotal > 0 ? 1 : 0.4
            }

            FixedField {
                Layout.alignment: Qt.AlignVCenter
                gauge: "999·99"
                fam: root.figureFont
                px: root.figureSize
                value: root.pkgLabel
                // Con cero, guion apagado: el atenuado va acompañado del cambio
                // de glifo (guion en vez de cifras), que se lee sin color.
                textColor: root.pkgTotal > 0 ? Appearance.colors.colOnLayer1 : Appearance.colors.colSubtext
            }
        }
    }
}
