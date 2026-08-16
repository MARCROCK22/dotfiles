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

-- Segunda distribución de teclado: RETIRADA el 2026-08-16 --------------------
-- Estuvo aquí como `kb_layout = "us,es"` para que apareciera el
-- KeyboardLayoutButton de la barra. Provocó un bloqueo: el greeter de SDDM usa
-- siempre `us` (/etc/vconsole.conf), así que con `es` activo la contraseña
-- entraba en el login y la rechazaban la pantalla de bloqueo y sudo, que sí
-- corren dentro de la sesión. Y sin `kb_options` de grupo, el botón de la barra
-- era la ÚNICA forma de volver a `us`, inalcanzable desde el lock.
-- Si se reintroduce: añadir también un atajo de teclado para rotar.
