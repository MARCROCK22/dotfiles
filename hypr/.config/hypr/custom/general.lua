-- cargar-plugin.py ---------------------------------------------------------
-- Carga el plugin AQUI, durante el parseo, no en hyprland.start.
-- Si se carga despues, las claves plugin.scrolloverview.* aun no
-- existen cuando Hyprland lee los valores de mas abajo y los
-- descarta con "unknown config key".
hl.plugin.load("/var/cache/hyprpm/marcrock/hyprland-scroll-overview/scrolloverview.so")
-- fin -- cargar-plugin.py ------------------------------------------------

hl.config({
  general = {
    layout = "scrolling",
    border_size = 3,
    col = {
      active_border = "rgba(0DB7D4FF)",
    },
  },
  decoration = {
    dim_inactive = true,
    dim_strength = 0.25,
  }
})

hl.config({
  binds = {
    movefocus_cycles_fullscreen = true,
  },
})

hl.config({
  plugin = {
    scrolloverview = {
      gesture_distance = 300,
      scale = 0.5,
      workspace_gap = 100,
      layout = "vertical",
      wallpaper = 2,
      blur = true,
      shadow = { enabled = true, range = 50 },
    },
  },
})

hl.animation({
  leaf = "workspaces",
  enabled = true,
  speed = 7,
  bezier = "menu_decel",
  style = "slidevert"
})

-- Segunda distribución de teclado ---------------------------------------------
-- Estuvo puesta como `us,es` y se RETIRÓ el 2026-08-16 porque dejaba fuera: el
-- greeter de SDDM usa siempre `us` (/etc/vconsole.conf), así que con la otra
-- activa la contraseña la rechazaban la pantalla de bloqueo y sudo, que sí
-- corren dentro de la sesión. Sin forma de rotar desde el lock, el botón de la
-- barra era la única salida, y hasta ahí no se llega.
--
-- Vuelve el 2026-08-29, con esa salida puesta. `grp:win_space_toggle` es una
-- opción de XKB, NO un `hl.bind`, y la diferencia es justo el fallo anterior:
-- la rotación la resuelve el estado XKB del compositor antes de que la tecla
-- llegue a ningún cliente, así que sigue funcionando con hyprlock delante, que
-- captura el teclado y se comería un bind normal.
--
-- `us` va PRIMERA a propósito: es la que queda activa al arrancar la sesión, y
-- así coincide con lo que teclea el greeter.
--
-- `latam` y no `es` por el locale de la máquina (es_MX / es_DO). Entre las dos
-- cambian de sitio varios símbolos, no solo el nombre.
--
-- Si alguna vez vuelve a liarse, esto fuerza `us` sin depender del teclado ni
-- de la barra (vale desde una TTY con Ctrl+Alt+F2):
--     hyprctl switchxkblayout all 0
hl.config({
  input = {
    kb_layout = "us,latam",
    kb_options = "grp:win_space_toggle",
  },
})

-- Ratón sin aceleración --------------------------------------------------------
-- `flat` es relación 1:1 constante: la misma distancia de ratón mueve siempre el
-- mismo número de píxeles, vaya rápido o despacio.
--
-- Antes no había NADA configurado -accel_profile vacío, force_no_accel en false,
-- sensitivity en 0-, y con eso manda el defecto de libinput, que es `adaptive`,
-- o sea CON aceleración. Comprobado con `libinput list-devices`, que marcaba el
-- perfil activo con asterisco.
--
-- Efecto secundario esperado: al quitar la aceleración los movimientos rápidos
-- cubren menos distancia. Lo normal es compensarlo subiendo el DPI en el propio
-- ratón, no la sensibilidad de aquí.
hl.config({
  input = {
    accel_profile = "flat",
  },
})
