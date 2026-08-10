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
stow niri hypr alacritty bin caffyne spicetify fish fastfetch

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
