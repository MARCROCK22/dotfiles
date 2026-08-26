-- pantalla-principal ---------------------------------------------------------
-- Hyprland numera los monitores por orden de DETECCIÓN, no por posición, así
-- que la pantalla de la izquierda puede salir como id=1 y ese número no se
-- puede cambiar desde la configuración. Lo que sí se puede es que el workspace
-- 1 viva ahí, que es lo que en la práctica hace de «principal»: donde empieza
-- la numeración y dónde caes al entrar.
--
-- El nombre de la salida NO se escribe a mano: este archivo va al repo y en el
-- portátil las salidas se llaman de otra forma (eDP-1). Se busca la de menor x,
-- que es la de más a la izquierda en cualquier máquina; con una sola pantalla
-- sale ella misma y la regla es inofensiva.
local izquierda, min_x = nil, nil
for _, m in ipairs(hl.get_monitors() or {}) do
    if min_x == nil or m.x < min_x then
        min_x, izquierda = m.x, m.name
    end
end
if izquierda then
    hl.workspace_rule({ workspace = "1", monitor = izquierda, default = true })
end
-- fin -- pantalla-principal --------------------------------------------------

-- cinta-vertical --------------------------------------------------------------
-- El layout de scroll admite `direction`, y acepta "down"/"up" además de
-- "left"/"right". Como se puede fijar por workspace con `layout_opts`, caben
-- unos workspaces horizontales y otros verticales en la misma sesión.
--
-- El 2 va en vertical a modo de prueba: las ventanas se apilan hacia abajo, y
-- las mismas teclas siguen valiendo porque las flechas siguen la dirección de
-- la cinta. Si no convence, se borra este bloque y no queda rastro.
hl.workspace_rule({ workspace = "2", layout_opts = { direction = "down" } })
-- fin -- cinta-vertical -------------------------------------------------------
