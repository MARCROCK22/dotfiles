# Mantenimiento

Este repo no es autónomo: va **encima** de [end-4/dots-hyprland](https://github.com/end-4/dots-hyprland)
y de un plugin de Hyprland. Los dos se actualizan por su cuenta, y hay tres
archivos suyos modificados a propósito.

Esto es lo que hay que hacer cuando alguno se actualiza.

---

## Los tres parches

Viven en `patches/` como **diffs**, no como copias del archivo entero.

| Parche | Archivo de end-4 | Qué cambia | Por qué |
|---|---|---|---|
| `BarContent.patch` | `modules/ii/bar/BarContent.qml` | Recursos y media a la izquierda, workspaces solos en el centro, reloj y batería a la derecha | Personalización propia |
| `StyledPopup.patch` | `modules/ii/bar/StyledPopup.qml` | Acota `margins.left` a los límites de la pantalla | **Bug de end-4**: centra el popup sobre el widget sin comprobar los bordes, así que cualquier widget cerca de un lado se recorta |
| `Background.patch` | `modules/ii/background/Background.qml` | `WlrLayer.Bottom` → `WlrLayer.Background` | **Bug del plugin scrolloverview**: solo dibuja el nivel `LAYER_BACKGROUND`, y end-4 pinta en `bottom`, así que el overview salía gris |

Los dos últimos son fallos ajenos, no gustos. Si algún día se arreglan aguas
arriba, esos parches se pueden borrar.

### Por qué diffs y no copias

Con una copia entera del archivo, cada actualización de end-4 obliga a elegir:
te quedas su versión y pierdes tu cambio, o te quedas la tuya y pierdes sus
arreglos. Con un diff, `patch` mete tu cambio **sobre** la versión nueva y te
quedas con las dos cosas. Y si el contexto cambió demasiado, falla diciendo qué
línea no cuadra, en vez de sobrescribir en silencio.

### La firma

Cada parche tiene un fragmento que **solo existe en la versión parcheada**:

| Archivo | Firma |
|---|---|
| `BarContent.qml` | `rightCenterGroupContent.implicitWidth` |
| `StyledPopup.qml` | `Math.max(0, Math.min` |
| `Background.qml` | `WlrLayer.Background` |

Sirve para saber en un `grep` si el parche sigue puesto, sin depender de que
`patch` adivine. `dotfiles-setup.sh` la comprueba en cada pasada.

---

## Después de actualizar end-4

```bash
cd ~/dotfiles
python3 install.py --sin-monitores --sin-sistema
```

Llega al paso de parches, comprueba las firmas y aplica los que falten. Para
cada uno hace `patch --dry-run` primero: si no aplicaría, no toca nada.

Salidas posibles:

**`ya aplicado (firma presente)`** — la actualización no tocó ese archivo.

**`aplicaría limpiamente`** — end-4 lo actualizó pero tu cambio sigue encajando.
Di que sí y listo.

**`el parche YA NO aplica limpiamente`** — end-4 reescribió esa zona. Toca a
mano:

```bash
cat patches/StyledPopup.patch                       # ver qué hacía
nano ~/.config/quickshell/ii/modules/ii/bar/StyledPopup.qml
```

Y después **regenerar el diff** (siguiente sección).

---

## Regenerar un parche

Hace falta cuando cambias tú el archivo, o cuando has tenido que reaplicar a
mano porque el parche dejó de encajar.

```bash
cd /tmp
# 1. La versión limpia de end-4, sin tus cambios
gh api "repos/end-4/dots-hyprland/contents/dots/.config/quickshell/ii/modules/ii/bar/StyledPopup.qml" \
   -H "Accept: application/vnd.github.raw" > original.qml

# 2. El diff contra la tuya
diff -u original.qml ~/.config/quickshell/ii/modules/ii/bar/StyledPopup.qml \
  | sed -e '1s|.*|--- a/modules/ii/bar/StyledPopup.qml|' \
        -e '2s|.*|+++ b/modules/ii/bar/StyledPopup.qml|' \
  > ~/dotfiles/patches/StyledPopup.patch

# 3. Comprobarlo antes de fiarte
cd ~/.config/quickshell/ii
patch -p1 --dry-run --reverse --input ~/dotfiles/patches/StyledPopup.patch
```

El `--reverse` del paso 3 comprueba que el parche **revierte** limpiamente lo
que tienes puesto, que es la forma de confirmar que el diff describe justo tu
cambio y nada más.

Las rutas del `sed` deben empezar por `a/` y `b/` desde
`~/.config/quickshell/ii`, porque `install.py` aplica con `patch -p1` desde ahí.

---

## Después de actualizar Hyprland

**El plugin del overview deja de cargar.** `hyprpm` compila contra la versión
exacta del compositor:

```bash
hyprpm update
```

Si no, `Super + O` no hace nada. Es lo primero que hay que mirar.

Y la ruta del `.so` en `custom/general.lua` lleva el usuario dentro
(`/var/cache/hyprpm/<usuario>/...`); `install.py` la comprueba y ofrece
corregirla si no existe.

---

## Después de cambiar configuración

```bash
cd ~/dotfiles
bash dotfiles-setup.sh
git show --stat HEAD        # mirar el diff ANTES de subir
git push
```

**Solo en la máquina origen.** Si ya ejecutaste `install.py` aquí, tus archivos
son enlaces al repo: el script lo detecta y aborta, porque se recogería sobre sí
mismo y dejaría el repo vacío. En esa máquina basta con:

```bash
cd ~/dotfiles && git add -A && git status && git commit
```

---

## Lo que NO se versiona, y por qué

| Archivo | Motivo |
|---|---|
| `~/.config/hypr/monitors.lua` | Nombres de output, escalas y posiciones son de una máquina. Lo genera `install.py --solo-monitores`. Es el equivalente del `machine.kdl` de niri |
| `~/.config/hypr/hyprland/` y `hyprland.lua` | Son de end-4, los sobrescribe su instalador. Lo tuyo va entero en `custom/` |
| `hyprlock.conf` | De end-4, sin tocar. La pantalla de bloqueo la dibuja Quickshell (`lock.useHyprlock: false`) |
| `fish_variables` | Lo genera fish solo y cambia constantemente |
| Configuración de VS Code | El repo es público |

---

## Cuando algo va mal

Todos los scripts respaldan antes de tocar, con marca de tiempo:

```bash
find ~/.config ~/dotfiles -name '*.bak-*' -newermt '-1 day'
```

Y los archivos de sistema, con `sudo`:

```bash
sudo find /etc -name '*.bak-*' -newermt '-1 day'
```
