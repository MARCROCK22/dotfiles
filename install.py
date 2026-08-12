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

Nada destructivo sin avisar. Todo lo que sobrescribe, lo respalda antes.

Uso:
    python3 install.py              # interactivo
    python3 install.py --solo-monitores
    python3 install.py --sin-monitores
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


def pregunta(texto, defecto=True):
    if not sys.stdin.isatty():
        return defecto
    sufijo = "[S/n]" if defecto else "[s/N]"
    try:
        r = input("    %s %s " % (texto, sufijo)).strip().lower()
    except (EOFError, KeyboardInterrupt):
        print()
        return defecto
    return defecto if not r else (r[0] in "sy")


def elige(texto, opciones, defecto=0):
    """Menu numerado. Devuelve el indice elegido."""
    for i, o in enumerate(opciones):
        marca = " (por defecto)" if i == defecto else ""
        print("      %d) %s%s" % (i + 1, o, marca))
    if not sys.stdin.isatty():
        return defecto
    while True:
        try:
            r = input("    %s [1-%d] " % (texto, len(opciones))).strip()
        except (EOFError, KeyboardInterrupt):
            print()
            return defecto
        if not r:
            return defecto
        if r.isdigit() and 1 <= int(r) <= len(opciones):
            return int(r) - 1
        print("      valor no valido")


def corre(cmd, **kw):
    """Ejecuta y devuelve (rc, salida). Nunca lanza."""
    try:
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=60, **kw)
        return r.returncode, (r.stdout + r.stderr).strip()
    except Exception as e:
        return 1, str(e)


def respalda(p: Path):
    if p.exists():
        copia = p.with_name("%s.bak-%s" % (p.name, SELLO))
        shutil.copy2(p, copia)
        return copia
    return None


# ------------------------------------------------------------- monitores ----
def lee_monitores():
    """Devuelve la lista de monitores de hyprctl, o None si no se puede."""
    if not shutil.which("hyprctl"):
        return None
    rc, salida = corre(["hyprctl", "monitors", "-j"])
    if rc != 0:
        return None
    try:
        datos = json.loads(salida)
    except json.JSONDecodeError:
        return None
    return datos if isinstance(datos, list) else None


def modo_desde_monitor(m):
    """Construye la cadena 'AnchoxAlto@Refresco' del estado actual.

    Los nombres de campo estan verificados contra src/ipc/s1/Commands.cpp de
    Hyprland: width, height, refreshRate (con 5 decimales), x, y, scale.
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
        nombre = m.get("name", "?")
        desc = m.get("description", "").strip()
        activo = modo_desde_monitor(m)
        disponibles = m.get("availableModes") or []
        escala_actual = m.get("scale", 1)
        x, y = m.get("x", 0), m.get("y", 0)

        print()
        say("Pantalla %s" % nombre)
        if desc:
            print("    %s" % desc)
        print("    actual: %s  escala %s  posicion %dx%d" % (activo, escala_actual, x, y))

        if m.get("disabled"):
            warn("esta desactivada; se omite")
            continue

        # --- modo ---
        opciones = []
        if activo:
            opciones.append("mantener el actual (%s)" % activo)
        opciones += ["preferred (lo que diga el monitor)",
                     "highrr (maximo refresco)",
                     "highres (maxima resolucion)"]
        # Los primeros modos de la lista del driver, sin repetir el actual.
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
        print()
        esc_op = ["mantener (%s)" % escala_actual, "1 (sin escalar)", "1.25", "1.5", "2"]
        j = elige("Escala para %s" % nombre, esc_op, 0)
        escala = escala_actual if j == 0 else esc_op[j].split()[0]

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
        lineas.append('})')
        lineas.append("")

    return "\n".join(lineas)


def configura_monitores():
    say("Monitores")

    monitores = lee_monitores()
    if monitores is None:
        warn("no pude leer 'hyprctl monitors -j'")
        print("        ¿Estas dentro de una sesion de Hyprland? Si no, ejecuta")
        print("        despues:  python3 install.py --solo-monitores")
        return False
    if not monitores:
        warn("hyprctl no devolvio ninguna pantalla")
        return False

    ok("%d pantalla(s) detectada(s): %s" %
       (len(monitores), ", ".join(m.get("name", "?") for m in monitores)))

    destino = HOME / ".config/hypr/monitors.lua"
    if destino.exists():
        print()
        print("    Ya existe %s:" % destino)
        for l in destino.read_text(encoding="utf-8").split("\n")[:12]:
            print("      | %s" % l)
        if not pregunta("¿Reemplazarlo?", False):
            ok("se conserva el existente")
            return False

    texto = genera_monitors_lua(monitores)

    print()
    say("Esto es lo que se va a escribir")
    for l in texto.split("\n"):
        print("    | %s" % l)

    if not pregunta("¿Escribirlo?", True):
        warn("cancelado")
        return False

    copia = respalda(destino)
    if copia:
        ok("respaldo en %s" % copia)
    destino.parent.mkdir(parents=True, exist_ok=True)
    destino.write_text(texto, encoding="utf-8")
    ok("escrito %s" % destino)

    if pregunta("¿Recargar Hyprland ahora?", True):
        rc, salida = corre(["hyprctl", "reload"])
        ok("hyprctl reload") if rc == 0 else warn(salida)
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

        iguales = origen.read_bytes() == actual.read_bytes()
        print("    %s" % rel)
        print("      %s" % desc)

        if iguales:
            ok("ya aplicado (identicos)")
            continue

        rc, salida = corre(["diff", "-u", str(actual), str(origen)])
        n = len([l for l in salida.split("\n") if l.startswith(("+", "-"))])
        print("      difieren en ~%d lineas" % n)
        print("      diff:  diff -u %s %s" % (actual, origen))

        if pregunta("      ¿Ver el diff completo?", False):
            print(salida)

        if pregunta("      ¿Aplicar este parche?", False):
            copia = respalda(actual)
            shutil.copy2(origen, actual)
            ok("aplicado (respaldo en %s)" % copia)
        else:
            warn("omitido")


# ---------------------------------------------------------------- plugin ----
def revisa_plugin():
    say("Plugin del overview")

    general = HOME / ".config/hypr/custom/general.lua"
    if not general.is_file():
        warn("no existe custom/general.lua")
        return

    texto = general.read_text(encoding="utf-8")
    if "hl.plugin.load(" not in texto:
        warn("custom/general.lua no carga el plugin")
        print("        hyprpm add https://github.com/yayuuu/hyprland-scroll-overview.git")
        print("        hyprpm update && hyprpm enable scrolloverview")
        return

    # La ruta lleva el nombre de usuario dentro: /var/cache/hyprpm/<usuario>/...
    ruta = None
    for l in texto.split("\n"):
        if "hl.plugin.load(" in l and '"' in l:
            ruta = l.split('"')[1]
            break

    if not ruta:
        warn("hay un hl.plugin.load() pero no pude extraer la ruta")
        return

    if Path(ruta).is_file():
        ok("el .so existe: %s" % ruta)
        return

    err("la ruta del plugin no existe:")
    print("        %s" % ruta)

    # Busca el real bajo /var/cache/hyprpm/<usuario>/
    usuario = os.environ.get("USER") or HOME.name
    base = Path("/var/cache/hyprpm") / usuario
    encontrados = sorted(base.rglob("scrolloverview.so")) if base.is_dir() else []

    if not encontrados:
        print("        No encuentro scrolloverview.so bajo %s" % base)
        print("        Instalalo:  hyprpm add ... && hyprpm update && hyprpm enable scrolloverview")
        return

    nueva = str(encontrados[0])
    print("        Encontrado en: %s" % nueva)
    if pregunta("¿Corregir la ruta en custom/general.lua?", True):
        copia = respalda(general)
        general.write_text(texto.replace(ruta, nueva), encoding="utf-8")
        ok("corregida (respaldo en %s)" % copia)


# ------------------------------------------------------------------ main ----
def paso_stow():
    say("Enlazando con stow")
    if not shutil.which("stow"):
        err("falta stow:  sudo pacman -S stow")
        return False
    faltan = [p for p in STOW if not (AQUI / p).is_dir()]
    if faltan:
        warn("no estan en el repo, se omiten: %s" % ", ".join(faltan))
    presentes = [p for p in STOW if (AQUI / p).is_dir()]
    rc, salida = corre(["stow", *presentes], cwd=str(AQUI))
    if rc == 0:
        ok("enlazados: %s" % ", ".join(presentes))
        return True
    err("stow fallo:")
    print(salida)
    print("\n    Suele ser que el archivo destino ya existe y no es un enlace.")
    print("    Muevelo o borralo y reintenta.")
    return False


def paso_sistema():
    say("Archivos de sistema (pedira sudo)")
    hechos = 0
    for rel, destino, desc in SISTEMA:
        origen = AQUI / rel
        if not origen.is_file():
            continue
        rc, salida = corre(["sudo", "install", "-Dm644", str(origen), destino])
        if rc == 0:
            ok(desc)
            hechos += 1
        else:
            err("%s: %s" % (desc, salida))

    tema = AQUI / "system/sddm-theme"
    destino_tema = Path("/usr/share/sddm/themes/sddm-astronaut-theme")
    if tema.is_dir():
        if destino_tema.is_dir():
            meta = tema / "metadata.desktop"
            if meta.is_file():
                corre(["sudo", "install", "-Dm644", str(meta), str(destino_tema / "metadata.desktop")])
            for conf in (tema / "Themes").glob("*.conf"):
                corre(["sudo", "install", "-Dm644", str(conf),
                       str(destino_tema / "Themes" / conf.name)])
            ok("tema de SDDM personalizado")
            hechos += 1
        else:
            warn("falta el paquete sddm-astronaut-theme; instalalo antes")

    if not hechos:
        warn("nada que instalar en el sistema")


def paso_wallpaper():
    say("Wallpaper")
    origen = AQUI / "wallpaper"
    fondos = sorted(origen.glob("*")) if origen.is_dir() else []
    if not fondos:
        warn("no hay wallpaper en el repo")
        return
    destino = HOME / "Pictures/wallpapers"
    destino.mkdir(parents=True, exist_ok=True)
    for f in fondos:
        shutil.copy2(f, destino / f.name)
        ok("%s -> %s" % (f.name, destino))
    print("        Aplicalo con Ctrl+Super+T para que se regenere la paleta.")


def main():
    ap = argparse.ArgumentParser(description="Despliega los dotfiles.")
    ap.add_argument("--solo-monitores", action="store_true",
                    help="solo genera ~/.config/hypr/monitors.lua")
    ap.add_argument("--sin-monitores", action="store_true",
                    help="salta la configuracion de monitores")
    args = ap.parse_args()

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

    if not pregunta("\n¿Continuar?", True):
        return

    paso_stow()
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
""")


if __name__ == "__main__":
    main()
