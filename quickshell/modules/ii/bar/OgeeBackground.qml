import qs.modules.common
import QtQuick
import QtQuick.Shapes

/**
 * OgeeBackground — fondo de barra cuyos extremos son una curva en S.
 *
 * De donde salen los numeros: medidos sobre una captura, trazando el borde
 * con precision subpixel fila a fila.
 *
 *     y= 0   x=1872.6     pendiente arriba  -1.63 px/fila
 *     y=18   x=1857.4              medio    -0.45 px/fila
 *     y=36   x=1843.4              abajo    -1.32 px/fila
 *
 * Fuerte -> suave -> fuerte, y la curvatura cambia de signo justo a media
 * altura. Contra la cuerda recta: a 1/4 de altura el borde va 3 px hacia
 * DENTRO (concavo), a 3/4 va 1.8 px hacia FUERA (convexo), y cruza la cuerda
 * en el punto medio. Eso es una ogiva, no una esquina redondeada: la barra no
 * termina, se derrite hacia el borde de la pantalla.
 *
 * Proporciones de la referencia: alto 37 px, metida ~7.5 % del ancho por cada
 * lado, y cada extremo barre 29.2 px = 0.79 veces la altura.
 *
 * Como se dibuja: una cubica de Bezier con las tangentes HORIZONTALES en los
 * dos extremos da exactamente ese perfil. Con P0=(0,0), P1=(kS,0),
 * P2=(S-kS,H), P3=(S,H) la coordenada y sale y(t) = H·t²(3-2t) — el
 * smoothstep de toda la vida — y la x cruza la cuerda en t=0.5. La inflexion
 * cae en el medio sin tener que forzarla.
 *
 * RoundCorner.qml de end-4 no vale aqui: es un PathAngleArc, un solo arco de
 * curvatura constante, y no puede cambiar de signo.
 */
Item {
    id: root

    property color color: Appearance.colors.colLayer0
    property color borderColor: Appearance.colors.colLayer0Border
    property real borderWidth: 0

    // Cuanto se mete la barra por cada lado.
    property real sideInset: root.width * 0.075
    // Cuanto barre el extremo en horizontal a lo largo de toda la altura.
    property real sweep: root.height * 0.79
    // Cuanto se tumban las tangentes en los extremos.
    // 0.28 NO es a ojo: es el valor que minimiza el error contra las 34 filas
    // medidas de la captura (RMS 1.09 px). 0.5 —la S "de manual"— da 2.00 px,
    // porque tumba demasiado los extremos y deja el medio muy vertical.
    // Subelo hacia 0.6 para una S mas marcada; bajalo hacia 0.1 y tiende a
    // un trapecio de lados rectos.
    property real bend: 0.28

    // Existe solo para que StyledRectangularShadow no se quede sin `radius`
    // si alguien apunta su `target` aqui. Esta silueta no lleva sombra.
    property real radius: 0

    // Si la pantalla fuese estrecha, los dos extremos podrian cruzarse y el
    // relleno saldria del reves. Se acota para que siempre quede meseta plana.
    readonly property real maxInset: Math.max(0, (root.width - root.sweep * 2) / 2 - 8)
    readonly property real inset: Math.max(0, Math.min(root.sideInset, root.maxInset))

    // ── LO QUE TIENE QUE USAR EL CONTENIDO ────────────────────────────────
    // Este fondo pinta MENOS ancho que el item que lo contiene. Quien ponga
    // widgets encima tiene que apartarlos otro tanto, o se dibujaran sobre el
    // hueco donde ya no hay fondo — que es exactamente lo que pasa si anclas
    // las secciones a parent.left / parent.right.
    //
    // Se usa inset + sweep, o sea el borde INFERIOR de la curva, que es el
    // punto mas metido. A media altura la curva esta en inset + sweep/2, asi
    // que esto deja holgura de sobra para un icono centrado verticalmente.
    readonly property real contentInset: root.inset + root.sweep

    Shape {
        anchors.fill: parent
        // CurveRenderer antialiasa en la GPU. NADA de layer.enabled: crea una
        // textura del tamaño exacto del item y se comeria el trazo del borde.
        preferredRendererType: Shape.CurveRenderer

        ShapePath {
            id: sp

            fillColor: root.color
            strokeColor: root.borderWidth > 0 ? root.borderColor : "transparent"
            strokeWidth: root.borderWidth

            // Arriba la barra es mas ANCHA que abajo: por eso el extremo
            // superior esta mas afuera y el inferior mas adentro.
            readonly property real izqArriba: root.inset
            readonly property real izqAbajo: root.inset + root.sweep
            readonly property real derArriba: root.width - root.inset
            readonly property real derAbajo: root.width - root.inset - root.sweep
            readonly property real tira: root.bend * root.sweep
            readonly property real alto: root.height

            startX: sp.izqArriba
            startY: 0

            // ── borde superior ────────────────────────────────────────────
            PathLine {
                x: sp.derArriba
                y: 0
            }

            // ── extremo derecho: S hacia dentro ───────────────────────────
            PathCubic {
                x: sp.derAbajo
                y: sp.alto
                // Tangente horizontal arriba y abajo: eso es lo que produce
                // el perfil fuerte-suave-fuerte y la inflexion centrada.
                control1X: sp.derArriba - sp.tira
                control1Y: 0
                control2X: sp.derAbajo + sp.tira
                control2Y: sp.alto
            }

            // ── borde inferior ────────────────────────────────────────────
            PathLine {
                x: sp.izqAbajo
                y: sp.alto
            }

            // ── extremo izquierdo: la misma S, espejada ───────────────────
            PathCubic {
                x: sp.izqArriba
                y: 0
                control1X: sp.izqAbajo - sp.tira
                control1Y: sp.alto
                control2X: sp.izqArriba + sp.tira
                control2Y: 0
            }
        }
    }
}
