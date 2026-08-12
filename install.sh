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
echo
echo "    Y ANTES de nada, los dotfiles de end-4:"
echo "      bash <(curl -s https://ii.clsty.link/get)"
echo "    Este repo solo trae los cambios ENCIMA de lo suyo."

echo "==> Enlazando configuración de usuario con stow"
command -v stow >/dev/null || { echo "Falta stow: sudo pacman -S stow"; exit 1; }
stow hypr illogical-impulse alacritty bin spicetify fish fastfetch starship
# quickshell/ NO se enlaza: ver el apartado de parches más abajo.

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
    mkdir -p ~/Pictures/wallpapers
    cp wallpaper/* ~/Pictures/wallpapers/
    echo "    copiado a ~/Pictures/wallpapers"
    echo "    Aplicalo con Ctrl+Super+T para que se regenere la paleta."
fi

echo
echo "==> PARCHES DE end-4 — paso manual, a propósito"
cat <<'PARCHES'
    quickshell/ contiene archivos de end-4 MODIFICADOS. No se despliegan
    solos porque SOBRESCRIBEN los suyos, y si tu version de end-4 no es la
    misma con la que se generaron, te romperian la barra.

    Compara antes de copiar nada:

      for f in modules/ii/bar/BarContent.qml \
               modules/ii/bar/StyledPopup.qml \
               modules/ii/background/Background.qml; do
          echo "--- $f"
          diff "$HOME/.config/quickshell/ii/$f" \
               "quickshell/.config/quickshell/ii/$f"
      done

    Si el diff solo muestra los cambios que esperas, copia. Si muestra
    lineas ajenas, tu end-4 es de otra version: reaplica los cambios a mano.

    Que hace cada uno:
      BarContent.qml    disposicion de la barra (recursos izq, reloj der)
      StyledPopup.qml   bug de end-4: popups recortados cerca de los bordes
      Background.qml    bug de scrolloverview: WlrLayer.Bottom -> Background
PARCHES

echo
echo "==> Plugin del overview"
echo "    hyprpm add https://github.com/yayuuu/hyprland-scroll-overview.git"
echo "    hyprpm update && hyprpm enable scrolloverview"
echo
echo "    La ruta del .so en custom/general.lua lleva TU usuario:"
echo "      /var/cache/hyprpm/<usuario>/hyprland-scroll-overview/scrolloverview.so"
echo "    Ajustala si el usuario de esta maquina es otro."

echo
echo "==> Monitor"
echo "    custom/general.lua trae el output de la maquina anterior."
echo "    Cambialo por el de esta:  hyprctl monitors"
