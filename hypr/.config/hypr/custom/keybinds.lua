hl.bind("CTRL+SUPER+ALT+Slash", hl.dsp.exec_cmd("xdg-open ~/.config/hypr/custom/keybinds.lua"), {description = "Edit user keybinds"} )
hl.unbind("SUPER + O")
hl.bind("SUPER + O", function()
  hl.plugin.scrolloverview.overview("toggle all")
end)

-- swapcol-retirado -----------------------------------------------------------
-- SUPER+SHIFT+←/→ vuelve a ser lo de end-4: `window.move({direction})`, que
-- MUEVE la ventana y, al llegar al borde, la pasa al otro monitor gracias a
-- binds:window_direction_monitor_fallback. Era el único atajo horizontal que
-- cruzaba de pantalla, y estas cuatro líneas lo tapaban desde faeaca7.
--
-- `swapcol` reordena columnas DENTRO del workspace y por diseño no sale de él,
-- así que no puede sustituirlo. Se queda comentado, no borrado: descomentar
-- estas cuatro líneas devuelve el comportamiento anterior tal cual.
--
-- hl.unbind("SUPER + SHIFT + Left")
-- hl.unbind("SUPER + SHIFT + Right")
--
-- hl.bind("SUPER + SHIFT + Left",  hl.dsp.layout("swapcol l"))
-- hl.bind("SUPER + SHIFT + Right", hl.dsp.layout("swapcol r"))
-- fin -- swapcol-retirado -----------------------------------------------------

hl.unbind("SUPER + BracketLeft")
hl.unbind("SUPER + BracketRight")

hl.bind("SUPER + BracketLeft",  hl.dsp.layout("consume_or_expel prev"))
hl.bind("SUPER + BracketRight", hl.dsp.layout("consume_or_expel next"))

-- sidebar-plan-b ------------------------------------------------------
-- El sidebar izquierdo solo tiene IA, traductor y anime, y los
-- tres estan desactivados: abria un placeholder vacio.
-- SUPER+ALT+A (detach) se deja sin tocar como via de entrada.
hl.unbind("SUPER + A")
hl.unbind("SUPER + B")

-- Libres para lo que quieras, por ejemplo:
--   hl.bind("SUPER + A", hl.dsp.exec_cmd("..."), { description = "App: ..." })
-- fin -- sidebar-plan-b --------------------------------------------------
