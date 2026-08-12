#!/usr/bin/env python3
"""
install.py — despliega estos dotfiles en una maquina.

Sustituye al antiguo install.sh. La razon del cambio: configurar los monitores
necesita leer JSON, preguntar y generar Lua, y eso en bash es un suplicio.

Que hace:
  1. Enlaza la configuracion de usuario con stow
  2. Instala los archivos de /etc y /usr/share (con sudo)
  3. Copia el wallpaper
  4. Genera ~/.config/hypr/monitors.lua a partir de tus pantallas reales
  5. Te guia por los parches de end-4 SIN aplicarlos a ciegas
  6. Comprueba el plugin del overview y su ruta

Todo lo que sobrescribe o borra, lo respalda antes con marca de tiempo.

Uso:
    python3 install.py                 # interactivo
    python3 install.py --solo-monitores
    python3 install.py --sin-monitores
    python3 install.py --sin-sistema   # no toca /etc ni /usr/share
    python3 install.py --si            # asume "si" (necesario sin terminal)
"""

import argparse
import json
import os
import shutil
import subprocess
import sys
import time
from pathlib import Path

AQUI = Path(__file__).resolve().parent
HOME = Path.home()
SELLO = time.strftime("%Y%m%d-%H%M%S")

# --si: unica forma de que un paso destructivo siga adelante sin terminal.
AUTO_SI = False

# Paquetes de stow. quickshell/ NO va aqui: sus archivos sobrescriben los de
# end-4 y se tratan aparte, con diff de por medio.
STOW = ["hypr", "illogical-impulse", "alacritty", "bin",
        "spicetify", "fish", "fastfetch", "starship"]

PARCHES = [
    ("modules/ii/bar/BarContent.qml",
     "disposicion de la barra: recursos izq, workspaces centro, reloj der"),
    ("modules/ii/bar/StyledPopup.qml",
     "bug de end-4: popups recortados cerca de un borde"),
    ("modules/ii/background/Background.qml",
     "bug de scrolloverview: WlrLayer.Bottom -> Background"),
]

SISTEMA = [
    ("system/nvidia/50-limit-free-buffer-pool-in-wayland-compositors.json",
     "/etc/nvidia/nvidia-application-profiles-rc.d/50-limit-free-buffer-pool-in-wayland-compositors.json",
     "perfil de VRAM de Nvidia"),
    ("system/sddm/theme.conf",
     "/etc/sddm.conf.d/theme.conf",
     "tema de SDDM"),
    ("system/libinput/local-overrides.quirks",
     "/etc/libinput/local-overrides.quirks",
     "quirks de libinput (touchpad — inutil en escritorio)"),
]


# ---------------------------------------------------------------- salida ----
def say(m):
    print("\n\033[1;35m==>\033[0m \033[1m%s\033[0m" % m)


def ok(m):
    print("    \033[1;32m/\033[0m %s" % m)


def warn(m):
    print("    \033[1;33m!\033[0m %s" % m)


def err(m):
    print("    \033[1;31mx\033[0m %s" % m)


def aborta(motivo):
    print()
    err(motivo)
    sys.exit(1)


def pregunta(texto, defecto=True, destructivo=False):
    """Si/no.

    Ctrl+C aborta el script entero: es lo que significa Ctrl+C en cualquier
    otro sitio, y antes aqui valia por "si" en los prompts que borran cosas.

    Sin terminal, un paso destructivo NO se asume: requiere --si explicito.
    """
    if not sys.stdin.isatty():
        if destructivo and not AUTO_SI:
            warn("sin terminal y sin --si: se responde NO a «%s»" % texto)
            return False
        return defecto

    sufijo = "[S/n]" if defecto else "[s/N]"
    try:
        r = input("    %s %s " % (texto, sufijo)).strip().lower()
    except KeyboardInterrupt:
        aborta("cancelado por el usuario")
    except EOFError:
        aborta("entrada cerrada; nada que hacer")
    return defecto if not r else (r[0] in "sy")


def elige(texto, opciones, defecto=0):
    """Menu numerado. Devuelve el indice elegido."""
    if not sys.stdin.isatty():
        return defecto
    for i, o in enumerate(opciones):
        marca = " (por defecto)" if i == defecto else ""
        print("      %d) %s%s" % (i + 1, o, marca))
    while True:
        try:
            r = input("    %s [1-%d] " % (texto, len(opciones))).strip()
        except KeyboardInterrupt:
            aborta("cancelado por el usuario")
        except EOFError:
            return defecto
        if not r:
            return defecto
        if r.isdecimal() and 1 <= int(r) <= len(opciones):
            return int(r) - 1
        print("      valor no valido")


def corre(cmd, timeout=60, **kw):
    """Ejecuta y devuelve (rc, stdout, stderr) por separado.

    Antes concatenaba ambos flujos, y cualquier aviso de hyprctl en stderr
    corrompia el JSON que se intentaba parsear.
    """
    try:
        r = subprocess.run(cmd, capture_output=True, text=True,
                           timeout=timeout, **kw)
        return r.returncode, r.stdout.strip(), r.stderr.strip()
    except FileNotFoundError:
        return 127, "", "no existe el comando: %s" % cmd[0]
    except subprocess.TimeoutExpired:
        return 124, "", "se agoto el tiempo de espera"
    except Exception as e:  # noqa: BLE001 — nunca debe tumbar el script
        return 1, "", str(e)


def respalda(p: Path):
    """Copia con marca de tiempo. Devuelve la ruta, o None si no habia nada.

    Devuelve None tambien si falla; el llamante decide si eso es aceptable.
    """
    try:
        if not p.is_file():
            return None
        copia = p.with_name("%s.bak-%s" % (p.name, SELLO))
        shutil.copy2(p, copia)
        return copia
    except OSError as e:
        warn("no pude respaldar %s: %s" % (p, e))
        return None


def respalda_root(destino: str):
    """Respaldo de un archivo de /etc, que necesita sudo para escribir al lado."""
    d = Path(destino)
    rc, _, _ = corre(["sudo", "test", "-f", destino])
    if rc != 0:
        return None
    copia = "%s.bak-%s" % (destino, SELLO)
    rc, _, salida = corre(["sudo", "cp", "-a", destino, copia])
    if rc != 0:
        warn("no pude respaldar %s: %s" % (destino, salida))
        return None
    return copia


# ------------------------------------------------------------- monitores ----
def lee_monitores():
    """Lista de monitores segun hyprctl, o None con el motivo del fallo.

    Se usa 'monitors all' a proposito: sin 'all', Hyprland NO lista los
    monitores desactivados (verificado en src/ipc/s1/Commands.cpp), y al
    regenerar se perderia su configuracion.
    """
    if not shutil.which("hyprctl"):
        return None, "no existe el comando hyprctl"
    rc, salida, error = corre(["hyprctl", "monitors", "all", "-j"])
    if rc != 0:
        return None, "hyprctl fallo (rc=%d): %s" % (rc, error or "sin detalle")
    try:
        datos = json.loads(salida)
    except json.JSONDecodeError as e:
        return None, "hyprctl no devolvio JSON valido: %s" % e
    if not isinstance(datos, list):
        return None, "hyprctl devolvio algo que no es una lista"
    return datos, None


def modo_desde_monitor(m):
    """Cadena 'AnchoxAlto@Refresco' del estado actual.

    Nombres de campo verificados contra src/ipc/s1/Commands.cpp de Hyprland:
    width, height, refreshRate (float), x, y, scale, transform, disabled.
    """
    w = m.get("width")
    h = m.get("height")
    rr = m.get("refreshRate")
    if not w or not h:
        return None
    if rr is None:
        return "%dx%d" % (w, h)
    # 2 decimales es el formato que usa el propio availableModes de Hyprland.
    return "%dx%d@%.2f" % (w, h, float(rr))


def formatea_escala(valor):
    """Escala como la escribe Hyprland: entera si lo es, si no con 6 decimales.

    Hyprland exige que ancho/escala de un entero. Un valor con 17 decimales
    salido de un float de JSON no cuadra nunca; se recorta y se avisa.
    """
    try:
        f = float(valor)
    except (TypeError, ValueError):
        return "1", False
    if abs(f - round(f)) < 1e-9:
        return str(int(round(f))), False
    return ("%.6f" % f).rstrip("0").rstrip("."), True


def genera_monitors_lua(monitores):
    """Pregunta por cada pantalla y devuelve el texto de monitors.lua."""
    lineas = [
        "-- monitors.lua — generado por install.py el %s" % SELLO,
        "--",
        "-- hyprland.lua de end-4 carga este archivo DESPUES de custom/, asi que",
        "-- lo que pongas aqui gana. hl.monitor() es acumulativo: una llamada",
        "-- por pantalla.",
        "--",
        "-- Para regenerarlo:  python3 install.py --solo-monitores",
        "",
    ]

    for m in monitores:
        nombre = m.get("name")
        if not nombre:
            continue
        desc = (m.get("description") or "").strip()
        activo = modo_desde_monitor(m)
        disponibles = m.get("availableModes") or []
        escala_cruda = m.get("scale", 1)
        x, y = m.get("x", 0), m.get("y", 0)
        transform = m.get("transform", 0)

        print()
        say("Pantalla %s" % nombre)
        if desc:
            print("    %s" % desc)

        # Las desactivadas se conservan como tales: si no se emitieran,
        # volverian a encenderse al recargar.
        if m.get("disabled"):
            warn("esta desactivada — se conserva desactivada")
            lineas.append('hl.monitor({ output = "%s", disabled = true })' % nombre)
            lineas.append("")
            continue

        print("    actual: %s  escala %s  posicion %dx%d  transform %s"
              % (activo, escala_cruda, x, y, transform))

        # --- modo ---
        opciones = []
        if activo:
            opciones.append("mantener el actual (%s)" % activo)
        opciones += ["preferred (lo que diga el monitor)",
                     "highrr (maximo refresco)",
                     "highres (maxima resolucion)"]
        extra = [s.replace("Hz", "") for s in disponibles[:6]]
        extra = [e for e in extra if e != activo]
        opciones += ["modo del driver: %s" % e for e in extra]

        i = elige("Modo para %s" % nombre, opciones, 0)
        if i == 0 and activo:
            modo = activo
        elif opciones[i].startswith("preferred"):
            modo = "preferred"
        elif opciones[i].startswith("highrr"):
            modo = "highrr"
        elif opciones[i].startswith("highres"):
            modo = "highres"
        else:
            modo = opciones[i].split(": ", 1)[1]

        # --- escala ---
        actual_txt, fraccional = formatea_escala(escala_cruda)
        if fraccional:
            warn("escala fraccional (%s): Hyprland exige que ancho/escala sea"
                 % actual_txt)
            warn("entero, o la rechaza y vuelve a 1. Compruebalo tras recargar.")
        print()
        esc_op = ["mantener (%s)" % actual_txt, "1 (sin escalar)", "1.25", "1.5", "2"]
        j = elige("Escala para %s" % nombre, esc_op, 0)
        escala = actual_txt if j == 0 else esc_op[j].split()[0]

        # --- posicion ---
        print()
        pos_op = ["mantener (%dx%d)" % (x, y), "auto", "auto-right", "auto-left", "0x0"]
        k = elige("Posicion de %s" % nombre, pos_op, 0)
        posicion = "%dx%d" % (x, y) if k == 0 else pos_op[k]

        lineas.append('hl.monitor({')
        lineas.append('  output   = "%s",' % nombre)
        lineas.append('  mode     = "%s",' % modo)
        lineas.append('  position = "%s",' % posicion)
        lineas.append('  scale    = %s,' % escala)
        # transform solo si no es la orientacion normal: no ensuciar el archivo.
        if transform:
            lineas.append('  transform = %d,' % int(transform))
        lineas.append('})')
        lineas.append("")

    return "\n".join(lineas)


def avisa_monitor_duplicado():
    """custom/ y monitors.lua compitiendo por lo mismo es una fuente de lios."""
    custom = HOME / ".config/hypr/custom"
    if not custom.is_dir():
        return
    for f in sorted(custom.glob("*.lua")):
        try:
            texto = f.read_text(encoding="utf-8", errors="replace")
        except OSError:
            continue
        for linea in texto.split("\n"):
            s = linea.strip()
            if s.startswith("--"):
                continue
            if "hl.monitor(" in s:
                warn("ya hay un hl.monitor() en custom/%s" % f.name)
                warn("monitors.lua se carga despues y lo pisara: quita uno de los dos")
                return


def configura_monitores():
    say("Monitores")

    monitores, motivo = lee_monitores()
    if monitores is None:
        warn(motivo)
        print("        Si no estas en una sesion de Hyprland, ejecuta despues:")
        print("        python3 install.py --solo-monitores")
        return False
    if not monitores:
        warn("hyprctl no devolvio ninguna pantalla")
        return False

    ok("%d pantalla(s): %s" %
       (len(monitores), ", ".join(m.get("name", "?") for m in monitores)))
    avisa_monitor_duplicado()

    destino = HOME / ".config/hypr/monitors.lua"

    # monitors.lua NO se versiona (va en .gitignore, como el machine.kdl de
    # niri): es especifico de esta maquina. Si aparece como enlace al repo es
    # que viene de una version antigua, y hay que deshacerlo o escribiriamos
    # las pantallas de la otra maquina dentro de git.
    if destino.is_symlink():
        warn("monitors.lua es un enlace al repo (%s)" % os.readlink(destino))
        warn("ya no se versiona: es específico de cada máquina")
        if not pregunta("¿Convertirlo en archivo local de esta máquina?", True,
                        destructivo=True):
            ok("se conserva el enlace")
            return False
        try:
            destino.unlink()
            ok("enlace deshecho; se generará un archivo local")
        except OSError as e:
            err("no pude quitarlo: %s" % e)
            return False

    elif destino.is_file():
        print()
        print("    Ya existe %s" % destino)
        try:
            for l in destino.read_text(encoding="utf-8", errors="replace").split("\n")[:12]:
                print("      | %s" % l)
        except OSError as e:
            warn("no pude leerlo: %s" % e)
        if not pregunta("¿Reemplazarlo?", False, destructivo=True):
            ok("se conserva el existente")
            return False

    texto = genera_monitors_lua(monitores)

    print()
    say("Esto es lo que se va a escribir")
    for l in texto.split("\n"):
        print("    | %s" % l)

    if not pregunta("¿Escribirlo?", True, destructivo=True):
        warn("cancelado")
        return False

    copia = respalda(destino)
    if copia:
        ok("respaldo en %s" % copia)
    try:
        destino.parent.mkdir(parents=True, exist_ok=True)
        destino.write_text(texto, encoding="utf-8")
    except OSError as e:
        err("no pude escribir %s: %s" % (destino, e))
        return False
    ok("escrito %s" % destino)

    if pregunta("¿Recargar Hyprland ahora?", True):
        rc, _, error = corre(["hyprctl", "reload"])
        if rc != 0:
            warn(error)
        else:
            ok("hyprctl reload")
            # reload devuelve 0 aunque el Lua tenga errores; hay que preguntar.
            rc, salida, _ = corre(["hyprctl", "configerrors"])
            if rc == 0 and salida and "no errors" not in salida.lower():
                err("Hyprland reporta errores de configuracion:")
                for l in salida.split("\n")[:6]:
                    print("        %s" % l)
                if copia:
                    print("        Volver atras:  cp %s %s" % (copia, destino))
            elif rc == 0:
                ok("sin errores de configuracion")
    return True


# --------------------------------------------------------------- parches ----
def revisa_parches():
    say("Parches de end-4")

    base = HOME / ".config/quickshell/ii"
    if not base.is_dir():
        warn("no existe %s — ¿instalaste end-4 antes?" % base)
        print("        bash <(curl -s https://ii.clsty.link/get)")
        return

    print("    Estos archivos SOBRESCRIBEN los de end-4. No se copian solos:")
    print("    si tu version de end-4 no es la misma con la que se generaron,")
    print("    te romperian la barra.\n")

    for rel, desc in PARCHES:
        origen = AQUI / "quickshell/.config/quickshell/ii" / rel
        actual = base / rel

        if not origen.is_file():
            warn("%s — no esta en el repo" % rel)
            continue
        if not actual.is_file():
            warn("%s — no existe en tu sistema" % rel)
            continue

        try:
            iguales = origen.read_bytes() == actual.read_bytes()
        except OSError as e:
            warn("%s — no pude leerlo: %s" % (rel, e))
            continue

        print("    %s" % rel)
        print("      %s" % desc)

        if iguales:
            ok("ya aplicado (identicos)")
            continue

        rc, salida, _ = corre(["diff", "-u", str(actual), str(origen)])
        if rc == 127:
            warn("no hay 'diff' instalado; no puedo comparar")
        else:
            cambios = [l for l in salida.split("\n")
                       if l[:1] in "+-" and not l.startswith(("+++", "---"))]
            print("      difieren en %d linea(s)" % len(cambios))
        print("      ver:  diff -u %s %s" % (actual, origen))

        if salida and pregunta("      ¿Ver el diff completo?", False):
            print(salida)

        if pregunta("      ¿Aplicar este parche?", False, destructivo=True):
            copia = respalda(actual)
            try:
                shutil.copy2(origen, actual)
            except OSError as e:
                err("no pude copiarlo: %s" % e)
                continue
            ok("aplicado (respaldo en %s)" % copia)
        else:
            warn("omitido")


# ---------------------------------------------------------------- plugin ----
def _ruta_plugin(texto):
    """Extrae la ruta del hl.plugin.load(), ignorando lineas comentadas."""
    for n, linea in enumerate(texto.split("\n")):
        s = linea.strip()
        if s.startswith("--"):
            continue
        if "hl.plugin.load(" in s and '"' in s:
            partes = s.split('"')
            if len(partes) >= 2:
                return n, partes[1]
    return None, None


def revisa_plugin():
    say("Plugin del overview")

    general = HOME / ".config/hypr/custom/general.lua"
    if not general.is_file():
        warn("no existe custom/general.lua")
        return

    try:
        texto = general.read_text(encoding="utf-8")
    except OSError as e:
        warn("no pude leerlo: %s" % e)
        return

    n, ruta = _ruta_plugin(texto)
    if ruta is None:
        warn("custom/general.lua no carga el plugin (sin contar comentarios)")
        print("        hyprpm add https://github.com/yayuuu/hyprland-scroll-overview.git")
        print("        hyprpm update && hyprpm enable scrolloverview")
        return

    if Path(ruta).is_file():
        ok("el .so existe: %s" % ruta)
        return

    err("la ruta del plugin no existe:")
    print("        %s  (linea %d)" % (ruta, n + 1))

    usuario = os.environ.get("USER") or HOME.name
    base = Path("/var/cache/hyprpm") / usuario
    try:
        encontrados = sorted(base.rglob("scrolloverview.so")) if base.is_dir() else []
    except OSError:
        encontrados = []

    if not encontrados:
        print("        No encuentro scrolloverview.so bajo %s" % base)
        print("        hyprpm add ... && hyprpm update && hyprpm enable scrolloverview")
        return

    if len(encontrados) > 1:
        warn("hay %d builds; elige cual (una compilada contra otra version de"
             % len(encontrados))
        warn("Hyprland no cargara, y el sintoma es un overview que no abre)")
        i = elige("¿Cual?", [str(p) for p in encontrados], 0)
    else:
        i = 0
    nueva = str(encontrados[i])
    print("        Candidata: %s" % nueva)

    if general.is_symlink():
        warn("general.lua es un enlace al repo: el cambio entra en git")

    # Por defecto NO: la ruta lleva el usuario dentro y es especifica de esta
    # maquina, asi que corregirla ensucia el repo compartido.
    if not pregunta("¿Corregir la ruta?", False, destructivo=True):
        warn("sin corregir")
        return

    copia = respalda(general)
    lineas = texto.split("\n")
    lineas[n] = lineas[n].replace(ruta, nueva)      # solo esa linea
    try:
        general.write_text("\n".join(lineas), encoding="utf-8")
    except OSError as e:
        err("no pude escribir: %s" % e)
        return
    ok("corregida (respaldo en %s)" % copia)


# ------------------------------------------------------------------ main ----
def conflictos_stow(paquetes, destino_stow: Path):
    """Archivos que stow no podra enlazar porque ya existen como archivo real.

    Es el caso normal, no una excepcion: el instalador de end-4 crea
    ~/.config/hypr/custom/*.lua vacios, y stow se niega a pisarlos.

    NO se resuelve con 'stow --adopt'. El manual dice que --adopt mueve el
    archivo del destino DENTRO del paquete, asi que el keybinds.lua vacio de
    end-4 sobrescribiria el tuyo en el repo. Es lo contrario de lo que quieres.
    """
    choques = []
    for p in paquetes:
        raiz = AQUI / p
        for origen in raiz.rglob("*"):
            if not origen.is_file():
                continue
            destino = destino_stow / origen.relative_to(raiz)
            if destino.is_symlink():
                continue          # ya lo gestiona stow (o apunta a otro sitio)
            if destino.is_file():
                choques.append((destino, origen))
            elif destino.exists():
                # Un directorio donde el repo trae un archivo: stow tampoco
                # puede, pero borrarlo seria destructivo. Se avisa y ya.
                warn("%s existe y no es un archivo; stow fallara ahi" % destino)
    return choques


def paso_stow():
    say("Enlazando con stow")
    if not shutil.which("stow"):
        err("falta stow:  sudo pacman -S stow")
        return False

    # stow usa por defecto el PADRE del directorio de paquetes como destino
    # ("Defaults to the parent of the stow directory", manual de GNU stow).
    # Si el repo no esta en $HOME, ese padre NO es $HOME: se borrarian los
    # archivos de $HOME y los enlaces irian a otro sitio, con exito aparente.
    # Se pasa -t explicito para que destino y comprobacion sean el mismo.
    destino_stow = HOME
    if AQUI.parent != HOME:
        warn("el repo esta en %s, no directamente en %s" % (AQUI, HOME))
        warn("se forzara el destino con -t %s" % HOME)

    faltan = [p for p in STOW if not (AQUI / p).is_dir()]
    if faltan:
        warn("no estan en el repo, se omiten: %s" % ", ".join(faltan))
    presentes = [p for p in STOW if (AQUI / p).is_dir()]
    if not presentes:
        err("ningun paquete de stow en %s — ¿es este el repo?" % AQUI)
        return False

    choques = conflictos_stow(presentes, destino_stow)
    if choques:
        print()
        warn("%d archivo(s) ya existen y no son enlaces:" % len(choques))
        for destino, origen in choques:
            nota = ""
            try:
                if destino.read_bytes() == origen.read_bytes():
                    nota = "  (identico al del repo)"
                elif destino.stat().st_size == 0:
                    nota = "  (vacio)"
            except OSError:
                pass
            print("        %s%s" % (destino, nota))

        print()
        print("    stow se niega a continuar mientras esten ahi. Lo normal es")
        print("    que sean los archivos por defecto que crea end-4.")
        print()
        print("    NO uses 'stow --adopt': moveria estos archivos DENTRO del")
        print("    repo, machacando tu configuracion con la version vacia.")
        print()

        if not pregunta("¿Respaldarlos y quitarlos para que stow pueda enlazar?",
                        True, destructivo=True):
            err("sin quitarlos, stow no puede continuar")
            return False

        apartados = []
        for destino, _ in choques:
            copia = respalda(destino)
            if copia is None:
                err("no pude respaldar %s — no lo borro" % destino)
                err("deshaz lo hecho si quieres reintentar: %s" %
                    ", ".join(str(c) for c in apartados) or "(nada aun)")
                return False
            try:
                destino.unlink()
            except OSError as e:
                err("no pude borrar %s: %s" % (destino, e))
                return False
            apartados.append(copia)
            print("        %s -> %s" % (destino.name, copia.name))
        ok("%d archivo(s) apartados" % len(apartados))

    rc, salida, error = corre(["stow", "-t", str(destino_stow), *presentes],
                              cwd=str(AQUI))
    if rc == 0:
        ok("enlazados en %s: %s" % (destino_stow, ", ".join(presentes)))
        print("        A partir de ahora esos archivos SON el repo: editarlos")
        print("        edita %s. Recuerda commitear." % AQUI)
        return True

    err("stow fallo (rc=%d):" % rc)
    print(salida or error)
    if choques:
        print("\n    Los archivos apartados siguen ahi como .bak-%s" % SELLO)
    return False


def paso_sistema():
    say("Archivos de sistema (pedira sudo)")
    hechos = 0
    for rel, destino, desc in SISTEMA:
        origen = AQUI / rel
        if not origen.is_file():
            continue

        # El perfil de Nvidia lleva DENTRO el nombre del proceso del compositor.
        # dotfiles-setup.sh ya avisa si sigue diciendo "niri" al recogerlo, pero
        # al desplegar se instalaba a ciegas -- y en un PC con Nvidia unica es
        # justo donde mas importa que este bien.
        if "nvidia" in rel:
            try:
                perfil = origen.read_text(encoding="utf-8", errors="replace")
            except OSError:
                perfil = ""
            if "hyprland" not in perfil.lower():
                err("el perfil de Nvidia no menciona Hyprland")
                print("        Lleva el nombre del proceso dentro; si dice 'niri',")
                print("        no se aplica a nada. Corrigelo con:")
                print("        python3 -c \"import json,pathlib;"
                      "p=pathlib.Path('%s');d=json.loads(p.read_text());"
                      "print(d['rules'])\"" % origen)
                if not pregunta("¿Instalarlo igualmente?", False, destructivo=True):
                    warn("omitido")
                    continue

        copia = respalda_root(destino)
        # timeout amplio: aqui es donde sudo puede pedir la contrasena.
        rc, _, error = corre(["sudo", "install", "-Dm644", str(origen), destino],
                             timeout=300)
        if rc == 0:
            ok("%s%s" % (desc, ("  (respaldo: %s)" % copia) if copia else ""))
            hechos += 1
        else:
            err("%s: %s" % (desc, error or "rc=%d" % rc))

    tema = AQUI / "system/sddm-theme"
    destino_tema = Path("/usr/share/sddm/themes/sddm-astronaut-theme")
    if tema.is_dir():
        if destino_tema.is_dir():
            fallos = 0
            meta = tema / "metadata.desktop"
            if meta.is_file():
                respalda_root(str(destino_tema / "metadata.desktop"))
                rc, _, e = corre(["sudo", "install", "-Dm644", str(meta),
                                  str(destino_tema / "metadata.desktop")], timeout=300)
                if rc != 0:
                    fallos += 1
                    err("metadata.desktop: %s" % e)
            for conf in sorted((tema / "Themes").glob("*.conf")):
                respalda_root(str(destino_tema / "Themes" / conf.name))
                rc, _, e = corre(["sudo", "install", "-Dm644", str(conf),
                                  str(destino_tema / "Themes" / conf.name)], timeout=300)
                if rc != 0:
                    fallos += 1
                    err("%s: %s" % (conf.name, e))
            if fallos == 0:
                ok("tema de SDDM personalizado")
                hechos += 1
            else:
                err("%d archivo(s) del tema fallaron" % fallos)
            warn("estos archivos son de pacman: un -Syu los repone o deja .pacnew")
        else:
            warn("falta el paquete sddm-astronaut-theme; instalalo antes")

    if not hechos:
        warn("nada instalado en el sistema")


def dir_imagenes():
    """Directorio XDG de imagenes. En español es ~/Imágenes, no ~/Pictures."""
    rc, salida, _ = corre(["xdg-user-dir", "PICTURES"])
    if rc == 0 and salida:
        p = Path(salida)
        if p != HOME:            # xdg-user-dir devuelve $HOME si no sabe
            return p
    for cand in ("Imágenes", "Pictures", "Imagenes"):
        if (HOME / cand).is_dir():
            return HOME / cand
    return HOME / "Pictures"


def paso_wallpaper():
    say("Wallpaper")
    origen = AQUI / "wallpaper"
    if not origen.is_dir():
        warn("no hay carpeta wallpaper/ en el repo")
        return
    fondos = sorted(f for f in origen.glob("*") if f.is_file())
    if not fondos:
        warn("wallpaper/ esta vacia")
        return

    destino = dir_imagenes() / "wallpapers"
    try:
        destino.mkdir(parents=True, exist_ok=True)
    except OSError as e:
        err("no pude crear %s: %s" % (destino, e))
        return

    copiados = []
    for f in fondos:
        final = destino / f.name
        if final.exists():
            copia = respalda(final)
            if copia:
                warn("%s ya existia (respaldo: %s)" % (f.name, copia.name))
        try:
            shutil.copy2(f, final)
            ok("%s -> %s" % (f.name, destino))
            copiados.append(final)
        except OSError as e:
            err("%s: %s" % (f.name, e))

    # config.json trae la ruta ABSOLUTA del fondo en la maquina anterior. Si
    # aqui no existe, el shell arranca sin fondo y SIN PALETA Material You, que
    # es de donde salen todos los colores. Nadie lo mencionaba.
    cfg = HOME / ".config/illogical-impulse/config.json"
    if cfg.is_file():
        try:
            datos = json.loads(cfg.read_text(encoding="utf-8"))
            ruta = (datos.get("background") or {}).get("wallpaperPath") or ""
        except (OSError, json.JSONDecodeError):
            ruta = ""
        if ruta and not Path(ruta).is_file():
            print()
            warn("config.json apunta a un fondo que aqui no existe:")
            print("        %s" % ruta)
            warn("sin el no se genera la paleta Material You: todo saldra gris")
            if copiados:
                print("        Lo tienes en: %s" % copiados[0])
            print("        Aplicalo con Ctrl+Super+T: el selector reescribe")
            print("        config.json por su cuenta y regenera los colores.")
            return
    print("        Aplicalo con Ctrl+Super+T para que se regenere la paleta.")


def main():
    global AUTO_SI

    ap = argparse.ArgumentParser(description="Despliega los dotfiles.")
    ap.add_argument("--solo-monitores", action="store_true",
                    help="solo genera ~/.config/hypr/monitors.lua")
    ap.add_argument("--sin-monitores", action="store_true",
                    help="salta la configuracion de monitores")
    ap.add_argument("--sin-sistema", action="store_true",
                    help="no toca /etc ni /usr/share")
    ap.add_argument("--si", action="store_true",
                    help="responde que si; necesario sin terminal")
    args = ap.parse_args()
    AUTO_SI = args.si

    if args.solo_monitores:
        configura_monitores()
        return

    print("\n\033[1mDotfiles — CachyOS + Hyprland + end-4\033[0m")
    print("Repo: %s" % AQUI)
    print("\nEste repo va ENCIMA de end-4. Si no lo tienes:")
    print("    bash <(curl -s https://ii.clsty.link/get)")
    print("\nPaquetes:")
    print("    sudo pacman -S --needed - < pkglist.txt")
    print("    (revisa antes: trae paquetes del portatil que en escritorio sobran)")

    # end-4 tiene que estar YA instalado: stow pliega directorios que no
    # existen, asi que sin el, ~/.config/hypr acabaria siendo un enlace al
    # repo entero y el instalador de end-4 escribiria dentro de git.
    if not (HOME / ".config/quickshell/ii").is_dir():
        err("no encuentro ~/.config/quickshell/ii")
        print("        Este repo va ENCIMA de end-4, no lo sustituye. Instalalo antes:")
        print("        bash <(curl -s https://ii.clsty.link/get)")
        if not pregunta("¿Seguir de todas formas?", False, destructivo=True):
            return

    if not pregunta("\n¿Continuar?", True, destructivo=True):
        return

    # sudo primero, con el prompt VISIBLE: mas abajo se llama a sudo desde
    # subprocess con capture_output, que se traga la peticion de contrasena y
    # deja la terminal aparentemente colgada hasta el timeout.
    if not args.sin_sistema and shutil.which("sudo"):
        say("Autenticación")
        print("    Se piden permisos ahora para no bloquear pasos posteriores.")
        try:
            subprocess.run(["sudo", "-v"], timeout=300)
        except Exception as e:  # noqa: BLE001
            warn("sudo -v falló (%s); los pasos de sistema pueden fallar" % e)

    if not paso_stow():
        # Sin los enlaces, lo demas trabaja sobre un ~/.config a medio montar.
        aborta("stow no termino bien; me paro aqui para no dejarlo peor. "
               "Revisa lo de arriba y los .bak-%s" % SELLO)

    if not args.sin_sistema:
        paso_sistema()
    paso_wallpaper()
    if not args.sin_monitores:
        configura_monitores()
    revisa_parches()
    revisa_plugin()

    say("Hecho")
    print("""
  Reinicia la sesion para que todo cargue:

      hyprctl dispatch exit

  Y despues:

      Ctrl + Super + R      recargar los widgets
      Super + /             chuleta de atajos

  Los respaldos de esta ejecucion llevan el sufijo  .bak-%s
""" % SELLO)


if __name__ == "__main__":
    main()
