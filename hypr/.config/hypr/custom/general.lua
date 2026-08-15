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

-- Segunda distribución de teclado --------------------------------------------
-- Va AQUÍ y no en hyprland/general.lua: ese archivo es de end-4, no está
-- versionado en el repo y `./setup` lo pisa al actualizar. `custom/general.lua`
-- se carga después (hyprland.lua:26 frente a :16), así que este valor gana.
--
-- Con dos distribuciones aparece el botón de teclado de la barra
-- (KeyboardLayoutButton), que está oculto mientras solo haya una: rota con
-- `hyprctl switchxkblayout all next`, que es un COMANDO de hyprctl y por eso
-- mantiene la sintaxis clásica aunque la config sea Lua.
hl.config({
  input = {
    kb_layout = "us,es",
  },
})
