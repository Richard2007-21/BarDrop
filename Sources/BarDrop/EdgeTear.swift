import SwiftUI

/// Die Ablage an der Kopfzeile vom Rand ziehen: Erst dehnt sie sich wie ein Tropfen, der
/// am Rand hängt, dann löst sie sich mit einem Ruck. An einem Rand (links oder rechts)
/// losgelassen, dockt sie dort an, mit derselben Bewegung rückwärts; der Rand in den
/// Einstellungen stellt sich dabei mit um. Sonst gleitet sie an ihren Rand zurück.
/// Ablauf und Fenster: EdgeController (Abschnitt „Vom Rand ziehen“).
enum EdgeTear {
    /// Platz im Fenster links und rechts der Ablage, solange sie gezogen wird: für den
    /// Schatten und die Verbindung zum Rand
    static let reach: CGFloat = 140
    /// So weit (pt) muss man vom Rand weg ziehen, bis sich die Ablage löst
    static let tearDistance: CGFloat = 60
    /// Bis zu diesem Abstand zum Rand zieht er die Ablage wieder an
    static let attachZone: CGFloat = 70
    /// Eckenradius der schwebenden Ablage (wie die offene Ablage innen)
    static let cornerRadius: CGFloat = 28
    /// Höhe der Kopfzeile (Abstand oben, Zeile, Abstand unten, siehe ShelfContent)
    static let headerHeight: CGFloat = 46
}

/// Die schwarze Form, solange die Ablage gezogen wird: Ablage, Verbindung und ein Stück
/// Rand verschmelzen wie Flüssigkeit (Unschärfe, dann harte Schwelle). Je weiter die
/// Ablage vom Rand weg ist, desto dünner die Verbindung, bis sie reißt.
struct TearGoo: View {
    let tear: ShelfUIModel.Tear
    /// Platz über und unter der Ablage im Rahmen (Rand-Übergänge)
    let inset: CGFloat
    /// Platz links und rechts der Ablage im Rahmen
    let reach: CGFloat
    /// Feiner heller Rahmen wie am Rand (Einstellung „Rahmen“ bzw. in der Einführung)
    var outline = false

    var body: some View {
        ZStack {
            goo(grow: 0, color: .black)
                .shadow(color: .black.opacity(0.45), radius: 18, x: 0, y: 8)
            if outline {
                // Dieselbe Form, 1 pt größer und hell, darüber noch einmal die schwarze: So
                // bleibt rundum ein feiner Rand. Über dem Schatten, sonst verschwand er unten.
                goo(grow: 1, color: Color.white.opacity(0.2))
                goo(grow: 0, color: .black)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func goo(grow: CGFloat, color: Color) -> some View {
        Canvas { context, size in
            context.addFilter(.alphaThreshold(min: 0.5, color: color))
            context.addFilter(.blur(radius: 7))
            context.drawLayer { layer in
                let body = CGRect(x: reach, y: inset, width: max(0, size.width - 2 * reach),
                                  height: max(0, size.height - 2 * inset))
                guard body.width > 0, body.height > 0 else { return }
                layer.fill(Path(roundedRect: body.insetBy(dx: -grow, dy: -grow),
                                cornerRadius: EdgeTear.cornerRadius + grow, style: .continuous),
                           with: .color(.black))
                let a = max(0, min(1, tear.attach))
                guard a > 0.01 else { return }
                let right = tear.side == .right
                let edgeX = right ? body.maxX + tear.gap : body.minX - tear.gap
                // Über den Rand hinaus, damit dort keine Rundung entsteht (liegt außerhalb
                // des Bildschirms)
                let beyond: CGFloat = 30
                // Verbindung: von der Mitte der Ablage bis über den Rand, je loser, desto dünner
                let bridgeHeight = body.height * pow(a, 1.6) + 2 * grow
                if bridgeHeight > 1 {
                    let from = right ? body.midX : edgeX - beyond
                    let to = right ? edgeX + beyond : body.midX
                    layer.fill(Path(CGRect(x: from, y: body.midY - bridgeHeight / 2,
                                           width: to - from, height: bridgeHeight)),
                               with: .color(.black))
                }
                // Ein Stück Rand, das sich herauswölbt: oben und unten etwas länger als die
                // Ablage, so laufen die Übergänge weich aus wie sonst am Rand
                let stubHeight = (body.height + 2 * inset) * (0.3 + 0.7 * a) + 2 * grow
                let stubWidth = 2 * (6 + 12 * a) + 2 * grow
                layer.fill(Path(ellipseIn: CGRect(x: edgeX - stubWidth / 2, y: body.midY - stubHeight / 2,
                                                  width: stubWidth, height: stubHeight)),
                           with: .color(.black))
                layer.fill(Path(CGRect(x: right ? edgeX : edgeX - beyond, y: body.midY - stubHeight / 2,
                                       width: beyond, height: stubHeight)),
                           with: .color(.black))
            }
        }
    }
}
