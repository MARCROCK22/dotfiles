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
    echo "    tema de SDDM seleccionado"
fi
if [ -f system/libinput/local-overrides.quirks ]; then
    sudo install -Dm644 system/libinput/local-overrides.quirks /etc/libinput/local-overrides.quirks
    echo "    quirks de libinput instalados (requiere reiniciar sesion)"
fi
if [ -d system/sddm-theme ]; then
    T=/usr/share/sddm/themes/sddm-astronaut-theme
    if [ -d "$T" ]; then
        [ -f system/sddm-theme/metadata.desktop ] && sudo install -Dm644 system/sddm-theme/metadata.desktop "$T/metadata.desktop"
        for f in system/sddm-theme/Themes/*.conf; do
            [ -f "$f" ] && sudo install -Dm644 "$f" "$T/Themes/$(basename "$f")"
        done
        echo "    personalizacion del tema sddm-astronaut restaurada"
    else
        echo "    AVISO: falta el paquete sddm-astronaut-theme, instalalo antes"
    fi
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
