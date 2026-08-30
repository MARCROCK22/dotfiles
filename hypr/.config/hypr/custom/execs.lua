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
