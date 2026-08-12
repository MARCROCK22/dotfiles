# Migración al PC de escritorio

Guía para llevar este setup del portátil ASUS TUF al PC de escritorio, en dual
boot con Windows.

|  | Portátil (origen) | PC (destino) |
|---|---|---|
| CPU | Intel (híbrido) | **Ryzen 7 5800XT** — Zen 3, 8C/16T, AM4 |
| GPU | Intel Iris Xe + RTX 3050 | **RTX 4060 sola** |
| RAM | — | 32 GB |
| Disco | — | Samsung 870 EVO 2 TB, **uno solo**, con Windows |
| Compositor corre en | la Intel | **la Nvidia, siempre** |

La diferencia que lo cambia casi todo: **en el PC no hay gráficos híbridos**, así
que el compositor pasa por el driver de Nvidia desde el arranque.

---

## Antes de tocar el PC

### 1. BitLocker — esto primero, y no es opcional

Windows 11 activa **cifrado de dispositivo** automáticamente en muchas
instalaciones, aunque no veas "BitLocker" por ningún lado.

```powershell
manage-bde -status C:
```

Si hay cifrado activo:

1. **Guarda la clave de recuperación fuera del equipo** — `aka.ms/myrecoverykey`.
2. **Desactívalo** (Configuración → Privacidad y seguridad → Cifrado de dispositivo).
3. Espera a que termine de descifrar.

Por qué: BitLocker sella la clave en el TPM atado al **PCR 7**, que depende del
estado de Secure Boot. Desactivar Secure Boot —que el instalador de CachyOS
exige— hará que Windows pida la clave en cada arranque. Sin ella, no entras.

Y un aviso lateral: desactivar BitLocker **también desactiva Windows Hello**
(PIN, huella, cara). Asegúrate de saber la **contraseña** de tu cuenta, no solo
el PIN.

### 2. Actualizar la BIOS — el punto de mayor impacto de toda la lista

Hazlo **desde Windows, antes de instalar CachyOS**. Si lo haces después, la
actualización de BIOS borra la entrada NVRAM de limine y te quedas sin arrancar
Linux. Es el fallo más repetido en el foro de CachyOS.

**Piso de seguridad: AGESA ComboAM4v2PI ≥ 1.2.0.E.** Recomendado ≥ 1.2.0.10.
En 2026 hay hasta 1.2.0.12 para placas AM4.

Esto importa de verdad: `amd-ucode` **no puede** mitigar **EntrySign**
(CVE-2024-36347) ni **SinkClose** (CVE-2023-31315). Solo la BIOS.

> Avisa el foro: hay casos documentados donde una BIOS *más nueva* rompe CPPC y
> hay que bajar de versión. Mira los hilos de tu placa antes de saltar a la
> última.

### 3. Ajustes de BIOS

| Opción | Valor | Por qué |
|---|---|---|
| **Secure Boot** | Desactivado | El instalador lo exige |
| **CSM** | Desactivado | Arranque UEFI puro |
| **CPPC** | **Enabled**, no *Auto* | Sin `_CPC` te quedas en `acpi-cpufreq` sin avisar |
| **CPPC Preferred Cores** | Enabled | |
| Frecuencia de CPU | **Auto** | Un multiplicador fijo impide que cargue amd-pstate |
| Legacy USB Support | Auto | |

**CPPC está en `Advanced → AMD CBS → NBIO Common Options → SMU Common Options`**,
no bajo "AMD Overclocking". Y *Auto* no significa activado: su comportamiento lo
define el AGESA. Ponlo explícito.

Si tras instalar `amd-pstate` no carga, la causa más reportada en AM4 es el
**modo x2APIC**: ponlo en Auto/xAPIC.

### 4. Los tres de siempre

Ya los tienes documentados en el README: reducir la partición desde el
Administrador de discos de Windows, desactivar el Inicio rápido, y
`RealTimeIsUniversal=1` en el registro.

Añade uno más: **`chkdsk C: /f` y reinicia**. Si la ESP o el NTFS quedan
marcados como "sucios", Linux se niega a montarlos y `limine-scan` falla al
buscar el arranque de Windows.

Y apaga con **Apagar completo**, no con reinicio rápido.

---

## Particionado

### La ESP de Windows NO sirve

Windows crea una ESP de **100 MiB**. CachyOS con limine exige **≥ 4 GiB**
montados en `/boot`, y recomienda 8: cada snapshot arrancable copia kernel e
initramfs ahí, y limine no sabe leer btrfs.

Desde CachyOS 26.01 el instalador **te bloquea** si intentas "instalar junto a"
con una ESP pequeña.

**Solución: una segunda ESP propia.** Dos particiones EFI en el mismo disco GPT
es legal — el firmware las referencia por GUID. Y tiene una ventaja concreta:
las actualizaciones de Windows no pueden llenar ni reformatear la tuya.

### El punto de montaje es `/boot`, no `/boot/efi`

Esta es la trampa que más gente se come. `/boot/efi` es la convención de **GRUB**.
Con limine, `limine-entry-tool` **asume que `/boot` es la ESP**: escribe rutas
`boot():` que se resuelven a la partición desde la que arrancó. Si las separas,
los kernels quedan donde limine no los busca y no arranca.

### Esquema propuesto

| # | Partición | FS | Tamaño | Montaje | Acción |
|---|---|---|---|---|---|
| 1 | ESP Windows | FAT32 | 100 MiB | *(ninguno)* | **No tocar** |
| 2 | MSR | — | 16 MiB | — | **No tocar** |
| 3 | Windows C: | NTFS | 500–700 GB | — | Ya reducida |
| 4 | WinRE | NTFS | ~600 MiB | — | **No tocar** |
| 5 | **ESP CachyOS** | FAT32, tipo EFI System | **8 GiB** | **`/boot`** | Crear, flag `boot`/`esp` |
| 6 | **Root** | **btrfs** | 600–900 GB | **`/`** | Crear |
| 7 | Datos compartidos | NTFS | resto | — | Opcional |

**Usa particionado manual.** El wiki de CachyOS es explícito: *"Install alongside
and Replace partition are not 100% reliable... Manual partitioning is strongly
preferred."*

⚠️ En el resumen previo a instalar, **verifica que las cuatro particiones de
Windows aparecen sin formatear y sin punto de montaje.** Hay casos de gente que
formateó la ESP de Windows y tuvo que reparar con `bcdboot` desde el medio de
instalación.

### Swap: no

CachyOS crea **32 GB de zram** (comprimido, en RAM) y no hace swap en disco. Con
32 GB de RAM real es de sobra.

Solo necesitas swap real si quieres **hibernar** — y ver la sección de
hibernación más abajo antes de decidirlo.

---

## Instalación

1. Arranca el USB **en modo UEFI**. Confirma con `efibootmgr -v`; si dice *"EFI
   variables are not supported"*, arrancaste en Legacy.
2. Particionado **manual**, con el esquema de arriba.
3. Gestor de arranque: **Limine**. Sistema de ficheros: **btrfs**.
4. Un solo entorno de escritorio.

Si un intento falla, **reinicia desde la ISO** antes de reintentar: el instalador
no desmonta bien y encadenas errores.

### Primer arranque, antes de reiniciar a Windows

```bash
sudo limine-scan          # añade Windows al menú; elige "Windows Boot Manager"
limine-list               # verifica
cat /boot/limine.conf     # debe haber un bloque protocol: efi con uuid(...)
sudo limine-install --fallback
```

El `--fallback` escribe limine en `EFI/BOOT/BOOTX64.EFI`, la ruta que el firmware
busca por defecto. Es tu red de seguridad si una actualización de BIOS o de
Windows borra la entrada NVRAM. Añade `ENABLE_LIMINE_FALLBACK=yes` a
`/etc/default/limine` para que persista.

> El fallback **no se actualiza solo** cuando limine se actualiza. Re-ejecútalo
> de vez en cuando.

**Recuperación si un día no arranca:** USB live → `sudo cachy-chroot` →
`limine-install` → reiniciar. Eso es todo.

---

## GPU: RTX 4060 sola

### El driver ya no se elige

`nvidia` y `nvidia-dkms` **ya no existen en los repos de Arch**. Solo queda la
familia `nvidia-open`. Para Ada Lovelace no hay alternativa razonable (la única
sería fijarse a la rama legacy 580, perdiendo 30 versiones).

**Deja que el instalador haga su trabajo.** `chwd` detectará la 4060 y, al ver un
kernel `linux-cachyos`, instalará **`linux-cachyos-nvidia-open` precompilado** en
vez de compilar por DKMS. Eso te ahorra la clase de rotura que ya se ha dado
(fallo de build de `nvidia-open-dkms` contra kernels nuevos por cambios de LLVM).

Dos cosas que **no** debes hacer:
- No instales `nvidia-open` a secas en CachyOS — depende del kernel `linux` de Arch.
- No mantengas el kernel `linux` de Arch instalado en paralelo.

### Parámetros de kernel: ninguno

`nvidia_drm.modeset=1` y `fbdev=1` **ya son el default del driver** — verificado
en el código de los módulos abiertos (`nv_drm_modeset_module_param = true`). Las
guías que te digan que los añadas están desactualizadas.

CachyOS además configura el early KMS por su cuenta en
`/etc/mkinitcpio.conf.d/10-chwd.conf`. No lo edites.

### Suspensión: no toques nada

Mucha documentación —incluida **la wiki de Hyprland**— te dirá que habilites
`nvidia-suspend.service`, `nvidia-hibernate.service` y `nvidia-resume.service`, y
que pongas `NVreg_PreserveVideoMemoryAllocations=1`.

**En el driver 610 eso es incorrecto.** Fue sustituido por
`NVreg_UseKernelSuspendNotifiers=1`, y el paquete de Arch **desactiva esos
servicios a propósito** al actualizar. Seguir esa guía sería deshacer lo que Arch
hace bien.

Verificar:
```bash
sort /proc/driver/nvidia/params | grep -E 'UseKernelSuspendNotifiers|TemporaryFilePath'
# → 1  y  /var/tmp
```

### El perfil de VRAM sigue haciendo falta

El bug de NVIDIA lleva **abierto desde agosto de 2024** con 86 comentarios. Sin
él, el compositor retiene ~1 GiB en vez de ~100 MiB.

Ya lo tienes versionado en `system/nvidia/`, con la regla para `Hyprland` (con H
mayúscula, que es el nombre real del proceso). `install.py` lo despliega.

> Discrepancia sin resolver: la ArchWiki y la wiki de niri usan `"value": 0`; el
> issue original usa `1`. Nadie explica la diferencia. Empieza con `0`.

### Variables de entorno

**No añadas nada del portátil.** `__NV_PRIME_RENDER_OFFLOAD`,
`__VK_LAYER_NV_optimus` y `DRI_PRIME` son equipaje de híbrido.

`WLR_NO_HARDWARE_CURSORS` **es un no-op**: Hyprland dejó wlroots por Aquamarine y
la variable no existe en el código. Si la ves en alguna guía, ignórala. Su
sustituto es `cursor:use_cpu_buffer`, cuyo modo `auto` ya resuelve correctamente
en Nvidia sin que toques nada.

`ELECTRON_OZONE_PLATFORM_HINT=auto` **ya lo declara end-4**. No lo dupliques.

Opcionales, si quieres VA-API: `LIBVA_DRIVER_NAME=nvidia` y
`__GLX_VENDOR_LIBRARY_NAME=nvidia`.

### Un fallo que vigilar

Hay una discusión abierta ([#14843](https://github.com/hyprwm/Hyprland/discussions/14843))
sobre **pantalla negra en juegos a pantalla completa** que **menciona la RTX 4060
por su nombre**. El mecanismo es el direct scanout.

**Buena noticia: no te va a pasar de salida.** Lo comprobé en el código de end-4
— pone `vrr = 0` y no toca `direct_scanout`, así que se queda en el default de
upstream, que es `0`. Ambas perillas apagadas.

Si algún día las activas y ves frames negros, prueba en este orden:
`render.direct_scanout = 0` → `render.non_shader_cm = 0` →
`quirks.skip_non_kms_dmabuf_formats = 1`.

> Nota: el preset de Hyprland de **CachyOS** sí pone `direct_scanout = 2` y
> `vrr = 3`. No lo uses; tú vas con end-4.

---

## CPU: Ryzen 7 5800XT

La conclusión corta: **CachyOS ya lo configura bien de fábrica.** Casi todo lo
que sigue es verificación, no acción.

| Cosa | Estado por defecto |
|---|---|
| Repo optimizado | **`cachyos-v3`** — es el techo de Zen 3, no hay v4 (falta AVX-512) ni `znver3` |
| Kernel | `linux-cachyos` con **EEVDF** + Clang ThinLTO + AutoFDO |
| Escalado de frecuencia | **`amd-pstate-epp`**, governor `powersave` |
| Microcódigo | `amd-ucode`, auto-detectado por fabricante |
| Memoria | **32 GB de zram**, `swappiness=150`, sin swap en disco |
| `ananicy-cpp` | Habilitado |

### Verificación tras instalar

```bash
grep -E '^\[' /etc/pacman.conf                              # [cachyos-v3], sin v4
cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_driver      # amd-pstate-epp
cat /sys/devices/system/cpu/amd_pstate/status                # active
journalctl -k --grep='microcode:'                            # ≥ 0x0a201211
grep . /sys/devices/system/cpu/vulnerabilities/*             # "Mitigation:", no "Vulnerable"
zramctl && swapon --show                                     # zram0 ~32G
kerver                                                        # resumen de todo
```

**Si `scaling_driver` dice `acpi-cpufreq`, falta `_CPC`** → vuelve a la BIOS
(CPPC, x2APIC, multiplicador en Auto).

### Cosas normales que parecen fallos

- **`lscpu` no muestra `cppc`** — correcto en Vermeer, que usa CPPC por memoria
  compartida (ACPI `_CPC`), no por MSR.
- **`highest_perf` = 166 y no 255** — normal en Vermeer.

### Lo que sí puede aportar: sched-ext

Es lo único de esta sección con potencial de mejora perceptible, y es **opt-in**:

```bash
sudo pacman -S scx-scheds
scxctl start --sched lavd --mode gaming
```

Tu CPU es **un solo CCD con una L3 compartida**, así que los schedulers cuyo
argumento es el manejo entre CCDs (`scx_rusty`, `scx_p2dq`) tienen poco que
aportar aquí. Los candidatos razonables son **`scx_lavd`** (desarrollado para
Steam Deck) y **`scx_flash`**.

CachyOS no recomienda ninguno: *"no hay mejor consejo que probarlo tú mismo"*.

### Gaming

Usa **`game-performance %command%`** en las opciones de lanzamiento de Steam.
Cambia el perfil de energía y el scheduler mientras dura el juego. El wiki avisa
de que no aporta por debajo de 6C/12T — tu 8C/16T está por encima del umbral.

**No instales `gamemode`**: choca con `ananicy-cpp`, que sí viene habilitado.

### Lo que NO hacer

- No busques el repo `v4` ni `znver3`: el primero es imposible sin AVX-512, el
  segundo **no existe**.
- No uses `cachyos-rate-mirrors` esperando cambiar de tier — solo ordena mirrors.
- No pongas `amd_pstate.shared_mem=1`, está obsoleto.
- No fijes el kernel en la serie 6.12: tiene dos regresiones de preferred cores
  en Zen 3, una de ellas nunca retroportada.
- No uses `mitigations=off`. Si algún día necesitas rendimiento,
  `mitigations=auto,no_guest_host,no_guest_guest` conserva SRSO y TSA.

### Sobre el repo v3

CachyOS publicita "5–20% de mejora". Las mediciones independientes dan **1–3%
con regresiones puntuales** (bzip2 y Python salen *más lentos*). Ya viene puesto
y es gratis, así que déjalo — pero no esperes que cambie nada perceptible.

---

## Hibernación: la recomendación es no

Si quieres hibernar, tienes tres frentes abiertos a la vez:

1. **El early KMS de CachyOS la rompe.** El initramfs no accede a
   `NVreg_TemporaryFilePath`, así que no puede restaurar la VRAM. Habría que
   quitar los drop-ins de `chwd`, que están marcados "PLEASE DO NOT EDIT".
2. **Necesitas swap real ≥ 32 GB** más `resume=` y el hook `resume`.
3. **Con ESP compartida es problemática** — un motivo más para el esquema de dos
   ESP de arriba.

Suspender a RAM funciona sin nada de esto. Salvo que la hibernación te importe
mucho, sáltatela.

---

## El repositorio: qué hay que tocar

### Paquetes que sobran

`pkglist.txt` viene del portátil. Estos no sirven en el PC:

| Paquete | Motivo |
|---|---|
| `asusctl`, `rog-control-center` | Utilidades de portátil ASUS |
| `supergfxctl`, `switcheroo-control` | Conmutación de GPU híbrida |
| `nvidia-prime` | `prime-run` no aplica con una sola GPU |
| `intel-media-driver`, `vulkan-intel`, `lib32-vulkan-intel`, `intel-lpmd` | El 5800XT **no tiene gráficos integrados** |
| `intel-ucode` | CPU equivocada |
| `acpi_call` | Energía de portátil |
| `niri`, `xwayland-satellite` | Compositor anterior |

Ninguno rompe nada — el instalador ya habrá puesto `amd-ucode` por su cuenta.
Son unos MB de basura, no un fallo.

### Paquete que falta: `ddcutil`

En el portátil el brillo va por el backlight interno. **En el escritorio, el
slider de brillo del sidebar derecho solo funciona si tienes `ddcutil`** y el
monitor habla DDC/CI. Verificado en `services/Brightness.qml` de end-4, que
ejecuta `ddcutil detect --brief`.

```bash
sudo pacman -S ddcutil
sudo modprobe i2c-dev          # y añadirlo a /etc/modules-load.d/
sudo usermod -aG i2c $USER
ddcutil detect
```

### Configuración específica de máquina

**Las pantallas.** No se versionan a propósito: los nombres de output, escalas
y posiciones son de una máquina concreta. Es el mismo criterio que usabas con
el `machine.kdl` de niri, y por eso `monitors.lua` está en `.gitignore`.

En el PC lo generas con:
```bash
python3 install.py --solo-monitores
```

Lee las pantallas reales con `hyprctl monitors all -j` y pregunta modo, escala
y posición por cada una.

**La ruta del plugin.** `custom/general.lua` tiene
`/var/cache/hyprpm/marcrock/hyprland-scroll-overview/scrolloverview.so`. Si en el
PC usas otro nombre de usuario, ajústala.

**Ajustes que asumen batería** en `config.json` — inofensivos, pero sin sentido:
`battery.automaticSuspend`, `bar.utilButtons.showPerformanceProfileToggle`.

**`system/libinput/local-overrides.quirks`** es el apaño del touchpad. Inútil en
el PC, pero no molesta.

### El plugin del overview

No es un paquete de pacman:

```bash
hyprpm add https://github.com/yayuuu/hyprland-scroll-overview.git
hyprpm update && hyprpm enable scrolloverview
```

Y recuerda: **tras cada actualización de Hyprland hay que repetir `hyprpm
update`** o el plugin deja de cargar.

---

## Orden de ejecución

```
EN WINDOWS
  1. Backup de lo importante
  2. manage-bde -status C:  → guardar clave, desactivar cifrado
  3. Anotar la contraseña de la cuenta (no solo el PIN)
  4. Actualizar BIOS a AGESA ≥ 1.2.0.10
  5. chkdsk C: /f  y reiniciar
  6. Reducir partición, desactivar Inicio rápido, RealTimeIsUniversal=1
  7. Apagado completo

EN LA BIOS
  8. Secure Boot off, CSM off
  9. CPPC → Enabled (no Auto), Preferred Cores → Enabled
 10. Frecuencia de CPU en Auto

INSTALAR CACHYOS
 11. USB en modo UEFI (verificar con efibootmgr -v)
 12. Particionado MANUAL: ESP propia 8 GiB en /boot + btrfs en /
 13. Verificar que las 4 particiones de Windows quedan intactas
 14. Bootloader: limine

PRIMER ARRANQUE
 15. sudo limine-scan            → añadir Windows
 16. sudo limine-install --fallback
 17. Reiniciar y probar AMBAS rutas de arranque
 18. Verificar CPU (amd-pstate-epp, microcódigo, mitigaciones)

RESTAURAR EL SETUP
 19. bash <(curl -s https://ii.clsty.link/get)      ← end-4 primero
 20. git clone del repo de dotfiles
 21. Editar pkglist.txt quitando lo del portátil, añadir ddcutil
 22. sudo pacman -S --needed - < pkglist.txt
 23. python3 install.py
 24. hyprpm add/update/enable scrolloverview
 25. Ajustar hl.monitor() y la ruta del .so
 26. Comparar los parches de quickshell/ con diff ANTES de copiarlos
 27. nvidia-smi tras 10 min en idle → cientos de MB, no GB
```

---

## Donde la respuesta no es segura

Cosas que la investigación **no** pudo cerrar. Ninguna es bloqueante, pero
conviene saber que son terreno movedizo:

- **Si el instalador de CachyOS ejecuta `limine-scan` solo.** Las fuentes se
  contradicen. Trátalo como manual — es idempotente y no hace daño.
- **Dos ESP en un disco**: es estándar, pero hay firmware de MSI y algunas
  Gigabyte/ASUS con implementaciones UEFI defectuosas documentadas.
- **VRR en monitores no validados como G-SYNC Compatible**: no hay equivalente
  Wayland del toggle de `nvidia-settings`. Depende de tu panel y no hay perilla.
- **Gamescope en Nvidia**: la wiki de Hyprland lo recomienda, la ArchWiki dice
  que tiene "critical issues". Contradicción entre fuentes oficiales.
- **`GLVidHeapReuseRatio` 0 vs 1**: las wikis discrepan y nadie lo explica.
- **Si Reflex funciona bajo `winewayland`**: hay un reporte de que no. Si te
  importa, quédate en XWayland (sin `PROTON_ENABLE_WAYLAND=1`) hasta probarlo.
- **AMD-SB-7061** (agosto 2026): ataca Safe RET, que es la mitigación SRSO por
  defecto en Zen 3. **Sin fix disponible.** A vigilar.
