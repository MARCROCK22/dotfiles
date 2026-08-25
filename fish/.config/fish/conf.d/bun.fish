# bun-fuera-de-la-cache ------------------------------------------------------
# El paquete de Arch (bun 1.4.0) instala los paquetes GLOBALES en
# ~/.cache/.bun cuando BUN_INSTALL no está definida. Eso es un directorio de
# datos desechables: vaciar la caché —a mano o con cualquier limpiador— borra
# herramientas que se esperan permanentes. Le pasó a ccstatusline, que dibuja
# la barra de estado de Claude Code.
#
# Va en conf.d/ y no en config.fish porque config.fish sólo exporta esto dentro
# del bloque interactivo, y los procesos que lanza el compositor no lo son.
set -gx BUN_INSTALL "$HOME/.local/share/bun"
fish_add_path -g "$BUN_INSTALL/bin"
# fin -- bun-fuera-de-la-cache -----------------------------------------------
