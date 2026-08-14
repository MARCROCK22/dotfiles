pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import Quickshell.Io
import qs.services
import qs.modules.common
import qs.modules.common.widgets

/**
 * Pulse — la presión del sistema como color, no como cifras.
 *
 * En reposo el widget NO tiene color: el punto usa `colSubtext` (que en M3 es
 * `m3outline`, un neutro de croma baja) y la sparkline es una fila de barras de
 * 1 px. El color solo aparece cuando pasa algo, así que verlo con el rabillo del
 * ojo ya significa algo.
 *
 * Como la paleta se regenera con cada wallpaper y no se puede dar por hecho el
 * contraste, cada estado lleva SIEMPRE una segunda señal de forma:
 *
 *   tranquilo  ->  sin color (colSubtext)  +  barras de 1 px (con hueco)
 *   cargado    ->  m3tertiary              +  barras de 2 px (se tocan: engorda)
 *   crítico    ->  m3error                 +  el punto crece de 6 a 10 px
 *
 * Tríada anti-oscilación:
 *   1. Histéresis   — entra en T, sale en T-5 (puntos porcentuales o °C).
 *   2. Sostenido    — subir a "cargado" exige 2 muestras seguidas (~6 s).
 *                     Subir a "crítico" es inmediato: es una alarma.
 *   3. Permanencia  — un nivel visible no baja antes de `minVisibleMs`.
 *   + CERO animaciones infinitas. Nada parpadea. Solo transiciones de estado.
 *
 * INVARIANTE DE RECORTE (no romper al editar): este widget NUNCA dibuja fuera de
 * su propio rectángulo. No usa `layer.enabled`, ni MultiEffect, ni máscaras, ni
 * sombras, ni halos, ni posiciones centradas del tipo (ancho - anchoHijo) / 2.
 * Todo lo que crece —el punto en crítico y el desglose al hover— crece
 * empujando el layout, nunca desbordando. Ver la nota sobre los extremos.
 */
Item {
    id: root

    // ─────────────────────────────────────────────────────────────────────────
    // Opt-in. Por defecto APAGADO, como pide el mantenedor de end-4 (PR #1858).
    //
    // OJO: el JsonAdapter de Quickshell serializa SOLO las propiedades declaradas
    // y reescribe el archivo entero, así que una clave añadida a mano en
    // ~/.config/illogical-impulse/config.json se borra sola en el siguiente
    // guardado. Hay que declararla en modules/common/Config.qml (ver la nota).
    // Mientras no esté declarada, `pulse` es `undefined`: el encadenamiento
    // opcional evita el TypeError y se cae a `forceEnable`.
    // ─────────────────────────────────────────────────────────────────────────
    property bool forceEnable: false // escotilla: `Pulse { forceEnable: true }` sin tocar Config.qml
    readonly property bool pulseEnabled: (Config?.options?.bar?.pulse?.enable ?? false) || root.forceEnable

    // ── Umbrales ─────────────────────────────────────────────────────────────
    // Reutilizo los umbrales que el usuario YA tiene configurados en end-4 en vez
    // de inventar claves: cada clave nueva le cuesta una línea en Config.qml.
    readonly property real cpuCrit: (Config?.options?.bar?.resources?.cpuWarningThreshold ?? 90) / 100
    readonly property real memCrit: (Config?.options?.bar?.resources?.memoryWarningThreshold ?? 95) / 100
    readonly property real swapCrit: (Config?.options?.bar?.resources?.swapWarningThreshold ?? 85) / 100
    readonly property real tempCrit: 90 // °C — end-4 no tiene clave para esto

    // "Cargado" = este margen por debajo del umbral crítico.
    readonly property real loadedMargin: 0.20 // 20 puntos porcentuales
    readonly property real tempLoadedMargin: 15 // °C

    // Histéresis: se sale 5 puntos (o 5 °C) por debajo de donde se entró.
    readonly property real hysteresis: 0.05
    readonly property real tempHysteresis: 5

    readonly property int minVisibleMs: 8000
    readonly property int sustainSamples: 2 // ~6 s a 3 s por muestra

    // ── Geometría ────────────────────────────────────────────────────────────
    readonly property int sparkPoints: Math.min(24, Config?.options?.resources?.historyLength ?? 60)
    readonly property int sparkSlot: 2 // px por muestra. FIJO: así engordar la
    // barra (1->2) no cambia el ancho total
    readonly property int sparkHeight: 14
    readonly property int dotBase: 6
    readonly property int dotCritical: 10

    // ── Estado ───────────────────────────────────────────────────────────────
    property int level: 0 // 0 tranquilo · 1 cargado · 2 crítico
    property int pendingLoaded: 0 // muestras consecutivas pidiendo "cargado"
    property double levelSetAt: 0 // Date.now() de la última subida
    property real cpuTemp: NaN // °C. NaN = sin sensor
    property var tempHistory: []
    readonly property bool tempAvailable: !isNaN(root.cpuTemp)

    visible: root.pulseEnabled
    implicitWidth: visuals.implicitWidth
    implicitHeight: root.pulseEnabled ? Math.max(root.sparkHeight, root.dotCritical) + 2 : 0

    // ── Desglose del hover: icono + cifra ─────────────────────────────────────
    // Los componentes en línea solo se pueden declarar en el objeto raíz del
    // archivo (igual que `VerticalBarSeparator` en BarContent.qml de end-4).
    component Readout: RowLayout {
        id: readoutItem
        property string icon: ""
        property string value: ""
        spacing: 2
        MaterialSymbol {
            text: readoutItem.icon
            iconSize: Appearance.font.pixelSize.smaller
            color: Appearance.colors.colOnLayer1
        }
        StyledText {
            text: readoutItem.value
            font.pixelSize: Appearance.font.pixelSize.smaller
            color: Appearance.colors.colOnLayer1
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Presión: cada métrica normalizada contra SU PROPIO umbral crítico, y nos
    // quedamos con la peor. 1.0 = justo en el umbral. Así el punto y la
    // sparkline dibujan la misma magnitud en vez de contar dos historias.
    // ─────────────────────────────────────────────────────────────────────────
    function pressureOf(cpu, mem, swap, tempC) {
        let p = Math.max(cpu / root.cpuCrit, mem / root.memCrit, swap / root.swapCrit);
        if (!isNaN(tempC) && tempC > 0)
            p = Math.max(p, tempC / root.tempCrit);
        return p;
    }

    // ¿Alguna métrica pasa de su umbral? `base` baja el umbral para el nivel
    // "cargado" (0 = crítico); `shift` lo baja otro tanto para la histéresis de
    // salida (0 = umbral de entrada). Para CPU/RAM/swap van en fracción 0..1;
    // para la temperatura se traducen a grados.
    function anyAbove(base, shift) {
        if (ResourceUsage.cpuUsage >= root.cpuCrit - base - shift)
            return true;
        if (ResourceUsage.memoryUsedPercentage >= root.memCrit - base - shift)
            return true;
        if (ResourceUsage.swapUsedPercentage >= root.swapCrit - base - shift)
            return true;
        if (root.tempAvailable) {
            const tBase = (base > 0) ? root.tempLoadedMargin : 0;
            const tShift = (shift > 0) ? root.tempHysteresis : 0;
            if (root.cpuTemp >= root.tempCrit - tBase - tShift)
                return true;
        }
        return false;
    }

    // Histéresis pura: para SUBIR se usan los umbrales de entrada; para BAJAR,
    // los de salida. Un valor que se queda entre ambos no mueve nada.
    function targetLevel(current) {
        const critIn = root.anyAbove(0, 0);
        const critOut = root.anyAbove(0, root.hysteresis);
        const loadIn = root.anyAbove(root.loadedMargin, 0);
        const loadOut = root.anyAbove(root.loadedMargin, root.hysteresis);

        if (current >= 2)
            return critOut ? 2 : (loadOut ? 1 : 0);
        if (current === 1)
            return critIn ? 2 : (loadOut ? 1 : 0);
        return critIn ? 2 : (loadIn ? 1 : 0);
    }

    function evaluate() {
        let t = root.targetLevel(root.level);

        // Sostenido: "cargado" tiene que aguantar varias muestras seguidas.
        // "Crítico" no espera: si la máquina se ahoga, quiero saberlo ya.
        if (t === 1 && root.level === 0) {
            root.pendingLoaded++;
            if (root.pendingLoaded < root.sustainSamples)
                t = 0;
        } else if (t !== 1) {
            root.pendingLoaded = 0;
        }

        // Permanencia mínima. No hace falta Timer: si todavía no toca bajar, se
        // reintenta en la muestra siguiente (como mucho 3 s de retraso).
        if (t < root.level && (Date.now() - root.levelSetAt) < root.minVisibleMs)
            return;

        if (t !== root.level) {
            root.level = t;
            if (t > 0)
                root.levelSetAt = Date.now();
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Serie de la sparkline.
    //
    // ResourceUsage YA guarda historial (cpuUsageHistory / memoryUsageHistory /
    // swapUsageHistory, `historyLength` = 60), así que no acumulo nada de eso:
    // lo combino. Ventaja concreta: al activar el widget la sparkline sale YA
    // POBLADA en vez de tardar 72 s en llenarse. La temperatura sí la acumulo
    // yo, porque ResourceUsage no la tiene.
    //
    // Alineación: la muestra más reciente está al FINAL en los cuatro arrays y
    // los cuatro se muestrean al mismo periodo nominal, así que alineo por el
    // final. El desfase máximo es de una muestra: invisible en 14 px de alto.
    // ─────────────────────────────────────────────────────────────────────────
    function buildSeries(cpuH, memH, swapH, tempH, n) {
        const out = [];
        for (let i = 0; i < n; i++) {
            const off = n - i; // 1 = la muestra más nueva
            const c = cpuH[cpuH.length - off] ?? 0;
            const m = memH[memH.length - off] ?? 0;
            const s = swapH[swapH.length - off] ?? 0;
            const t = tempH[tempH.length - off] ?? NaN;
            out.push(root.pressureOf(c, m, s, t));
        }
        return out;
    }

    readonly property var series: root.buildSeries(ResourceUsage.cpuUsageHistory ?? [], ResourceUsage.memoryUsageHistory ?? [], ResourceUsage.swapUsageHistory ?? [], root.tempHistory, root.sparkPoints)

    // Cuantización: la altura se redondea a PÍXEL ENTERO. Con 14 px de recorrido
    // solo hay 14 niveles distinguibles, así que redondear al píxel no pierde
    // información y elimina todo el temblor de reposo. Y si la altura calculada
    // no cambia, asignar el mismo valor no ensucia el scene graph: en reposo el
    // repintado es literalmente cero.
    function barHeight(p) {
        return Math.round(1 + Math.max(0, Math.min(1, p)) * (root.sparkHeight - 1));
    }

    readonly property color levelColor: root.level === 2 ? Appearance.m3colors.m3error : root.level === 1 ? Appearance.m3colors.m3tertiary : Appearance.colors.colSubtext

    // ─────────────────────────────────────────────────────────────────────────
    // Temperatura de CPU.
    //
    // FileView NO sabe hacer glob (`path` es una ruta única, y en Quickshell
    // 0.3.0 no existe ningún tipo que liste directorios), y los índices hwmonN
    // no son estables entre arranques. Así que resuelvo la ruta UNA VEZ con
    // `sh` y a partir de ahí leo con FileView, sin volver a hacer fork. Forkear
    // un `cat` cada 3 s sería justo la regresión de CPU que end-4 rechazó.
    //
    // Elijo el canal por ÍNDICE, no por etiqueta, porque el índice lo garantiza
    // el kernel y el texto de la etiqueta no:
    //
    //   · coretemp (Intel): en drivers/hwmon/coretemp.c el índice se calcula como
    //     `attr_no = is_pkg_temp_data(tdata) ? 1 : cpu_core_id + 2`, o sea temp1
    //     ES el paquete por construcción. Además la etiqueta cambió de
    //     "Physical id 0" a "Package id 0" en kernels viejos, así que casar por
    //     texto es más frágil que casar por índice.
    //
    //   · k10temp (AMD): la doc del kernel (hwmon/k10temp.rst) dice que Tctl "no
    //     representa una temperatura física real" y que se usa para controlar los
    //     ventiladores, mientras que Tdie "es la temperatura medida de verdad".
    //     Tctl es siempre temp1_input; Tdie sale como temp2_input SOLO en los seis
    //     SKU de la tctl_offset_table (Ryzen 1600X/1700X/1800X/2700X y
    //     Threadripper 19xx/29xx), donde Tctl viene inflado entre 10 y 27 °C. Por
    //     eso: temp2_input si existe, si no temp1_input. En Zen 2+ (el Ryzen 7
    //     5800XT del sobremesa) no hay Tdie y temp1_input ya viene compensado.
    //     NOTA: Noctalia prefiere Tctl; sigo la doc del kernel y a caelestia, que
    //     priorizan Tdie. En Zen 3 el resultado es el mismo.
    //
    //   · zenpower (DKMS, no puede convivir con k10temp) numera al revés: su
    //     canal 1 ya es Tdie.
    //
    // La lista blanca es exactamente {coretemp, k10temp, zenpower}: `amdgpu`,
    // `nvidia`, `nouveau`, `nvme` y `acpitz` caen en el `*)` y se descartan ANTES
    // de construir ninguna ruta temp*. Este widget no puede tocar la RTX 3050 ni
    // despertarla, y jamás llama a nvidia-smi.
    //
    // Coste: `read -r n < archivo` es builtin (cero forks; la versión con `cat`
    // forkeaba una vez por cada hwmon), y leer `name` no invoca ningún callback
    // del driver — hwmon.c devuelve una cadena guardada al registrarse. `[ -r ]`
    // es faccessat(2), un permiso de inodo, no una lectura. O sea: el sondeo no
    // puede despertar nada, por construcción.
    // ─────────────────────────────────────────────────────────────────────────
    readonly property string probeScript: 'for d in /sys/class/hwmon/hwmon*; do ' + '[ -r "$d/name" ] || continue; ' + 'read -r n < "$d/name"; ' + 'case $n in ' + 'coretemp) p=$d/temp1_input ;; ' + 'k10temp) p=$d/temp2_input; [ -r "$p" ] || p=$d/temp1_input ;; ' + 'zenpower) p=$d/temp1_input ;; ' + '*) continue ;; ' + 'esac; ' + 'if [ ! -r "$p" ]; then p=; ' + 'for f in "$d"/temp*_input; do [ -r "$f" ] || continue; p=$f; break; done; ' + 'fi; ' + '[ -n "$p" ] && [ -r "$p" ] || continue; ' + 'echo "$p"; exit 0; ' + 'done; exit 0'

    Process {
        id: sensorProbe
        // Un solo disparo, y solo si el widget está encendido. No hay Timer
        // detrás: cuando el proceso termina, `running` pasa a false y el binding
        // no se reevalúa hasta que `pulseEnabled` cambie.
        running: root.pulseEnabled
        command: ["sh", "-c", root.probeScript]
        environment: ({
                LANG: "C",
                LC_ALL: "C"
            })
        stdout: StdioCollector {
            id: probeOut
            onStreamFinished: {
                tempFile.path = probeOut.text.trim(); // "" deja el FileView descargado
            }
        }
    }

    FileView {
        id: tempFile
        path: ""
        // Sin sensor el archivo no existe: que no ensucie el log de quickshell.
        printErrors: false
        // `watchChanges` no sirve: sysfs no emite inotify al cambiar el valor.
        // La actualización va por reload() desde el Timer.
    }

    // `text()` es una FUNCIÓN en Quickshell 0.3.0, pero se comporta como
    // propiedad: emite textChanged(), así que este binding se reevalúa solo al
    // terminar cada reload(). No hace falta manejador de señal.
    readonly property string tempRaw: tempFile.path === "" ? "" : tempFile.text()

    onTempRawChanged: {
        const v = parseInt(root.tempRaw, 10);
        // Milésimas de grado. <= 0 es un sensor que no está dando lectura
        // (Noctalia trata igual el caso Tctl == 0).
        root.cpuTemp = (isNaN(v) || v <= 0) ? NaN : v / 1000;
    }

    // ─────────────────────────────────────────────────────────────────────────
    // ÚNICO Timer del widget.
    //
    // CPU, RAM y swap no cuestan NADA: ResourceUsage ya los muestrea y ya guarda
    // historial, así que ahí añado 0 timers y 0 lecturas. Este Timer existe solo
    // porque sysfs no empuja: hay que ir a preguntar la temperatura. Hace tres
    // cosas: un reload() (una lectura de sysfs, microsegundos), meter una
    // muestra en el anillo, y evaluar el nivel (aritmética sobre 4 números). Va
    // al mismo periodo que ResourceUsage para que las series queden en fase.
    //
    // Se para solo cuando el widget está apagado -> coste cero, no "coste bajo".
    // ─────────────────────────────────────────────────────────────────────────
    Timer {
        // Mantén `bar.pulse.intervalMs` IGUAL que `resources.updateInterval` (los
        // dos valen 3000 por defecto). Si los separas, mi anillo de temperatura y
        // los arrays de ResourceUsage dejan de ir en fase y la sparkline mezcla
        // muestras de instantes distintos.
        interval: Config?.options?.bar?.pulse?.intervalMs ?? 3000
        running: root.pulseEnabled
        repeat: true
        triggeredOnStart: true
        onTriggered: {
            if (tempFile.path !== "")
                tempFile.reload();
            root.tempHistory = root.tempHistory.concat([root.cpuTemp]).slice(-root.sparkPoints);
            root.evaluate();
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Visuales, dentro de un Loader: apagado, no se instancia NADA.
    // ─────────────────────────────────────────────────────────────────────────
    Loader {
        id: visuals
        active: root.pulseEnabled

        sourceComponent: MouseArea {
            id: area
            hoverEnabled: true
            implicitWidth: contentRow.implicitWidth
            implicitHeight: root.implicitHeight

            // Un MouseArea se come la rueda por defecto. Este widget vive dentro
            // del FocusedScrollMouseArea izquierdo de la barra, que es el que
            // cambia el brillo al hacer scroll: si no la devuelvo, el brillo deja
            // de funcionar justo encima del widget.
            onWheel: wheel => {
                wheel.accepted = false;
            }

            RowLayout {
                id: contentRow
                anchors.verticalCenter: parent.verticalCenter
                spacing: 4

                // ── Sparkline ─────────────────────────────────────────────────
                // Rectángulos, NO Canvas. Razones, en orden de peso:
                //
                // 1. En Qt 6 Canvas solo tiene un render target, `Canvas.Image`:
                //    pinta en un QImage y "cada actualización provoca una subida
                //    de textura" (doc de Qt). Y `renderStrategy` es `Immediate`
                //    por defecto: JS de Context2D en el hilo de UI. Repintar cada
                //    3 s para siempre es el gasto que end-4 rechazó en el #1858.
                // 2. Con bindings, si la altura calculada no cambia no se emite
                //    nada: coste cero. `requestPaint()` no tiene ese
                //    cortocircuito, repinta aunque el dibujo sea idéntico.
                // 3. La paleta se regenera con el wallpaper. Un Rectangle se
                //    recolorea solo por binding; un Canvas se queda con el color
                //    viejo hasta el siguiente requestPaint().
                // 4. El grosor de barra es la señal redundante de "cargado": son
                //    barras discretas, no una línea. El Graph.qml que ya trae
                //    end-4 dibuja línea+relleno y no puede expresarlo — por eso
                //    no lo reutilizo, aunque exista.
                //
                // Son 24 rectángulos opacos, mismo material, sin radio y sin
                // opacidad por barra: el scene graph los agrupa en un lote.
                // `model` es un ENTERO constante a propósito — si fuese el array,
                // el Repeater recrearía los 24 delegados cada 3 s en vez de
                // limitarse a actualizar alturas.
                Item {
                    implicitWidth: root.sparkPoints * root.sparkSlot
                    implicitHeight: root.sparkHeight
                    Layout.alignment: Qt.AlignVCenter

                    Repeater {
                        model: root.sparkPoints

                        delegate: Rectangle {
                            id: bar
                            required property int index

                            // Anclado a la izquierda de su hueco, nunca centrado:
                            // centrar 1 px en un hueco de 2 daría x = 0.5 y una
                            // barra borrosa a 1920x1080 sin escalado.
                            x: bar.index * root.sparkSlot
                            width: root.level === 0 ? 1 : 2
                            height: root.barHeight(root.series[bar.index] ?? 0)
                            y: root.sparkHeight - bar.height
                            color: root.levelColor

                            // SIN Behavior en `height`: cambia cada 3 s y animarla
                            // sería una animación prácticamente continua. Salta.
                            Behavior on color {
                                animation: Appearance.animation.elementMoveFast.colorAnimation.createObject(this)
                            }
                        }
                    }
                }

                // ── El punto ──────────────────────────────────────────────────
                // Solo implicitWidth/Height: el RowLayout es quien fija width y
                // height, y tocarlos a mano aquí pelearía con él.
                Rectangle {
                    id: dot
                    Layout.alignment: Qt.AlignVCenter
                    implicitWidth: root.level === 2 ? root.dotCritical : root.dotBase
                    implicitHeight: dot.implicitWidth
                    radius: dot.implicitWidth / 2
                    color: root.levelColor

                    // Transiciones de estado, no bucles. Cero loops infinitos.
                    Behavior on implicitWidth {
                        animation: Appearance.animation.elementResize.numberAnimation.createObject(this)
                    }
                    Behavior on color {
                        animation: Appearance.animation.elementMoveFast.colorAnimation.createObject(this)
                    }
                }

                // ── Cifras exactas, solo al pasar por encima ───────────────────
                // Se expande en línea en vez de abrir un StyledPopup: el brief
                // pide "expande", y además el popup de end-4 se recorta contra el
                // borde de la pantalla, que es justo donde vive este widget.
                //
                // Crece hacia la DERECHA porque es el último hijo de un RowLayout
                // LTR, así que empuja a sus vecinos hacia el interior de la barra
                // y nunca hacia el borde. `clip` solo recorta durante la
                // animación; al final sobran 4 px para que no se coma un glifo.
                Item {
                    id: readout
                    Layout.alignment: Qt.AlignVCenter
                    clip: true
                    implicitHeight: readoutRow.implicitHeight
                    implicitWidth: area.containsMouse ? readoutRow.implicitWidth + 8 : 0

                    Behavior on implicitWidth {
                        animation: Appearance.animation.elementResize.numberAnimation.createObject(this)
                    }

                    RowLayout {
                        id: readoutRow
                        anchors.left: parent.left
                        anchors.leftMargin: 4
                        anchors.verticalCenter: parent.verticalCenter
                        spacing: 6

                        Readout {
                            icon: "planner_review"
                            value: Math.round(ResourceUsage.cpuUsage * 100) + "%"
                        }
                        Readout {
                            icon: "memory"
                            value: Math.round(ResourceUsage.memoryUsedPercentage * 100) + "% · " + ResourceUsage.kbToGbString(ResourceUsage.memoryUsed)
                        }
                        Readout {
                            icon: "swap_horiz"
                            visible: ResourceUsage.swapTotal > 0 && ResourceUsage.swapUsedPercentage > 0
                            value: Math.round(ResourceUsage.swapUsedPercentage * 100) + "%"
                        }
                        Readout {
                            icon: "thermostat"
                            // Sin sensor esta pareja desaparece y ya está: el
                            // resto del widget sigue funcionando igual.
                            visible: root.tempAvailable
                            value: Math.round(root.cpuTemp) + "°"
                        }
                    }
                }
            }
        }
    }
}
