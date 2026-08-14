# Mantenimiento

Este repo no es autónomo: va **encima** de [end-4/dots-hyprland](https://github.com/end-4/dots-hyprland)
y de un plugin de Hyprland. Los dos se actualizan por su cuenta. De end-4 hay
**4 archivos pisados a propósito**, y encima se añaden **10 propios**.

Esto es lo que hay que hacer cuando alguno se actualiza.

---

## Los 14 archivos de la shell

Desde **v15 no hay parches**. `quickshell/` guarda los archivos **enteros**,
más un `MANIFEST` con el sha256 de cada uno y un `VERSION` con el commit de
end-4 contra el que se recogieron.

**4 marcados `reemplazo`** — existen en end-4 y los pisamos:

| Archivo | Qué cambia | Por qué |
|---|---|---|
| `modules/ii/bar/BarContent.qml` | La disposición entera de la barra | Personalización. **Lo escribe `select_design.py`**, no se edita a mano |
| `modules/common/Config.qml` | Declara las claves de los 10 widgets nuevos | `Config.options` es un `JsonAdapter` de propiedades estáticas: sin declarar, la clave vale `undefined` para siempre |
| `modules/ii/bar/StyledPopup.qml` | Acota `margins.left` a la pantalla | **Bug de end-4**: centra el popup sin comprobar los bordes, así que un widget cerca de un lado se recorta |
| `modules/ii/background/Background.qml` | `WlrLayer.Bottom` → `WlrLayer.Background` | **Bug del plugin scrolloverview**: solo dibuja `LAYER_BACKGROUND` y end-4 pinta en `bottom`, así que el overview salía gris |

**10 marcados `nuevo`** — no existen en end-4, no pueden destruir nada suyo:
los 8 widgets (`AlertLine`, `GpuWidget`, `Pulse`, `QuickControls`, `SpaceNav`,
`SysReadouts`, `TapeMinimap`, `WindowShelf`) y 2 componentes de diseño
(`IslandGroup`, `OgeeBackground`).

La lista está en el array **`ARCHIVOS_SHELL`** de `dotfiles-setup.sh`, catorce
líneas explícitas. **Si añades un widget, añádelo ahí.**

### `select_design.py` NO está en el repo, y tampoco hace falta

Son 460 KB que llevan **embebidos** los mismos 14 `.qml` que el repo ya guarda
sueltos: dos copias de lo mismo, garantizadas a separarse. Está en
`.gitignore` para que no vuelva a entrar por descuido.

Primero intenté que `dotfiles-setup.sh` le pidiera la lista, para no tener dos
sitios donde mantenerla. Salió mal en la primera ejecución real: la copia de la
máquina era anterior a la bandera `--archivos`, `argparse` devolvió `rc=2` y la
shell **no se recogió**. Catorce líneas no justifican que recoger dependa de un
archivo que vive fuera del repo.

Ahora si hay un `select_design.py` a mano se usa solo para **contrastar** las
dos listas y avisar si han divergido. **Nunca bloquea**: si falta, o es viejo,
lo dice y sigue.

### El precio de no usar parches, dicho claro

Un diff que ya no encaja **falla a gritos**. Un reemplazo **pisa en silencio**.
Si end-4 arregla un bug en `BarContent.qml` y tú copias el tuyo encima, su
arreglo desaparece sin avisar.

Lo que lo compensa es el `MANIFEST`: `install.py` compara el sha256 de lo que
tienes instalado contra el del repo, y **solo hay tres desenlaces**:

- **coinciden** → ya está puesto, no toca nada;
- **el archivo no existe y es `nuevo`** → lo copia sin preguntar;
- **difieren** → enseña el diff y **pregunta**, con la respuesta por defecto
  en **no**.

Ese tercer caso es la señal de que end-4 cambió el archivo, o de que lo
editaste tú. Las dos merecen que pares a mirar.

---

## Después de actualizar end-4

**En la máquina ORIGEN** (la que recoge, donde nunca corriste `install.py`):

```bash
cd ~/dotfiles
python3 install.py --solo-shell
```

`--solo-shell` existe precisamente para esto. **No uses `install.py` a secas
aquí**: pasa por `stow`, que convierte tus archivos en enlaces al repo, y a
partir de ese momento `dotfiles-setup.sh` aborta por su guarda y te quedas sin
máquina desde la que recoger.

**En una máquina destino** (ya desplegada con `install.py`):

```bash
cd ~/dotfiles && git pull
python3 install.py --sin-monitores --sin-sistema
```

En los dos casos compara los 14. Salidas posibles:

**`N al dia`** — coinciden con el repo. La actualización no los tocó.

**`lo instalado NO es lo del repo`** — end-4 reescribió ese archivo. Mira el
diff que sale justo debajo antes de responder:

- Si su cambio no te importa → **sí**, tu versión gana.
- Si su cambio te interesa → **no**, y lo integras a mano en tu archivo.
  Después vuelve a recoger con `dotfiles-setup.sh`.

Para `BarContent.qml` hay un atajo: no lo edites a mano. Vuelve a aplicar tu
diseño con `python3 select_design.py <n>` y recoge.

**Revisa siempre los 4 `reemplazo`** tras actualizar end-4. Los 10 `nuevo` no
necesitan revisión: upstream no tiene nada que perder ahí.

---

## Fijar la versión de end-4

`./setup` de end-4 **no tiene bandera de versión** — sus subcomandos son
`install|uninstall|exp-update|exp-merge|resetfirstrun|checkdeps|virtmon`.
Fijarla significa elegir el commit antes de instalar:

```bash
git clone https://github.com/end-4/dots-hyprland
cd dots-hyprland
git checkout <commit-de-quickshell/VERSION>
./setup install
```

`quickshell/VERSION` dice contra cuál se recogieron los 14 archivos. Si
end-4 se instaló con el `curl` de una línea no queda checkout git y el commit
sale como `desconocido`; el `MANIFEST` sigue funcionando igual, porque compara
hashes y no versiones.

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

**Con una excepción importante: los 14 archivos de `quickshell/`.** No van por
stow — son **copias** en `~/.config/quickshell/ii`, no enlaces. Así que en una
máquina desplegada `git add -A` **no ve nada** de lo que cambies ahí, ni
siquiera si aplicas otro diseño con `select_design.py`.

Consecuencia práctica: **la shell solo se recoge en la máquina origen**. En las
demás se despliega (`install.py --solo-shell`) y punto. Si cambias el diseño en
una máquina desplegada y lo quieres versionar, cópialo a mano al repo:

```bash
cp ~/.config/quickshell/ii/modules/ii/bar/BarContent.qml \
   ~/dotfiles/quickshell/modules/ii/bar/BarContent.qml
sha256sum ~/dotfiles/quickshell/modules/ii/bar/BarContent.qml   # y actualiza MANIFEST
```

Es incómodo a propósito: si las dos máquinas recogieran, el repo dejaría de
tener una única fuente de verdad.

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
