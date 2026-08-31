-- Anuncio de bateria del casco ----------------------------------------------
-- Escucha el boton de encendido del G733 y dice la carga en voz alta. Es lo
-- que hace G HUB en Windows, que no existe para Linux.
--
-- Va aqui, colgando de la sesion, y no como servicio de systemd: es lo que ya
-- hace end-4 con hypridle y los demas.
--
-- `hyprland.start` NO se dispara en las recargas, asi que un `hyprctl reload`
-- no lo duplica. Aun asi el script lleva cerrojo de instancia unica, por si
-- alguna vez se lanza tambien a mano.
--
-- Ruta completa y no solo el nombre: no se puede dar por hecho que
-- ~/.local/bin este en el PATH del proceso que arranca la sesion.
hl.on("hyprland.start", function()
    hl.exec_cmd("$HOME/.local/bin/casco-bateria")
end)

-- Vigilante de la barra ------------------------------------------------------
-- quickshell se cae solo de vez en cuando: pide una captura de una ventana que
-- ya se cerro, Hyprland lo considera un cliente que habla mal y lo expulsa. La
-- carrera esta dentro de su codigo compilado, asi que desde aqui no se puede
-- arreglar; lo que si se puede es que no cueste nada. Ver la cabecera del
-- script para la reconstruccion completa del fallo.
--
-- No lanza la barra: de eso sigue encargandose hyprland/execs.lua, que es de
-- end-4 y no se toca. Este se engancha a la que ya hay y solo actua si muere.
--
-- Se cuelga de un pidfd, asi que no sondea: duerme hasta que el kernel lo
-- despierta. Y si la barra volviera sola --una recarga a mano-- se limita a
-- re-engancharse en vez de lanzar una segunda.
hl.on("hyprland.start", function()
    hl.exec_cmd("$HOME/.local/bin/barra-viva")
end)
