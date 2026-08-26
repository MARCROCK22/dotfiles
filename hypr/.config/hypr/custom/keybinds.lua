hl.bind("CTRL+SUPER+ALT+Slash", hl.dsp.exec_cmd("xdg-open ~/.config/hypr/custom/keybinds.lua"), {description = "Edit user keybinds"} )
hl.unbind("SUPER + O")
hl.bind("SUPER + O", function()
  hl.plugin.scrolloverview.overview("toggle all")
end)

hl.unbind("SUPER + SHIFT + Left")
hl.unbind("SUPER + SHIFT + Right")

hl.bind("SUPER + SHIFT + Left",  hl.dsp.layout("swapcol l"))
hl.bind("SUPER + SHIFT + Right", hl.dsp.layout("swapcol r"))

-- mover-entre-monitores ------------------------------------------------------
-- SUPER+ALT+←/→ manda la ventana a la pantalla de al lado. SUPER+SHIFT+←/→ se
-- queda con `swapcol`, que reordena columnas dentro del workspace.
--
-- NO se usa `window.move({direction})`, que sería lo obvio: ése sólo cruza de
-- monitor si la ventana YA está en la columna del borde de ese lado. Desde
-- cualquier otra posición se limita a moverla dentro de la cinta, y como esta
-- tecla debe funcionar mirando donde mires, no sirve.
--
-- En su lugar se manda al WORKSPACE ACTIVO del monitor contiguo, que no depende
-- de dónde esté la ventana. El foco viaja solo: `follow` vale true por defecto.
local function mover_a_monitor(dir)
    local m = hl.get_active_monitor()
    local w = hl.get_active_window()
    if not m or not w then return end

    local destino = nil
    for _, o in ipairs(hl.get_monitors() or {}) do
        if o.name ~= m.name then
            local al_lado
            if dir == "l" then al_lado = o.x < m.x else al_lado = o.x > m.x end
            -- el más cercano en esa dirección, por si algún día hay tres
            if al_lado and (destino == nil or math.abs(o.x - m.x) < math.abs(destino.x - m.x)) then
                destino = o
            end
        end
    end
    if destino == nil then return end          -- no hay pantalla en esa dirección

    local ws = destino.active_workspace and destino.active_workspace.id
    if ws == nil then return end

    local addr = w.address
    hl.dispatch(hl.dsp.window.move({ workspace = tostring(ws) }))

    -- Hyprland la añade SIEMPRE al final (derecha) de la cinta de destino,
    -- venga del lado que venga. Yendo a la izquierda eso ya es correcto —entra
    -- por su borde derecho, el contiguo—, pero yendo a la derecha aparece en el
    -- extremo opuesto al que venía.
    --
    -- Se camina hacia el frente con `swapcol l`, un paso por vuelta, hasta que
    -- deja de haber ninguna columna a su izquierda. No existe atajo de un solo
    -- paso: `move <n>` desplaza la VISTA y no reordena, `promote` sólo saca la
    -- ventana a una columna propia, y `swapcol r` sobre la última ENVUELVE
    -- intercambiándola con la primera, que se iría al extremo contrario.
    -- El tope de vueltas evita quedarse colgado si algo no converge.
    if dir == "r" then
        for _ = 1, 12 do
            local mia, minx = nil, nil
            for _, o in ipairs(hl.get_windows() or {}) do
                if o.mapped and not o.floating and o.monitor
                   and o.monitor.name == destino.name
                   and o.workspace and o.workspace.id == ws then
                    local x = o.at.x
                    if minx == nil or x < minx then minx = x end
                    if o.address == addr then mia = x end
                end
            end
            if mia == nil or minx == nil or mia <= minx then break end
            hl.dispatch(hl.dsp.layout("swapcol l"))
        end
    end
end

hl.bind("SUPER + ALT + Left",  function() mover_a_monitor("l") end,
    { description = "Window: Move to monitor left" })
hl.bind("SUPER + ALT + Right", function() mover_a_monitor("r") end,
    { description = "Window: Move to monitor right" })
-- fin -- mover-entre-monitores ------------------------------------------------

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
