#!/usr/bin/env bash
#
# dotfiles-setup.sh  (v12)
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
#
# Uso:  bash dotfiles-setup.sh
#

set -uo pipefail

VERSION="12"
DOTS="$HOME/dotfiles"
ESTE="$(readlink -f "${BASH_SOURCE[0]}")"
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
mkdir -p "$DOTS"/quickshell/.config/quickshell/ii/modules/ii/{bar,background}
ok "directorios listos"

# ---------- configuración de usuario ----------
say "Copiando configuración de usuario"

# Solo custom/: hyprland.lua y la carpeta hyprland/ son de end-4 y las
# sobrescribe su instalador. Lo tuyo vive entero en custom/.
if [ -d "$HOME/.config/hypr/custom" ]; then
    rm -rf "$DOTS/hypr/.config/hypr/custom"
    mkdir -p "$DOTS/hypr/.config/hypr/custom"
    if cp -r "$HOME/.config/hypr/custom/." "$DOTS/hypr/.config/hypr/custom/"; then
        limpiar_bak "$DOTS/hypr/.config/hypr/custom"
        N=$(find "$DOTS/hypr/.config/hypr/custom" -type f | wc -l)
        ok "hypr / custom/ ($N archivo(s), sin respaldos)"
        COPIADOS=$((COPIADOS + 1))
    else
        err "fallo copiando hypr/custom"
    fi
else
    warn "no existe ~/.config/hypr/custom"
    FALTANTES+=("hypr/custom")
fi

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
copiar_opcional "$HOME/.config/fish/functions"   "$DOTS/fish/.config/fish" "fish / functions"
copiar_opcional "$HOME/.config/fish/conf.d"      "$DOTS/fish/.config/fish" "fish / conf.d"
# fish_variables se excluye a propósito: lo genera fish solo y cambia constantemente
# VS Code se excluye a proposito: el repo es publico y sus ajustes pueden
# arrastrar rutas, tokens de extensiones y configuracion de trabajo.
copiar "$HOME/.config/spicetify"                  "$DOTS/spicetify/.config"           "spicetify"
copiar "$HOME/.config/fastfetch/config.jsonc"     "$DOTS/fastfetch/.config/fastfetch" "fastfetch"
copiar "$HOME/.config/starship.toml"              "$DOTS/starship/.config"            "starship (prompt)"

# ---------- parches sobre end-4 ----------
say "Copiando los parches de end-4"

# Estos NO son configuración: son archivos del propio end-4 modificados.
# Se versionan porque cada actualizacion suya los pisa y hay que reaplicarlos.
# install.py NO los despliega solo, precisamente porque sobrescriben.
QS="$HOME/.config/quickshell/ii/modules/ii"
PARCHES=(
    "bar/BarContent.qml|disposición de barra: recursos a la izquierda, reloj a la derecha"
    "bar/StyledPopup.qml|bug de end-4: popups recortados en los bordes"
    "background/Background.qml|bug de scrolloverview: WlrLayer.Bottom -> Background"
)
for entrada in "${PARCHES[@]}"; do
    ruta="${entrada%%|*}"
    desc="${entrada##*|}"
    if [ -f "$QS/$ruta" ]; then
        mkdir -p "$DOTS/quickshell/.config/quickshell/ii/modules/ii/$(dirname "$ruta")"
        cp "$QS/$ruta" "$DOTS/quickshell/.config/quickshell/ii/modules/ii/$ruta"
        ok "$(basename "$ruta") — $desc"
        COPIADOS=$((COPIADOS + 1))
    else
        warn "no encontrado: $ruta"
        FALTANTES+=("parche $ruta")
    fi
done

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
    sudo cp "$NVIDIA_SRC" "$DOTS/system/nvidia/"
    ok "perfil de VRAM de Nvidia"
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
        sudo cp "$candidato" "$DOTS/system/sddm/theme.conf"
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

sudo chown -R "$USER:$USER" "$DOTS/system" 2>/dev/null

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
| `quickshell/` | Archivos de end-4 **modificados**. `install.py` pregunta antes |
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
- **Los parches de `quickshell/`**: sobrescriben archivos de end-4. `install.py`
  te enseña el diff y pregunta uno por uno.
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
RUIDO="$RUIDO|key_get_link|requires_key|key_id"              # end-4: nombran una key, no la contienen
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
RESULTADO=$(grep -rniE "$PATRON" "$DOTS" \
    --exclude-dir=.git --exclude=README.md --exclude=pkglist.txt \
    --exclude=dotfiles-setup.sh 2>/dev/null \
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
