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
git clone https://github.com/MARCROCK22/dotfiles.git ~/dotfiles
cd ~/dotfiles
sudo pacman -S --needed - < pkglist.txt
./install.sh
```

Después hay que crear `~/.config/niri/machine.kdl` a mano. Ejemplo para un
equipo de escritorio (sin bloque `touchpad`):

```kdl
output "DP-1" {
    mode "2560x1440@144.000"
    scale 1
}
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
