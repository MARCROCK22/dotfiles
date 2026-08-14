#!/usr/bin/env bash
#
# dotfiles-setup.sh  (v15)
# Monta o actualiza el repositorio de dotfiles para CachyOS + Hyprland + end-4.
#
# Es idempotente: puedes ejecutarlo las veces que quieras. Si ~/dotfiles ya
# existe, actualiza las copias y hace un commit con los cambios.
#
# NO borra ni modifica ninguna configuración existente. Todo son copias.
#
# Historial:
#   v9  — el setup deja de ser Niri + Caffyne. Se recogen los overrides de
#         Hyprland en Lua, la config de illogical-impulse y los tres archivos
#         QML de end-4 parcheados. Se eliminan niri/ y caffyne/ del repo.
#   v10 — el escaneo de secretos deja de dar falsos positivos en cada pasada.
#   v11 — install.sh se sustituye por install.py, que ya no se genera aqui
#         sino que es un archivo real del repo.
#   v12 — tras una revision adversarial. Lo importante:
#         * GUARDA CONTRA STOW: si la maquina ya esta enlazada al repo, el
#           'rm -rf' previo a copiar vaciaba el repo y se commiteaba. Aborta.
#         * Un secreto detectado ya NO se commitea: sale con codigo 2.
#         * El escaneo detecta claves SSH, JWT, AWS, Google, Slack, GitLab;
#           antes solo veia 2 de 8 formatos reales.
#         * 'sk-' exigia caracteres detras: casaba con task-, disk-, desk-.
#         * El wallpaper ya no se borra a si mismo si vive dentro del repo.
#         * pkglist/hyprpm-plugins no se truncan si el comando falla.
#         * 'cd $DOTS' comprobado; merge/rebase/HEAD desacoplado detectados.
#         * git ya no PISA tu identidad configurada.
#         * monitors.lua deja de versionarse: es de cada maquina.
#   v13 — resto de la revision adversarial:
#         * copiar_dir() refleja borrados; antes 'cp -r' solo fusionaba y un
#           archivo borrado de tu config seguia publicandose para siempre.
#         * Los parches llevan FIRMA: si end-4 los pisa, no se sobrescribe la
#           version buena del repo con la que ya no tiene el parche.
#         * rc comprobado en los 'sudo cp'; $USER vacio ya no aborta.
#         * El escaneo ya no se salta los README de spicetify/, y 'key_id'
#           deja de tragarse lineas enteras.
#         * Se rechaza la ejecucion por tuberia (readlink daba /dev/fd/63).
#   v14 — los parches de end-4 pasan de copias enteras a DIFFS en patches/.
#         Con copias, cada actualizacion de end-4 obligaba a elegir entre su
#         version y la tuya. Con diffs, 'patch' aplica tu cambio sobre la suya.
#         Este script ya solo VERIFICA las firmas; aplicar es cosa de
#         install.py. Ver MANTENIMIENTO.md.
#   v15 — MARCHA ATRAS DELIBERADA sobre v14: se vuelve a archivos ENTEROS, y
#         ahora son 14 (los 4 que se tocan de end-4 + 10 widgets nuevos).
#         El motivo de v14 sigue siendo cierto: un reemplazo pisa en SILENCIO
#         los cambios de end-4, mientras que un diff falla a gritos. A cambio,
#         el despliegue es determinista y no hay diffs que regenerar a mano.
#         Compensaciones, porque el riesgo es real:
#         * MANIFEST con el sha256 de cada archivo; install.py NO sobrescribe
#           a ciegas: si lo instalado no coincide, ensena el diff y pregunta.
#         * VERSION con el commit de end-4 contra el que se recogio.
#         * Las FIRMAS desaparecen: el diseno 1 elimina legitimamente
#           'rightCenterGroupContent', asi que daban falsa alarma.
#         * La lista de .qml se le pregunta a select_design.py --archivos, en
#           vez de duplicarla aqui. Ese script NO se versiona: son 460 KB
#           que ya duplican, embebidos, los 14 .qml que el repo guarda
#           sueltos. Vive fuera del repo y solo se le consulta.
#         Y lo que encontro la revision adversarial de este mismo cambio:
#         * Se recoge a un TEMPORAL y solo se sustituye si estan los 14. Antes
#           borraba quickshell/ del repo ANTES de copiar, asi que un archivo
#           ausente en la maquina (caso normal tras './setup install' de end-4)
#           desaparecia del repo y 'git add -A' publicaba el borrado.
#         * Rutas con '..' o absolutas se rechazan en los dos lados. En
#           install.py escribian FUERA de la shell diciendo "escrito".
#         * select_design.py se busca por FECHA, no por orden: la copia del
#           repo ganaba siempre y usaba una lista vieja sin decirlo.
#         * El error de select_design.py ya no va a /dev/null.
#         * install.py: --solo-shell, para actualizar la shell en la maquina
#           ORIGEN sin pasar por stow (pasar por stow la enlazaba y dejaba el
#           recolector inservible para siempre). Y si el respaldo falla, ya no
#           sobrescribe.
#
# Uso:  bash dotfiles-setup.sh
#

set -uo pipefail

VERSION="15"
DOTS="$HOME/dotfiles"
ESTE="$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || true)"
# Con 'bash <(curl ...)' o 'bash < script', BASH_SOURCE no es un archivo real
# y se copiaria /dev/fd/63 al repo como si fuera el script.
case "$ESTE" in
    ""|/dev/fd/*|/proc/self/fd/*|bash|/dev/stdin)
        printf '\033[1;31m✗\033[0m Ejecuta el script desde un archivo, no por tuberia:\n'
        printf '    bash dotfiles-setup.sh\n'
        exit 1
        ;;
esac
FALTANTES=()
AVISOS=()
COPIADOS=0

# Los respaldos que dejan los scripts de parcheo nunca deben acabar en el repo.
# GNU cp no tiene --exclude, asi que se copia todo y se limpia despues.
limpiar_bak() {
    find "$1" -type f \( -name '*.bak' -o -name '*.bak-*' \) -delete 2>/dev/null
}

# ---------- salida ----------
say()  { printf '\n\033[1;35m==>\033[0m \033[1m%s\033[0m\n' "$*"; }
ok()   { printf '    \033[1;32m✓\033[0m %s\n' "$*"; }
warn() { printf '    \033[1;33m!\033[0m %s\n' "$*"; }
err()  { printf '    \033[1;31m✗\033[0m %s\n' "$*"; }

# copiar <origen> <directorio-destino> <etiqueta>
copiar() {
    local origen="$1" destino="$2" etiqueta="$3"
    if [ -e "$origen" ]; then
        mkdir -p "$destino"
        if cp -r "$origen" "$destino/"; then
            ok "$etiqueta"
            COPIADOS=$((COPIADOS + 1))
        else
            err "fallo copiando: $etiqueta"
        fi
    else
        warn "no encontrado: $etiqueta  ($origen)"
        FALTANTES+=("$etiqueta -> $origen")
    fi
}

# Copia un DIRECTORIO reflejando borrados. 'cp -r dir dest/' fusiona con lo
# que ya hay, asi que el repo solo crecia: si borrabas un archivo de tu config,
# seguia publicandose. Se copia a un temporal y se sustituye entero.
copiar_dir() {
    local origen="$1" destino="$2" etiqueta="$3"
    if [ ! -d "$origen" ]; then
        warn "no encontrado: $etiqueta  ($origen)"
        FALTANTES+=("$etiqueta -> $origen")
        return
    fi
    local tmp="${destino}.tmp.$$"
    rm -rf "$tmp"
    if cp -r "$origen" "$tmp"; then
        limpiar_bak "$tmp"
        rm -rf "${destino:?}"
        mv "$tmp" "$destino"
        ok "$etiqueta ($(find "$destino" -type f | wc -l) archivo(s))"
        COPIADOS=$((COPIADOS + 1))
    else
        rm -rf "$tmp"
        err "fallo copiando: $etiqueta (se conserva lo anterior)"
    fi
}

# Igual que copiar, pero si no existe no se considera un problema.
copiar_opcional() {
    local origen="$1" destino="$2" etiqueta="$3"
    if [ -e "$origen" ]; then
        mkdir -p "$destino"
        cp -r "$origen" "$destino/" && { ok "$etiqueta"; COPIADOS=$((COPIADOS + 1)); }
    fi
}

# ---------- comprobaciones ----------
say "Comprobando requisitos (script v$VERSION)"

# Si en el repo hay una copia distinta de este mismo script, avisar: casi
# siempre significa que estás ejecutando una versión vieja guardada por ahí.
if [ -f "$DOTS/dotfiles-setup.sh" ] && ! cmp -s "$ESTE" "$DOTS/dotfiles-setup.sh"; then
    if [ "$ESTE" != "$(readlink -f "$DOTS/dotfiles-setup.sh")" ]; then
        err "Estás ejecutando una copia distinta a la del repo."
        err "  ejecutando : $ESTE"
        err "  en el repo : $DOTS/dotfiles-setup.sh"
        err "Si esta es la nueva (v$VERSION), es lo esperado la primera vez."
        err "Continúa solo si sabes que esta copia es la buena."
        read -rp "    ¿Continuar? [s/N] " r
        [ "${r,,}" = "s" ] || exit 1
    fi
fi

if [ ! -d "$HOME/.config/hypr" ]; then
    err "No existe ~/.config/hypr. ¿Seguro que estás en la máquina con Hyprland?"
    exit 1
fi

# --- GUARDA CONTRA STOW -----------------------------------------------------
# Este script RECOGE config de ~/.config hacia el repo. install.py hace lo
# contrario: convierte esos archivos en enlaces AL repo. Si ya se ejecuto
# install.py, origen y destino son el mismo inodo, y el 'rm -rf' previo a la
# copia destruye el contenido real del repo. Verificado: deja custom/ vacio,
# y 'git add -A' commitea el borrado.
#
# Con enlaces, este script no tiene nada que recoger: los archivos YA son el
# repo. Editarlos edita el repo directamente; basta con hacer commit.
ENLAZADOS=()
for ruta in "$HOME/.config/hypr/custom" \
            "$HOME/.config/hypr/monitors.lua" \
            "$HOME/.config/alacritty/alacritty.toml" \
            "$HOME/.config/fish/config.fish" \
            "$HOME/.config/illogical-impulse/config.json" \
            "$HOME/.local/bin/recorder"; do
    if [ -L "$ruta" ]; then
        DESTINO_ENLACE="$(readlink -f "$ruta" 2>/dev/null || true)"
        case "$DESTINO_ENLACE" in
            "$DOTS"/*) ENLAZADOS+=("$ruta -> $DESTINO_ENLACE") ;;
        esac
    fi
done

if [ ${#ENLAZADOS[@]} -gt 0 ]; then
    err "Esta máquina ya está enlazada al repo con stow:"
    for e in "${ENLAZADOS[@]}"; do printf '        %s\n' "$e"; done
    echo
    echo "    Estos archivos YA SON el repo. Este script los recogería sobre sí"
    echo "    mismos y el 'rm -rf' previo a la copia dejaría el repo VACÍO."
    echo
    echo "    Si has cambiado configuración, ya está en el repo. Solo falta:"
    echo "        cd $DOTS && git add -A && git status && git commit"
    echo
    echo "    OJO, con una excepción: los 14 archivos de quickshell/ NO van por"
    echo "    stow. Son copias en ~/.config/quickshell/ii, no enlaces, así que"
    echo "    'git add -A' no ve nada de lo que cambies ahí. En esta máquina la"
    echo "    shell solo se DESPLIEGA (install.py --solo-shell), no se recoge."
    echo
    echo "    Este script es para la máquina ORIGEN, la que aún no está enlazada."
    exit 1
fi
ok "sin enlaces de stow — se puede recoger sin riesgo"

for cmd in git pacman; do
    command -v "$cmd" >/dev/null || { err "falta el comando: $cmd"; exit 1; }
done
ok "git y pacman disponibles"

if command -v stow >/dev/null; then
    ok "stow disponible"
else
    warn "stow no instalado — lo necesitarás para los enlaces: sudo pacman -S stow"
    AVISOS+=("instalar stow")
fi

if [ -d "$DOTS/.git" ]; then
    ok "repo existente en $DOTS — se actualizará"
    MODO="actualizar"
elif [ -e "$DOTS" ]; then
    err "$DOTS existe pero no es un repo git. Muévelo o bórralo antes."
    exit 1
else
    ok "se creará $DOTS desde cero"
    MODO="crear"
fi

# ---------- retirar lo que ya no es tu setup ----------
say "Retirando restos del setup anterior"

# niri/ y caffyne/ describen un escritorio que ya no usas. Dejar de copiarlos
# no basta: seguirían en el repo dando información falsa a quien lo clone.
for obsoleto in niri caffyne; do
    if [ -e "$DOTS/$obsoleto" ]; then
        rm -rf "${DOTS:?}/$obsoleto"
        ok "eliminado del repo: $obsoleto/"
        AVISOS+=("$obsoleto/ se ha borrado del repo — sigue en el historial de git")
    fi
done

# hyprlock.conf lo instala end-4 y no lo has tocado; versionarlo como tuyo
# confunde. La pantalla de bloqueo real la dibuja Quickshell (lock.useHyprlock
# está en false en tu config).
if [ -f "$DOTS/hypr/.config/hypr/hyprlock.conf" ]; then
    rm -f "$DOTS/hypr/.config/hypr/hyprlock.conf"
    ok "eliminado del repo: hyprlock.conf (es de end-4, no tuyo)"
fi

# ---------- estructura ----------
say "Preparando estructura"
mkdir -p "$DOTS"/{hypr/.config/hypr/custom,alacritty/.config/alacritty}
mkdir -p "$DOTS"/{bin/.local/bin,spicetify/.config,illogical-impulse/.config/illogical-impulse}
mkdir -p "$DOTS"/{fish/.config/fish,fastfetch/.config/fastfetch,starship/.config}
mkdir -p "$DOTS"/{system/nvidia,system/sddm,wallpaper}
ok "directorios listos"

# ---------- configuración de usuario ----------
say "Copiando configuración de usuario"

# Solo custom/: hyprland.lua y la carpeta hyprland/ son de end-4 y las
# sobrescribe su instalador. Lo tuyo vive entero en custom/.
copiar_dir "$HOME/.config/hypr/custom" "$DOTS/hypr/.config/hypr/custom" "hypr / custom/"

copiar "$HOME/.config/illogical-impulse/config.json" \
       "$DOTS/illogical-impulse/.config/illogical-impulse" "illogical-impulse / config.json"

# monitors.lua NO se versiona, a proposito. Es el equivalente del machine.kdl
# que ya usabas en niri: nombres de output, escalas y posiciones son de UNA
# maquina. Versionarlo hacia que stow plantara en el PC las pantallas del
# portatil, y que install.py escribiera en el repo al regenerarlo.
# Lo genera install.py en cada maquina:  python3 install.py --solo-monitores
if [ -f "$DOTS/hypr/.config/hypr/monitors.lua" ]; then
    rm -f "$DOTS/hypr/.config/hypr/monitors.lua"
    ok "monitors.lua retirado del repo (es específico de máquina, va en .gitignore)"
fi

if [ ! -f "$HOME/.config/hypr/monitors.lua" ] && ! grep -rqs 'hl.monitor(' "$HOME/.config/hypr/custom/"; then
    warn "no hay hl.monitor() en ningun sitio: tu resolucion no esta fijada"
    AVISOS+=("generar monitors.lua:  python3 ~/dotfiles/install.py --solo-monitores")
fi

copiar "$HOME/.config/alacritty/alacritty.toml"   "$DOTS/alacritty/.config/alacritty" "alacritty"
copiar "$HOME/.local/bin/recorder"                "$DOTS/bin/.local/bin"              "script recorder"
copiar          "$HOME/.config/fish/config.fish" "$DOTS/fish/.config/fish" "fish / config.fish"
copiar_dir      "$HOME/.config/fish/functions" "$DOTS/fish/.config/fish/functions" "fish / functions"
copiar_dir      "$HOME/.config/fish/conf.d"    "$DOTS/fish/.config/fish/conf.d"    "fish / conf.d"
# fish_variables se excluye a propósito: lo genera fish solo y cambia constantemente
# VS Code se excluye a proposito: el repo es publico y sus ajustes pueden
# arrastrar rutas, tokens de extensiones y configuracion de trabajo.
copiar_dir "$HOME/.config/spicetify" "$DOTS/spicetify/.config/spicetify" "spicetify"
copiar "$HOME/.config/fastfetch/config.jsonc"     "$DOTS/fastfetch/.config/fastfetch" "fastfetch"
copiar "$HOME/.config/starship.toml"              "$DOTS/starship/.config"            "starship (prompt)"

# ---------- archivos de la shell (reemplazo completo) ----------
say "Recogiendo los archivos de end-4"

# v15: se acabaron los diffs. El repo guarda los archivos ENTEROS.
#
# Por que se cambio: un diff que ya no encaja falla a gritos, pero obliga a
# regenerarlo a mano cada vez que end-4 toca la zona. Con archivos enteros el
# despliegue es determinista: lo que hay en el repo es exactamente lo que
# acaba en la maquina.
#
# El precio, y hay que decirlo claro: un reemplazo PISA EN SILENCIO los
# cambios de end-4. Por eso el repo guarda tambien el sha256 de cada archivo
# (MANIFEST) y la version de la shell contra la que se hizo (VERSION), e
# install.py se niega a sobrescribir a ciegas: si lo instalado no coincide ni
# con lo nuestro ni con lo ultimo recogido, ensena el diff y pregunta.
#
# La lista de los 12 archivos que gestiona select_design.py NO se escribe
# aqui: se le pregunta a el. Existen a la vez como .qml en disco y embebidos
# dentro del script, y dos listas separadas acaban separandose.

QS="$HOME/.config/quickshell/ii"
DEST_QS="$DOTS/quickshell"

# Los dos que select_design.py no gestiona: son arreglos de bugs ajenos.
EXTRA_ARCHIVOS=(
    "reemplazo	modules/ii/bar/StyledPopup.qml"
    "reemplazo	modules/ii/background/Background.qml"
)

if [ ! -d "$QS" ]; then
    err "no existe $QS — ¿esta end-4 instalado?"
    FALTANTES+=("quickshell/ii")
else
    # select_design.py hace falta para saber QUE recoger, pero NO se versiona:
    # son 460 KB que ya duplican, embebidos, los mismos 14 .qml que el repo
    # guarda sueltos. Vive fuera del repo y aqui solo se le consulta.
    #
    # $DOTS NO esta en la busqueda a proposito: una copia suelta ahi la
    # recogeria el 'git add -A' del final y volveria a entrar en el repo por
    # la puerta de atras. Ademas esta en .gitignore.
    #
    # Se coge el MAS RECIENTE de los candidatos: si tienes dos copias, la
    # vieja daria una lista desactualizada sin decir nada.
    SEL=""
    for cand in "$HOME/select_design.py" "$HOME/Descargas/select_design.py" \
                "$HOME/Downloads/select_design.py" "$HOME/.local/bin/select_design.py"; do
        [ -f "$cand" ] || continue
        if [ -z "$SEL" ] || [ "$cand" -nt "$SEL" ]; then
            SEL="$cand"
        fi
    done

    if [ -z "$SEL" ]; then
        err "no encuentro select_design.py"
        err "  buscado en: \$HOME, ~/Descargas, ~/Downloads, ~/.local/bin"
        err "  no se versiona a proposito (460 KB que duplican los 14 .qml),"
        err "  pero hace falta para saber que recoger. Sin el se omite la shell."
        FALTANTES+=("select_design.py (fuera del repo)")
    else
        ok "lista pedida a $SEL"

        # El error NO se tira a /dev/null: si la copia es vieja y no tiene la
        # bandera --archivos, argparse escribe el motivo en stderr, y sin el
        # esto solo diria "no devolvio nada". Un 2>/dev/null tapando un fallo
        # real ya ha costado horas en este repo.
        SEL_ERR="${TMPDIR:-/tmp}/.select_design.err.$$"
        LISTA="$(python3 "$SEL" --archivos 2>"$SEL_ERR")"
        SEL_RC=$?
        if [ "$SEL_RC" -ne 0 ] || [ -z "$LISTA" ]; then
            err "select_design.py --archivos fallo (rc=$SEL_RC)"
            if [ -s "$SEL_ERR" ]; then
                head -4 "$SEL_ERR" | while IFS= read -r l; do echo "        $l"; done
            fi
            err "¿es una copia vieja, anterior a la bandera --archivos?"
            rm -f "$SEL_ERR"
            FALTANTES+=("lista de archivos de la shell")
        else
            rm -f "$SEL_ERR"
            # Se monta en un TEMPORAL y solo se sustituye si todo salio bien.
            # Es el mismo patron que copiar_dir() (mas arriba) y por el mismo
            # motivo: borrar primero y copiar despues significa que un archivo
            # ausente en la maquina desaparece del repo, y el 'git add -A' del
            # final publica el borrado sin que nada lo compruebe — ni N_FALLO
            # ni FALTANTES, que solo se imprimen DESPUES del commit.
            #
            # No es teorico: './setup install' de end-4 reinstala el arbol ii/
            # y se lleva por delante los 10 .qml nuevos. Recoger justo despues
            # habria vaciado quickshell/ del repo y commiteado el borrado.
            TMP_QS="${DEST_QS}.tmp.$$"
            rm -rf "$TMP_QS"
            mkdir -p "$TMP_QS"

            MAN_TMP="$TMP_QS/MANIFEST"
            : > "$MAN_TMP"
            N_OK=0; N_FALLO=0

            while IFS=$'\t' read -r tipo ruta; do
                # Un \r al final convierte la ruta en inexistente y el fallo
                # es mudo: "no esta en tu sistema" para un archivo que si
                # esta. Pasa si select_design.py corre en Windows (python
                # traduce \n a \r\n en stdout) o si el MANIFEST viaja por ahi.
                ruta="${ruta%$'\r'}"
                tipo="${tipo%$'\r'}"
                [ -n "$ruta" ] || continue
                # Una ruta con '..' o absoluta escribiria FUERA del repo. Hoy
                # no puede pasar (las genera select_design.py), pero el coste
                # de comprobarlo es cero y el de no hacerlo es escribir en
                # sitios arbitrarios sin enterarse.
                case "$ruta" in
                    /*|*..*)
                        err "ruta sospechosa, omitida: $ruta"
                        N_FALLO=$((N_FALLO + 1))
                        continue
                        ;;
                esac
                origen="$QS/$ruta"
                if [ ! -f "$origen" ]; then
                    warn "no esta en tu sistema: $ruta"
                    FALTANTES+=("quickshell/$ruta")
                    N_FALLO=$((N_FALLO + 1))
                    continue
                fi
                mkdir -p "$TMP_QS/$(dirname "$ruta")"
                SUMA="$(sha256sum "$origen" 2>/dev/null | cut -d' ' -f1)"
                if [ -z "$SUMA" ]; then
                    err "no pude calcular el sha256 de $ruta"
                    N_FALLO=$((N_FALLO + 1))
                elif cp "$origen" "$TMP_QS/$ruta"; then
                    printf '%s\t%s\t%s\n' "$tipo" "$SUMA" "$ruta" >> "$MAN_TMP"
                    N_OK=$((N_OK + 1))
                else
                    err "no pude copiar $ruta"
                    N_FALLO=$((N_FALLO + 1))
                fi
            done < <(printf '%s\n' "$LISTA"; printf '%s\n' "${EXTRA_ARCHIVOS[@]}")

            # VERSION: contra que end-4 se hizo esto. Si la shell se instalo
            # con ./setup no hay .git y no se puede saber el commit; se anota
            # asi en vez de inventarlo.
            {
                echo "# Version de end-4/dots-hyprland contra la que se recogieron"
                echo "# estos archivos. Fijarla = git checkout <commit> antes de"
                echo "# ./setup install. El propio ./setup NO tiene bandera de version."
                if [ -d "$HOME/.config/quickshell/.git" ]; then
                    echo "commit=$(git -C "$HOME/.config/quickshell" rev-parse HEAD 2>/dev/null || echo desconocido)"
                    echo "fecha=$(git -C "$HOME/.config/quickshell" log -1 --format=%ad --date=short 2>/dev/null || echo desconocida)"
                elif [ -d "$HOME/dots-hyprland/.git" ]; then
                    echo "commit=$(git -C "$HOME/dots-hyprland" rev-parse HEAD 2>/dev/null || echo desconocido)"
                    echo "fecha=$(git -C "$HOME/dots-hyprland" log -1 --format=%ad --date=short 2>/dev/null || echo desconocida)"
                else
                    echo "commit=desconocido"
                    echo "fecha=desconocida"
                    echo "# No hay checkout git de end-4: se instalo con ./setup."
                    echo "# Si quieres fijarla de verdad, clona el repo, haz checkout"
                    echo "# del commit que quieras y corre ./setup install desde ahi."
                fi
                # Sin marca de tiempo a proposito: cambiaria en cada pasada y
                # 'git add -A' veria siempre una diferencia, generando un
                # commit por ejecucion aunque no hubiera cambiado nada. La
                # fecha de recogida ya la registra el propio commit.
            } > "$TMP_QS/VERSION"

            # EL CAMBIAZO. Solo si los 14 estan: un archivo que falte casi
            # siempre significa que la maquina esta a medias (end-4 recien
            # reinstalado, o los widgets sin poner), no que lo hayas borrado
            # a proposito. Borrar a proposito se refleja igual, porque
            # entonces select_design.py tampoco lo lista y no cuenta como
            # fallo. Ante la duda, se conserva lo que ya habia en el repo.
            if [ "$N_FALLO" -gt 0 ]; then
                rm -rf "$TMP_QS"
                err "$N_FALLO de $((N_OK + N_FALLO)) archivo(s) no se pudieron recoger"
                err "quickshell/ del repo NO se toca: se conserva lo que ya habia"
                err "Si acabas de reinstalar end-4, repon los widgets con:"
                err "  python3 $SEL --widgets"
                AVISOS+=("quickshell/ NO se actualizo: faltaban $N_FALLO archivo(s)")
            else
                rm -rf "${DEST_QS:?}"
                if mv "$TMP_QS" "$DEST_QS"; then
                    ok "$N_OK archivo(s) recogidos en quickshell/ (+ MANIFEST y VERSION)"
                    COPIADOS=$((COPIADOS + 1))
                else
                    err "no pude sustituir quickshell/ en el repo"
                    FALTANTES+=("quickshell/")
                fi
            fi
        fi
    fi
fi

# patches/ queda muerto con el reemplazo completo. NO se borra solo: borrar
# cosas del repo sin pedirlo es justo lo que rompio el repo en su dia.
if [ -d "$DOTS/patches" ]; then
    warn "patches/ ya no se usa (v15 guarda archivos enteros)"
    AVISOS+=("borrar patches/ cuando confirmes que va bien:  rm -rf ~/dotfiles/patches")
fi

# ---------- wallpaper actual ----------
say "Detectando wallpaper actual"

# end-4 guarda la ruta en su config, que es más fiable que preguntarle al
# demonio de fondos (awww/swww ya no intervienen en este setup).
WP=""
CFG_II="$HOME/.config/illogical-impulse/config.json"
if [ -f "$CFG_II" ]; then
    if command -v python3 >/dev/null; then
        WP=$(python3 -c "
import json,sys
try:
    d = json.load(open(sys.argv[1]))
    print(d.get('background', {}).get('wallpaperPath', ''))
except Exception:
    pass
" "$CFG_II" 2>/dev/null)
    elif command -v jq >/dev/null; then
        WP=$(jq -r '.background.wallpaperPath // ""' "$CFG_II" 2>/dev/null)
    fi
fi

if [ -n "$WP" ] && [ -f "$WP" ]; then
    # Si el fondo en uso vive DENTRO del repo -- lo normal tras migrar, porque
    # install.py lo copia desde aqui -- el 'rm -f wallpaper/*' lo destruiria
    # justo antes de intentar copiarlo. Verificado: borra el original, el cp
    # falla, y sin '-e' el script seguia adelante.
    WP_REAL="$(readlink -f "$WP" 2>/dev/null || printf '%s' "$WP")"
    DOTS_REAL="$(readlink -f "$DOTS" 2>/dev/null || printf '%s' "$DOTS")"
    case "$WP_REAL" in
        "$DOTS_REAL"/*)
            ok "wallpaper: $(basename "$WP") — ya está en el repo, no se toca"
            ;;
        *)
            # Copiar primero, sustituir despues: nunca se borra sin tener
            # el reemplazo ya en disco.
            TMP_WP="$DOTS/wallpaper/.nuevo-$$"
            if cp "$WP_REAL" "$TMP_WP"; then
                find "$DOTS/wallpaper" -maxdepth 1 -type f ! -name ".nuevo-$$" -delete 2>/dev/null
                mv "$TMP_WP" "$DOTS/wallpaper/$(basename "$WP_REAL")"
                ok "wallpaper: $(basename "$WP_REAL")"
                COPIADOS=$((COPIADOS + 1))
            else
                rm -f "$TMP_WP"
                err "no pude copiar el wallpaper; el anterior se conserva"
                FALTANTES+=("wallpaper")
            fi
            ;;
    esac
else
    warn "no se pudo leer background.wallpaperPath"
    AVISOS+=("copiar el wallpaper a mano a ~/dotfiles/wallpaper/")
fi

# ---------- archivos de sistema ----------
say "Copiando archivos de sistema (pedirá sudo)"

NVIDIA_SRC="/etc/nvidia/nvidia-application-profiles-rc.d/50-limit-free-buffer-pool-in-wayland-compositors.json"
if sudo test -e "$NVIDIA_SRC"; then
    if ! sudo cp "$NVIDIA_SRC" "$DOTS/system/nvidia/"; then
        err "fallo copiando el perfil de Nvidia (¿falló sudo?)"
    fi
    ok "perfil de VRAM de Nvidia"
    COPIADOS=$((COPIADOS + 1))
    # El perfil apunta a un nombre de proceso. Si sigue diciendo niri, no aplica.
    if ! sudo grep -qi 'hyprland' "$NVIDIA_SRC"; then
        warn "el perfil no menciona Hyprland — puede seguir apuntando solo a niri"
        AVISOS+=("revisar el perfil de Nvidia: debe tener una regla para Hyprland")
    fi
else
    warn "no encontrado el perfil de Nvidia"
    FALTANTES+=("perfil nvidia")
fi

# SDDM: aceptar tanto el nombre correcto como el que tiene una coma por error.
SDDM_OK=0
for candidato in "/etc/sddm.conf.d/theme.conf" "/etc/sddm.conf.d/theme,conf"; do
    if sudo test -e "$candidato"; then
        if ! sudo cp "$candidato" "$DOTS/system/sddm/theme.conf"; then
            err "fallo copiando el tema de SDDM"; break
        fi
        ok "tema de SDDM (desde $(basename "$candidato"))"
        SDDM_OK=1
        if [ "$candidato" = "/etc/sddm.conf.d/theme,conf" ]; then
            AVISOS+=("renombrar el archivo de SDDM: tiene una coma en vez de un punto")
        fi
        break
    fi
done
[ "$SDDM_OK" = "0" ] && { warn "no se encontró configuración de tema de SDDM"; FALTANTES+=("tema sddm"); }

# Quirks de libinput: aquí vive el apaño que desactiva el "disable while
# typing" del touchpad marcando el teclado interno como externo.
if sudo test -f /etc/libinput/local-overrides.quirks; then
    mkdir -p "$DOTS/system/libinput"
    sudo cp /etc/libinput/local-overrides.quirks "$DOTS/system/libinput/"
    ok "quirks de libinput (touchpad)"
    COPIADOS=$((COPIADOS + 1))
fi

# Los archivos del propio tema viven en /usr/share y los pisa cualquier
# actualizacion del paquete.
TEMA_SDDM="/usr/share/sddm/themes/sddm-astronaut-theme"
if sudo test -d "$TEMA_SDDM"; then
    mkdir -p "$DOTS/system/sddm-theme/Themes"

    if sudo test -f "$TEMA_SDDM/metadata.desktop"; then
        sudo cp "$TEMA_SDDM/metadata.desktop" "$DOTS/system/sddm-theme/"
        ok "sddm-astronaut / metadata.desktop"
        COPIADOS=$((COPIADOS + 1))
    fi

    VARIANTE=$(sudo grep -oP 'ConfigFile=Themes/\K.*' "$TEMA_SDDM/metadata.desktop" 2>/dev/null | head -1)
    if [ -n "$VARIANTE" ] && sudo test -f "$TEMA_SDDM/Themes/$VARIANTE"; then
        sudo cp "$TEMA_SDDM/Themes/$VARIANTE" "$DOTS/system/sddm-theme/Themes/"
        ok "sddm-astronaut / $VARIANTE"
        COPIADOS=$((COPIADOS + 1))
    else
        warn "no se pudo determinar la variante activa del tema de SDDM"
    fi
fi

# $USER puede venir vacio o sin definir (cron, su, contenedor); con set -u
# eso abortaba el script justo antes del escaneo de secretos.
YO="${USER:-$(id -un)}"
if ! sudo chown -R "$YO:$YO" "$DOTS/system" 2>/dev/null; then
    warn "no pude devolverte la propiedad de $DOTS/system"
    warn "quedan archivos de root en el repo: sudo chown -R $YO:$YO $DOTS/system"
    AVISOS+=("archivos de root en $DOTS/system")
fi

# ---------- lista de paquetes ----------
say "Generando lista de paquetes"

# '> archivo' TRUNCA antes de ejecutar el comando: si este falla, la lista
# buena se sustituye por una vacia y git la commitea. Se escribe aparte y solo
# se sustituye si el resultado tiene contenido.
TMP_PKG="$DOTS/.pkglist.$$"
if pacman -Qqe > "$TMP_PKG" 2>/dev/null && [ -s "$TMP_PKG" ]; then
    mv "$TMP_PKG" "$DOTS/pkglist.txt"
    ok "$(wc -l < "$DOTS/pkglist.txt") paquetes explícitos"
else
    rm -f "$TMP_PKG"
    err "pacman -Qqe no devolvió nada; se conserva el pkglist.txt anterior"
    FALTANTES+=("pkglist.txt")
fi

# El plugin del overview no es un paquete: hyprpm lo compila aparte.
# hyprpm necesita Hyprland corriendo: por SSH o desde un TTY devuelve vacio,
# y antes eso borraba la lista buena.
if command -v hyprpm >/dev/null; then
    TMP_HP="$DOTS/.hyprpm.$$"
    if hyprpm list > "$TMP_HP" 2>/dev/null && [ -s "$TMP_HP" ]; then
        mv "$TMP_HP" "$DOTS/hyprpm-plugins.txt"
        ok "plugins de hyprpm anotados"
    else
        rm -f "$TMP_HP"
        warn "hyprpm no respondió (¿Hyprland no está corriendo?); lista anterior intacta"
    fi
fi

# ---------- install.sh ----------
say "Generando archivos del repo"

# install.sh se sustituyo por install.py (v11). El instalador ya no se genera
# desde aqui: es un archivo real del repo, versionado como cualquier otro.
# Motivo: configurar monitores necesita leer JSON, preguntar y emitir Lua, y
# eso dentro de un heredoc de bash era insostenible.
if [ -f "$DOTS/install.sh" ]; then
    rm -f "$DOTS/install.sh"
    ok "install.sh eliminado — lo sustituye install.py"
fi

if [ -f "$DOTS/install.py" ]; then
    chmod +x "$DOTS/install.py"
    if command -v python3 >/dev/null && python3 -m py_compile "$DOTS/install.py" 2>/dev/null; then
        ok "install.py presente y compila"
        rm -rf "$DOTS/__pycache__"
    else
        warn "install.py presente pero no compila — revisalo"
        AVISOS+=("install.py no compila")
    fi
else
    err "falta install.py en el repo"
    FALTANTES+=("install.py")
fi

# El propio script vive en el repo: así solo existe una versión canónica.
if [ "$ESTE" != "$(readlink -f "$DOTS/dotfiles-setup.sh" 2>/dev/null)" ]; then
    cp "$ESTE" "$DOTS/dotfiles-setup.sh"
    chmod +x "$DOTS/dotfiles-setup.sh"
    ok "dotfiles-setup.sh copiado al repo (v$VERSION)"
fi

# .gitignore: si no existe se crea entero; si ya existe solo se añaden las
# entradas que falten, para no borrar lo que hayas puesto tú a mano.
ENTRADAS=(
    'machine.kdl'
    'monitors.lua'          # específico de máquina, lo genera install.py
    'launcher_usage.json'
    'fish_variables'
    '*.bak'
    '*.bak-*'
    '*.log'
    '.cache/'
    '__pycache__/'
)
if [ ! -f "$DOTS/.gitignore" ]; then
    printf '%s\n' "${ENTRADAS[@]}" > "$DOTS/.gitignore"
    ok ".gitignore creado"
else
    NUEVAS=0
    for entrada in "${ENTRADAS[@]}"; do
        grep -qxF "$entrada" "$DOTS/.gitignore" || { echo "$entrada" >> "$DOTS/.gitignore"; NUEVAS=$((NUEVAS + 1)); }
    done
    if [ "$NUEVAS" -gt 0 ]; then
        ok ".gitignore actualizado ($NUEVAS entrada(s) nueva(s))"
    else
        ok ".gitignore ya estaba completo"
    fi
fi

# README: NO se toca si existe. Ya se perdió una vez por sobrescribirlo.
if [ -f "$DOTS/README.md" ]; then
    if grep -qi 'niri\|caffyne' "$DOTS/README.md"; then
        warn "el README sigue describiendo Niri + Caffyne"
        AVISOS+=("actualizar README.md a mano: describe un setup que ya no usas")
    else
        ok "README.md existente — no se toca"
    fi
else
cat > "$DOTS/README.md" <<'README_EOF'
# dotfiles

Configuración de escritorio para **CachyOS + Hyprland + end-4 (illogical-impulse)**.

## Qué hay aquí

| Carpeta | Contenido |
|---|---|
| `hypr/` | `custom/*.lua` — mis overrides de Hyprland. Lo de end-4 no está aquí |
| `illogical-impulse/` | `config.json` del shell |
| `quickshell/` | Archivos **enteros** de la shell: 4 que pisan a end-4 y 10 widgets propios. `MANIFEST` (sha256) + `VERSION` (commit de end-4) |
| `alacritty/` | Terminal |
| `bin/` | Scripts propios (`recorder`: grabación de pantalla) |
| `spicetify/` | Tema de Spotify |
| `fish/` | Shell |
| `fastfetch/` | Resumen del sistema al abrir la terminal |
| `starship/` | Prompt |
| `system/` | Archivos de `/etc` y `/usr/share`, los instala `install.py` |
| `wallpaper/` | Fondo actual — de él sale la paleta Material You |

## Instalación en una máquina nueva

```bash
# 1. Primero end-4, que es la base
bash <(curl -s https://ii.clsty.link/get)

# 2. Luego esto, que va encima
git clone <este-repo> ~/dotfiles
cd ~/dotfiles
sudo pacman -S --needed - < pkglist.txt
python3 install.py
```

## Lo que hay que tocar a mano

- **Las pantallas**: no se versionan. Las genera `install.py` en cada máquina,
  en `~/.config/hypr/monitors.lua` (como el `machine.kdl` de niri).
- **Los archivos de `quickshell/`**: se copian **enteros** encima de los de
  end-4. `install.py` compara el sha256 contra `MANIFEST` y solo pregunta
  cuando lo instalado no coincide — que es la señal de que end-4 cambió ese
  archivo, o de que lo editaste tú.
- **Tras actualizar end-4**: revisa los 4 marcados `reemplazo` en `MANIFEST`.
  Un reemplazo pisa los cambios de upstream **en silencio**; ese es el precio
  de no usar parches, y por eso existe la comprobación de hash.
- **El plugin del overview**: se instala con `hyprpm`, no con pacman. La ruta
  del `.so` en `custom/general.lua` lleva el nombre de usuario dentro.

## Notas

- **Hyprland 0.55+ usa Lua**, no hyprlang. `hyprctl keyword` no funciona;
  para probar en caliente, `hyprctl eval`.
- **`custom/` gana sobre `hyprland/`**: se carga después. Nunca editar
  `~/.config/hypr/hyprland/`, lo pisa cada actualización de end-4.
- **Nvidia**: `system/nvidia/` limita la fuga de VRAM del driver. Solo importa
  cuando el compositor corre sobre la Nvidia (no en modo híbrido).
- **`prime-run`**: en portátiles híbridos, los juegos necesitan
  `prime-run %command%` en las opciones de lanzamiento de Steam.
README_EOF
ok "README.md creado"
fi

# ---------- limpieza final ----------
# Red de seguridad: cualquier .bak que se haya colado en cualquier copia.
# Ojo: -prune y -delete son incompatibles (-delete implica -depth), asi que
# .git se excluye con -not -path, no con -prune.
BAKS=$(find "$DOTS" -type f \( -name '*.bak' -o -name '*.bak-*' \) \
        -not -path "*/.git/*" -print 2>/dev/null | wc -l)
if [ "${BAKS:-0}" -gt 0 ]; then
    find "$DOTS" -type f \( -name '*.bak' -o -name '*.bak-*' \) \
        -not -path "*/.git/*" -delete
    ok "$BAKS respaldo(s) descartado(s) del repo"
fi

# ---------- escaneo de secretos ----------
say "Escaneando en busca de secretos (el repo es público)"

# Dos familias: etiquetas ("api_key = ...") y FORMAS de credencial reconocibles.
# Solo con etiquetas se colaban claves privadas SSH, JWT, y tokens de AWS,
# Google, Slack y GitLab, que no llevan ninguna de esas palabras al lado.
PATRON='api[_-]?key|apikey|access[_-]?token|auth[_-]?token|secret|passwd|password|client[_-]?secret|bearer'
PATRON="$PATRON|-----BEGIN [A-Z ]*PRIVATE KEY"      # claves SSH/PGP/TLS
PATRON="$PATRON|ghp_[A-Za-z0-9]{20}|github_pat_[A-Za-z0-9_]{20}"
PATRON="$PATRON|eyJ[A-Za-z0-9_-]{10}"               # JWT
PATRON="$PATRON|AKIA[0-9A-Z]{12}"                   # AWS
PATRON="$PATRON|AIza[0-9A-Za-z_-]{30}"              # Google
PATRON="$PATRON|xox[baprs]-[0-9A-Za-z-]{10}"        # Slack
PATRON="$PATRON|glpat-[0-9A-Za-z_-]{15}"            # GitLab
PATRON="$PATRON|hf_[A-Za-z0-9]{20}|npm_[A-Za-z0-9]{20}"
# 'sk-' pedia caracteres detras: si no, casaba con task-, disk-, desk-...
PATRON="$PATRON|sk-[A-Za-z0-9_-]{16}"

# Falsos positivos ya revisados uno a uno. Un escaner que siempre sale en
# rojo se deja de leer, asi que el ruido conocido se filtra a proposito.
RUIDO='tokenColorCustomizations|semanticTokenColor'          # temas de VS Code
RUIDO="$RUIDO|password managers|World\.Secrets|KeePassXC"    # ejemplos heredados de niri
RUIDO="$RUIDO|key_get_link|requires_key"                     # end-4: nombran una key, no la contienen
RUIDO="$RUIDO|\"key_id\"|key_id:"                              # acotado: antes casaba dentro de cualquier token
RUIDO="$RUIDO|Password(Field|Icon|Focus)|HoverPassword"      # tema de SDDM: son colores
RUIDO="$RUIDO|HideCompletePassword|AllowEmptyPassword"       # tema de SDDM: son booleanos
RUIDO="$RUIDO|TranslatePlaceholderPassword"
RUIDO="$RUIDO|changePassword|requirePasswordToPower"         # un comando y un booleano
# Comentarios en prosa del tema de SDDM. Se listan uno a uno en vez de
# ignorar todos los comentarios: una clave pegada en un comentario es
# exactamente lo que este escaneo tiene que seguir cazando.
RUIDO="$RUIDO|focuses password field|Hides the password while typing"
RUIDO="$RUIDO|users without a password"

# El propio script se excluye: su variable PATRON contiene justo las palabras
# que busca, asi que se encontraba a si mismo en cada ejecucion.
# --exclude=README.md excluia por nombre en TODO el arbol, incluidos los de
# los temas de spicetify. Se filtra despues, solo el de la raiz.
RESULTADO=$(grep -rniE "$PATRON" "$DOTS" \
    --exclude-dir=.git --exclude=pkglist.txt \
    --exclude=dotfiles-setup.sh 2>/dev/null \
    | grep -v "^$DOTS/README.md:" \
    | grep -viE "$RUIDO")

if [ -n "$RESULTADO" ]; then
    echo "$RESULTADO"
    echo
    err "HAY COINCIDENCIAS. Revísalas una por una antes de subir."
    SECRETOS=1
else
    ok "sin coincidencias nuevas (los falsos positivos conocidos están filtrados)"
    SECRETOS=0
fi

# La clave de OpenRouter no vive en config.json, pero conviene mirarlo:
# si algun dia la pegas ahi, este repo es publico.
if [ -f "$DOTS/illogical-impulse/.config/illogical-impulse/config.json" ]; then
    if grep -qE '"(api_?key|token)" *: *"[^"]{12,}"' \
        "$DOTS/illogical-impulse/.config/illogical-impulse/config.json" 2>/dev/null; then
        err "config.json parece contener una clave larga. NO SUBAS sin mirarlo."
        SECRETOS=1
    fi
fi

# ---------- restos de shells desinstalados ----------
say "Comprobando restos de shells anteriores"
RESTOS=()
for d in "$HOME/.local/state/noctalia" "$HOME/.local/state/caelestia" \
         "$HOME/.config/noctalia" "$HOME/.config/DankMaterialShell" \
         "$HOME/.config/caffyne-shell" "$HOME/.config/niri"; do
    [ -e "$d" ] && RESTOS+=("$d")
done
if [ ${#RESTOS[@]} -gt 0 ]; then
    for d in "${RESTOS[@]}"; do warn "resto: $d"; done
    AVISOS+=("borrar restos: rm -rf ${RESTOS[*]}")
else
    ok "sin restos"
fi

if pacman -Qq niri >/dev/null 2>&1; then
    warn "el paquete niri sigue instalado"
    AVISOS+=("desinstalar niri: sudo pacman -Rns niri xwayland-satellite")
fi

# window-reopen usaba el IPC de niri y en Hyprland no sirve para nada.
if [ -f "$HOME/.local/bin/window-reopen" ]; then
    warn "~/.local/bin/window-reopen usa el IPC de niri; ya no funciona"
    AVISOS+=("borrar ~/.local/bin/window-reopen")
fi

# ---------- git ----------
say "Guardando en git"

# Sin '-e', un cd fallido no aborta: 'git init' + 'git add -A' correrian en el
# directorio desde el que lanzaste el script. Si eso es $HOME, seria un repo
# de tu home entero, .ssh incluido, con instrucciones de publicarlo.
cd "$DOTS" || { err "no pude entrar en $DOTS"; exit 1; }

# Un secreto detectado NO se commitea: sacarlo del historial despues obliga a
# reescribirlo, y el repo es publico.
if [ "$SECRETOS" = "1" ]; then
    err "El escaneo encontró coincidencias: NO se hace commit."
    err "Revísalas arriba. Si son falsos positivos, añádelas a RUIDO."
    err "Los archivos ya están copiados en $DOTS; nada se ha subido."
    exit 2
fi

if [ "$MODO" = "crear" ]; then
    git init -b main -q
fi

# Estados en los que 'git add -A' hace algo distinto de lo que uno espera.
if [ -e .git/MERGE_HEAD ] || [ -d .git/rebase-merge ] || [ -d .git/rebase-apply ]; then
    err "hay un merge o rebase a medias: un commit ahora los daría por resueltos"
    err "termínalo o abórtalo y vuelve a ejecutar"
    exit 1
fi
if ! git symbolic-ref -q HEAD >/dev/null; then
    err "HEAD está desacoplado: el commit quedaría huérfano y no lo subirías"
    err "vuelve a una rama:  git switch main"
    exit 1
fi

git add -A
if git diff --cached --quiet; then
    ok "sin cambios que guardar"
else
    MENSAJE="Actualizar configuración"
    [ "$MODO" = "crear" ] && MENSAJE="Configuración inicial: CachyOS + Hyprland + end-4"

    # 'git -c' PISA la identidad configurada, no es un fallback. Solo se pasa
    # si git no encuentra ninguna, para no estampar un correo ajeno en los
    # commits de un repo publico.
    if git config user.email >/dev/null 2>&1 && git config user.name >/dev/null 2>&1; then
        git commit -q -m "$MENSAJE"
    else
        warn "git no tiene identidad configurada; se usa una por defecto"
        warn "para cambiarla:  git config --global user.email tu@correo"
        git -c user.email="${GIT_AUTHOR_EMAIL:-emilio@clip.tech}" \
            -c user.name="${GIT_AUTHOR_NAME:-${USER:-marcrock}}" \
            commit -q -m "$MENSAJE"
    fi
    ok "commit hecho — $(git rev-list --count HEAD) en total"
fi

# ---------- resumen ----------
say "Resumen"
echo "    Copiados: $COPIADOS elementos"
if [ ${#FALTANTES[@]} -gt 0 ]; then
    echo "    No encontrados:"
    for f in "${FALTANTES[@]}"; do echo "      - $f"; done
fi
if [ ${#AVISOS[@]} -gt 0 ]; then
    echo "    Pendientes:"
    for a in "${AVISOS[@]}"; do echo "      - $a"; done
fi

say "Siguiente paso"
if git remote get-url origin >/dev/null 2>&1; then
    cat <<FINAL

  Sube los cambios:
      cd ~/dotfiles && git push

FINAL
else
    cat <<FINAL

  Subir a GitHub (primera vez):
      cd ~/dotfiles
      gh repo create dotfiles --public --source=. --push

FINAL
fi

[ "$SECRETOS" = "1" ] && err "El escaneo encontró coincidencias. No subas sin revisarlas."
exit 0
