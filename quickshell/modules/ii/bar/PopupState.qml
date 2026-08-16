pragma Singleton

import Quickshell

/**
 * PopupState — garantiza que solo haya UN popup de barra abierto a la vez.
 *
 * Sin esto se solapaban: `StyledPopup` mantiene el suyo vivo un margen de
 * gracia (450 ms) tras salir del widget, así que al pasar rápido de un widget
 * al de al lado el anterior seguía en pantalla mientras el nuevo ya se había
 * abierto. Aquí, en cuanto uno quiere abrirse, al anterior se le corta la
 * gracia y desaparece en el acto.
 *
 * No hace falta forzar `active`: `StyledPopup.active` es
 * `wantOpen || graceTimer.running`, y si el ratón ya no está sobre el widget
 * anterior su `wantOpen` es false. Basta con parar su temporizador. Y si el
 * ratón SÍ siguiera encima de ese widget, no habría nada que cerrar: no se
 * pueden señalar dos a la vez.
 */
Singleton {
    id: root

    property var abierto: null

    function reclamar(popup: var): void {
        if (root.abierto && root.abierto !== popup)
            root.abierto.cerrarYa();
        root.abierto = popup;
    }

    function soltar(popup: var): void {
        if (root.abierto === popup)
            root.abierto = null;
    }
}
