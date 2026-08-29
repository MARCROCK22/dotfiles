# dotfiles

Configuración de escritorio para **CachyOS + Hyprland + end-4 (illogical-impulse)**.

Este repo contiene **solo lo que va encima de end-4**, no end-4 entero.

## Qué hay aquí

| Carpeta | Contenido |
|---|---|
| `hypr/` | `custom/*.lua` — mis overrides de Hyprland, y `hypridle.conf`. **No** van aquí `monitors.lua` (es de cada máquina) ni `custom/scripts/__restore_video_wallpaper.sh` (lo genera `switchwall.sh`, y lo hace con un `mv` encima, que sustituye el enlace de stow en cada cambio de fondo) |
| `illogical-impulse/` | `config.json` del shell (barra, dock, sidebars, temas) |
| `patches/` | Diffs sobre archivos de end-4. Los aplica `install.py` con `patch` |
| `alacritty/` | Terminal |
| `bin/` | Scripts propios (`recorder`: grabación de pantalla; `reparar-pantallas`: recupera el DisplayPort cuando despierta sin EDID) |
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
git clone https://github.com/MARCROCK22/dotfiles.git ~/dotfiles
cd ~/dotfiles
sudo pacman -S --needed - < pkglist.txt
python3 install.py
```

`install.py` es interactivo: enlaza con **stow** los paquetes de configuración,
instala los archivos de sistema con sudo, **configura los monitores** leyendo
`hyprctl monitors all -j`, y aplica los parches de end-4 con `patch`, haciendo
un `--dry-run` de cada uno antes de tocar nada.

> Si vas a instalar en un equipo nuevo, lee primero **[MIGRACION-PC.md](MIGRACION-PC.md)**.
> Cubre el dual boot con Windows, los ajustes de BIOS y las diferencias de
> hardware.

## Configuración de pantallas

La hace `install.py`. Detecta las pantallas conectadas y escribe
`~/.config/hypr/monitors.lua`, que `hyprland.lua` de end-4 carga **después** de
`custom/` — así que gana sobre cualquier otra cosa.

```bash
python3 install.py --solo-monitores
```

Pregunta modo, escala y posición por cada pantalla, ofreciendo los modos reales
que reporta el driver. Soporta varios monitores: `hl.monitor()` es acumulativo,
una llamada por pantalla.

## Lo que hay que revisar a mano

**Los parches de `patches/`.** Son diffs sobre archivos de end-4, no copias
enteras: así `patch` mete el cambio sobre la versión nueva y conservas también
las mejoras de end-4. `install.py` hace `--dry-run` de cada uno y solo aplica
los que encajan; si alguno deja de aplicar, te dice qué línea no cuadra.

Dos de los tres son **bugs ajenos**, no personalización: popups recortados en
los bordes (end-4) y overview gris (plugin scrolloverview). Si se arreglan
aguas arriba, esos parches se borran.

El ciclo completo tras cada actualización está en **[MANTENIMIENTO.md](MANTENIMIENTO.md)**.

| Archivo | Por qué está modificado |
|---|---|
| `bar/BarContent.qml` | Disposición: recursos a la izquierda, workspaces centrados, reloj a la derecha |
| `bar/StyledPopup.qml` | **Bug de end-4**: `margins.left` no se acota a la pantalla, los popups se recortan cerca de un borde |
| `background/Background.qml` | **Bug de scrolloverview**: el plugin solo dibuja `LAYER_BACKGROUND` y end-4 pinta en `WlrLayer.Bottom`, así que el overview salía gris |

**El plugin del overview.** No es un paquete de pacman:

```bash
hyprpm add https://github.com/yayuuu/hyprland-scroll-overview.git
hyprpm update && hyprpm enable scrolloverview
```

La ruta del `.so` en `custom/general.lua` lleva el nombre de usuario dentro
(`/var/cache/hyprpm/<usuario>/...`). **`install.py` lo detecta y ofrece
corregirlo** si la ruta no existe.

Y recuerda: **cada `hyprpm update` recompila el `.so`**, y tras cada
actualización de Hyprland hay que repetirlo o el plugin deja de cargar.

## Notas

- **Hyprland 0.55+ usa Lua**, no hyprlang. `hyprctl keyword` falla con
  *"can't work with non-legacy parsers"*; para probar en caliente, `hyprctl eval`.
- **`custom/` gana sobre `hyprland/`**: se carga después. Nunca editar
  `~/.config/hypr/hyprland/`, lo pisa cada actualización de end-4.
- **Los plugins de hyprpm se compilan contra la versión exacta de Hyprland.**
  Tras cada actualización del compositor hay que volver a lanzar `hyprpm update`
  o el plugin deja de cargar.
- **Nvidia**: `system/nvidia/` limita la fuga de VRAM del driver (~1 GiB en vez
  de ~100 MiB). Solo importa cuando el compositor corre **sobre** la Nvidia; en
  modo híbrido, con la sesión en la Intel, no interviene.
- **`prime-run`**: en portátiles con gráficos híbridos, los juegos necesitan
  `prime-run %command%` en las opciones de lanzamiento de Steam.

## Migración al PC de escritorio (dual boot con Windows)

Tres cosas que hay que hacer **antes** de instalar, en este orden.

**1. Reducir la partición desde Windows.** Usar el Administrador de discos de
Windows, no el instalador de Linux. Dejar el hueco sin formatear y que CachyOS
lo use.

**2. Desactivar el Inicio rápido de Windows.** Panel de control → Opciones de
energía → Comportamiento de los botones de inicio/apagado. Sin esto Windows
deja el disco en hibernación, y Linux lo monta en solo lectura o lo corrompe.
En dual boot no es opcional.

**3. Poner el reloj del hardware en UTC.** Windows asume hora local y Linux
asume UTC; sin arreglarlo la hora se desfasa varias horas cada vez que se
cambia de sistema. En PowerShell como administrador:

```powershell
reg add "HKLM\SYSTEM\CurrentControlSet\Control\TimeZoneInformation" /v RealTimeIsUniversal /t REG_DWORD /d 1 /f
```

### Arranque

- CachyOS usa **limine**, no GRUB. Los tutoriales de dual boot que se
  encuentran por ahí hablan de GRUB y no aplican directamente.
- En ASUS: `Esc` para el menú de arranque, `F2` para la BIOS. Secure Boot solo
  se puede desactivar **después** de establecer una contraseña de
  administrador; hasta entonces la opción aparece en gris.

### Diferencias de hardware entre los dos equipos

|  | Laptop (ASUS TUF) | PC de escritorio |
|---|---|---|
| GPU | Intel Iris Xe + RTX 3050 | RTX 4060 sola |
| Compositor corre en | la Intel | la Nvidia, siempre |
| `prime-run` | necesario para juegos | no aplica |
| `supergfxctl` | gestiona el cambio | no aplica |
| Perfil de VRAM | necesario | **también necesario** |

En el PC no hay gráficos híbridos, así que todo pasa por el driver de Nvidia
desde el arranque. Verificar `nvidia_drm.modeset=1` y usar driver 555 o
superior, que es donde llegó *explicit sync*.
