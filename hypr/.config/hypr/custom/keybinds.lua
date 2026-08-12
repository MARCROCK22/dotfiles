hl.bind("CTRL+SUPER+ALT+Slash", hl.dsp.exec_cmd("xdg-open ~/.config/hypr/custom/keybinds.lua"), {description = "Edit user keybinds"} )
hl.unbind("SUPER + O")
hl.bind("SUPER + O", function()
  hl.plugin.scrolloverview.overview("toggle all")
end)

hl.unbind("SUPER + SHIFT + Left")
hl.unbind("SUPER + SHIFT + Right")

hl.bind("SUPER + SHIFT + Left",  hl.dsp.layout("swapcol l"))
hl.bind("SUPER + SHIFT + Right", hl.dsp.layout("swapcol r"))

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
