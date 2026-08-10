#!/usr/bin/env bash
#
# dotfiles-setup.sh  (v2)
# Monta o actualiza el repositorio de dotfiles para CachyOS + Niri + Caffyne.
#
# Es idempotente: puedes ejecutarlo las veces que quieras. Si ~/dotfiles ya
# existe, actualiza las copias y hace un commit con los cambios.
#
# NO borra ni modifica ninguna configuración existente. Todo son copias.
#
# Uso:  bash dotfiles-setup.sh
#

set -uo pipefail

VERSION="6"
DOTS="$HOME/dotfiles"
ESTE="$(readlink -f "${BASH_SOURCE[0]}")"
FALTANTES=()
AVISOS=()
COPIADOS=0

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
# Para rutas que legítimamente pueden no estar (conf.d de fish, por ejemplo).
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
        err "Usa siempre la del repo, que es la actualizada:"
        err "  bash $DOTS/dotfiles-setup.sh"
        exit 1
    fi
fi

if [ ! -d "$HOME/.config/niri" ]; then
    err "No existe ~/.config/niri. ¿Seguro que estás en la máquina con Niri?"
    exit 1
fi

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

# ---------- estructura ----------
say "Preparando estructura"
mkdir -p "$DOTS"/{niri/.config/niri,hypr/.config/hypr,alacritty/.config/alacritty}
mkdir -p "$DOTS"/{bin/.local/bin,caffyne/.config/caffyne-shell/config,spicetify/.config}
mkdir -p "$DOTS"/{fish/.config/fish,fastfetch/.config/fastfetch,starship/.config}
mkdir -p "$DOTS"/{system/nvidia,system/sddm,wallpaper}
ok "directorios listos"

# ---------- configuración de usuario ----------
say "Copiando configuración de usuario"

copiar "$HOME/.config/niri/config.kdl"            "$DOTS/niri/.config/niri"           "niri / config.kdl"
copiar "$HOME/.config/hypr/hyprlock.conf"         "$DOTS/hypr/.config/hypr"           "hyprlock"
copiar "$HOME/.config/alacritty/alacritty.toml"   "$DOTS/alacritty/.config/alacritty" "alacritty"
copiar "$HOME/.local/bin/recorder"                "$DOTS/bin/.local/bin"              "script recorder"
copiar          "$HOME/.config/fish/config.fish" "$DOTS/fish/.config/fish" "fish / config.fish"
copiar_opcional "$HOME/.config/fish/functions"   "$DOTS/fish/.config/fish" "fish / functions (saludo y funciones propias)"
copiar_opcional "$HOME/.config/fish/conf.d"      "$DOTS/fish/.config/fish" "fish / conf.d"
# fish_variables se excluye a propósito: lo genera fish solo y cambia constantemente
# VS Code se excluye a proposito: el repo es publico y sus ajustes pueden
# arrastrar rutas, tokens de extensiones y configuracion de trabajo.
copiar "$HOME/.config/spicetify"                  "$DOTS/spicetify/.config"           "spicetify"
copiar "$HOME/.config/fastfetch/config.jsonc"     "$DOTS/fastfetch/.config/fastfetch" "fastfetch"
copiar "$HOME/.config/starship.toml"              "$DOTS/starship/.config"            "starship (prompt)"

# Caffyne: solo config.json, que vive en el subdirectorio config/.
# Se excluyen a propósito:
#   - launcher_usage.json  (estadísticas de uso, cambian solas)
#   - themes/              (vienen con el proyecto, no son tuyos)
copiar "$HOME/.config/caffyne-shell/config/config.json" \
       "$DOTS/caffyne/.config/caffyne-shell/config" "caffyne / config.json"

# ---------- wallpaper actual ----------
say "Detectando wallpaper actual"

WP=""
if command -v awww >/dev/null 2>&1; then
    WP=$(awww query 2>/dev/null | grep -oP 'image: \K.*' | head -1)
elif command -v swww >/dev/null 2>&1; then
    WP=$(swww query 2>/dev/null | grep -oP 'image: \K.*' | head -1)
fi

if [ -n "$WP" ] && [ -f "$WP" ]; then
    rm -f "$DOTS"/wallpaper/* 2>/dev/null
    cp "$WP" "$DOTS/wallpaper/"
    ok "wallpaper: $(basename "$WP")"
    COPIADOS=$((COPIADOS + 1))
else
    warn "no se pudo detectar el wallpaper en uso"
    AVISOS+=("copiar el wallpaper a mano a ~/dotfiles/wallpaper/")
fi

# ---------- archivos de sistema ----------
say "Copiando archivos de sistema (pedirá sudo)"

NVIDIA_SRC="/etc/nvidia/nvidia-application-profiles-rc.d/50-limit-free-buffer-pool-in-wayland-compositors.json"
if sudo test -e "$NVIDIA_SRC"; then
    sudo cp "$NVIDIA_SRC" "$DOTS/system/nvidia/"
    ok "perfil de VRAM de Nvidia"
else
    warn "no encontrado el perfil de Nvidia"
    FALTANTES+=("perfil nvidia")
fi

# SDDM: aceptar tanto el nombre correcto como el que tiene una coma por error.
# En el repo siempre se guarda como theme.conf, que es lo que install.sh espera.
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

sudo chown -R "$USER:$USER" "$DOTS/system" 2>/dev/null

# ---------- lista de paquetes ----------
say "Generando lista de paquetes"
pacman -Qqe > "$DOTS/pkglist.txt"
ok "$(wc -l < "$DOTS/pkglist.txt") paquetes explícitos"

# ---------- install.sh ----------
say "Generando archivos del repo"
cat > "$DOTS/install.sh" <<'INSTALL_EOF'
#!/usr/bin/env bash
#
# Despliega estos dotfiles en una máquina nueva.
# Uso:  ./install.sh
#
set -euo pipefail
cd "$(dirname "$0")"

echo "==> Paquetes"
echo "    Para instalarlos todos:"
echo "      sudo pacman -S --needed - < pkglist.txt"

echo "==> Enlazando configuración de usuario con stow"
command -v stow >/dev/null || { echo "Falta stow: sudo pacman -S stow"; exit 1; }
stow niri hypr alacritty bin caffyne spicetify fish fastfetch starship

echo "==> Archivos de sistema (sudo)"
if [ -f system/nvidia/50-limit-free-buffer-pool-in-wayland-compositors.json ]; then
    sudo install -Dm644 \
      system/nvidia/50-limit-free-buffer-pool-in-wayland-compositors.json \
      /etc/nvidia/nvidia-application-profiles-rc.d/50-limit-free-buffer-pool-in-wayland-compositors.json
    echo "    perfil de VRAM de Nvidia instalado"
fi
if [ -f system/sddm/theme.conf ]; then
    sudo install -Dm644 system/sddm/theme.conf /etc/sddm.conf.d/theme.conf
    echo "    tema de SDDM instalado"
fi

echo "==> Wallpaper"
if compgen -G "wallpaper/*" > /dev/null; then
    mkdir -p ~/.config/caffyne-shell/wallpapers
    cp wallpaper/* ~/.config/caffyne-shell/wallpapers/
    echo "    copiado. Aplícalo desde el Dash de Caffyne para que matugen genere la paleta."
fi

echo
echo "==> Falta un paso manual"
echo "    Crea ~/.config/niri/machine.kdl con el output y el touchpad de ESTA máquina."
echo "    En un PC de escritorio, omite el bloque touchpad."
echo
echo "    Ejemplo:"
echo '      output "DP-1" {'
echo '          mode "2560x1440@144.000"'
echo '          scale 1'
echo '      }'
INSTALL_EOF
chmod +x "$DOTS/install.sh"
ok "install.sh"

# El propio script vive en el repo: así solo existe una versión canónica y no
# se puede ejecutar por accidente una copia vieja guardada en otro sitio.
if [ "$ESTE" != "$(readlink -f "$DOTS/dotfiles-setup.sh" 2>/dev/null)" ]; then
    cp "$ESTE" "$DOTS/dotfiles-setup.sh"
    chmod +x "$DOTS/dotfiles-setup.sh"
    ok "dotfiles-setup.sh copiado al repo (v$VERSION)"
fi

# .gitignore: si no existe se crea entero; si ya existe solo se añaden las
# entradas que falten, para no borrar lo que hayas puesto tú a mano.
if [ ! -f "$DOTS/.gitignore" ]; then
    cat > "$DOTS/.gitignore" <<'GIT_EOF'
# Específico de cada máquina: nunca se comparte
machine.kdl

# Estadísticas de uso, cambian solas
launcher_usage.json

# Variables universales de fish: las genera fish y cambian constantemente
fish_variables

# Ruido
*.log
*.bak
.cache/
GIT_EOF
    ok ".gitignore creado"
else
    NUEVAS=0
    for entrada in machine.kdl launcher_usage.json fish_variables '*.log' '*.bak' '.cache/'; do
        grep -qxF "$entrada" "$DOTS/.gitignore" || { echo "$entrada" >> "$DOTS/.gitignore"; NUEVAS=$((NUEVAS + 1)); }
    done
    if [ "$NUEVAS" -gt 0 ]; then
        ok ".gitignore actualizado ($NUEVAS entrada(s) nueva(s))"
    else
        ok ".gitignore ya estaba completo"
    fi
fi

# README: se genera SOLO si no existe. A partir de ahí es tuyo — puedes
# ampliarlo y el script no lo tocará. (Antes lo sobrescribía en cada
# ejecución y se llevaba por delante lo que hubieras añadido.)
if [ -f "$DOTS/README.md" ]; then
    ok "README.md existente — no se toca"
else
cat > "$DOTS/README.md" <<'README_EOF'
# dotfiles

Configuración de escritorio para **CachyOS + Niri + Caffyne**.

## Qué hay aquí

| Carpeta | Contenido |
|---|---|
| `niri/` | Configuración del compositor (sin lo específico de máquina) |
| `hypr/` | `hyprlock.conf` — pantalla de bloqueo |
| `alacritty/` | Terminal |
| `bin/` | Scripts propios (`recorder`: grabación de pantalla) |
| `caffyne/` | `config.json` del shell Caffyne |
| `spicetify/` | Tema de Spotify |
| `fish/` | Shell |
| `fastfetch/` | Resumen del sistema al abrir la terminal |
| `system/` | Archivos de `/etc`, los instala `install.sh` |
| `wallpaper/` | Fondo actual — matugen genera la paleta a partir de él |

## Instalación en una máquina nueva

```bash
git clone <este-repo> ~/dotfiles
cd ~/dotfiles
sudo pacman -S --needed - < pkglist.txt
./install.sh
```

## Lo que NO está aquí

`~/.config/niri/machine.kdl` — monitor y touchpad, distinto en cada equipo.
Está en `.gitignore` a propósito; hay que crearlo a mano tras instalar.

## Notas

- **Nvidia + Niri**: `system/nvidia/` contiene el perfil que limita la fuga de
  VRAM del driver. Sin él, niri consume ~1 GiB en vez de ~100 MiB.
- **Caffyne** no es un paquete de pacman, sino un clon de git en
  `~/.config/caffyne-shell`. Sus dependencias aparecen como huérfanas para
  pacman: **no ejecutar `pacman -Rns $(pacman -Qtdq)` sin revisar la lista.**
- **`prime-run`**: en portátiles con gráficos híbridos, los juegos necesitan
  `prime-run %command%` en las opciones de lanzamiento de Steam.
README_EOF
ok "README.md creado"
fi

# ---------- escaneo de secretos ----------
say "Escaneando en busca de secretos (el repo es público)"

# Se excluyen los falsos positivos ya revisados:
#   - tokenColorCustomizations / semanticTokenColorCustomizations (temas de VS Code)
#   - los comentarios y ejemplos que Niri trae por defecto sobre gestores de contraseñas
PATRON='api[_-]?key|apikey|access[_-]?token|auth[_-]?token|secret|passwd|password|client[_-]?secret|bearer|ghp_|github_pat_|sk-'
RESULTADO=$(grep -rniE "$PATRON" "$DOTS" \
    --exclude-dir=.git --exclude=README.md --exclude=pkglist.txt 2>/dev/null \
    | grep -viE 'tokenColorCustomizations|semanticTokenColor|password managers|World\.Secrets|KeePassXC')

if [ -n "$RESULTADO" ]; then
    echo "$RESULTADO"
    echo
    err "HAY COINCIDENCIAS. Revísalas una por una antes de subir."
    SECRETOS=1
else
    ok "sin coincidencias nuevas (los falsos positivos conocidos están filtrados)"
    SECRETOS=0
fi

# ---------- restos de shells desinstalados ----------
say "Comprobando restos de shells anteriores"
RESTOS=()
for d in "$HOME/.local/state/noctalia" "$HOME/.local/state/caelestia" \
         "$HOME/.config/noctalia" "$HOME/.config/DankMaterialShell"; do
    [ -e "$d" ] && RESTOS+=("$d")
done
if [ ${#RESTOS[@]} -gt 0 ]; then
    for d in "${RESTOS[@]}"; do warn "resto: $d"; done
    AVISOS+=("borrar restos: rm -rf ${RESTOS[*]}")
else
    ok "sin restos"
fi

# ---------- git ----------
say "Guardando en git"
cd "$DOTS"

if [ "$MODO" = "crear" ]; then
    git init -b main -q
fi

git add -A
if git diff --cached --quiet; then
    ok "sin cambios que guardar"
else
    MENSAJE="Actualizar configuración"
    [ "$MODO" = "crear" ] && MENSAJE="Configuración inicial: CachyOS + Niri + Caffyne"
    git -c user.email="${GIT_AUTHOR_EMAIL:-emilio@clip.tech}" \
        -c user.name="${GIT_AUTHOR_NAME:-$USER}" \
        commit -q -m "$MENSAJE"
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

  Ya tienes remoto configurado. Sube los cambios:
      cd ~/dotfiles && git push

FINAL
else
    cat <<FINAL

  Subir a GitHub (primera vez):
      cd ~/dotfiles
      gh repo create dotfiles --public --source=. --push

  Después, para pasar a enlaces simbólicos (opcional, borra los originales):
      sudo pacman -S --needed stow
      cd ~/dotfiles
      rm ~/.config/niri/config.kdl ~/.config/hypr/hyprlock.conf
      rm ~/.config/alacritty/alacritty.toml ~/.local/bin/recorder
      stow niri hypr alacritty bin

FINAL
fi

[ "$SECRETOS" = "1" ] && err "El escaneo encontró coincidencias. No subas sin revisarlas."
exit 0
