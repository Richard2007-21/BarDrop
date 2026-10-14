import SwiftUI

/// Tiefschwarze Form, die bündig am Bildschirmrand sitzt. Zum Rand hin läuft sie
/// mit konkaven Rundungen aus (wie die Notch / Dynamic Island), zur Bildschirmmitte
/// hin hat sie weiche Ecken.
///
/// Die Rundung zur Mitte hat Vorrang: Ist die Form schmal, wird der konkave
/// Übergang horizontal gestaucht statt die Ecken eckig werden zu lassen.
/// So wirken der schmale Streifen und die mittlere Stufe wie verkleinerte
/// Versionen der großen Ablage.
struct EdgeBlobShape: Shape {
    var edge: ScreenEdge
    var cornerRadius: CGFloat
    var fillet: CGFloat
    /// Wie lang der Übergang zum Rand im Verhältnis zu seiner Tiefe ausläuft.
    /// 1,25 = rund wie bei der offenen Ablage; größer = flacher und länger, sodass
    /// der schmale Streifen aussieht, als wölbe sich der Bildschirmrand selbst.
    var filletStretch: CGFloat = 1.25
    /// Wie lang die innere Rundung in Randrichtung ausläuft (1 = Kreis).
    /// Beim flachen Streifen gehen Rundung und Übergang so ohne Knick ineinander über.
    var cornerStretch: CGFloat = 1
    /// false: nur die Kontur, ohne die Linie am Bildschirmrand (für den feinen Rahmen)
    var closed = true

    var animatableData: AnimatablePair<AnimatablePair<CGFloat, CGFloat>, AnimatablePair<CGFloat, CGFloat>> {
        get { AnimatablePair(AnimatablePair(cornerRadius, fillet), AnimatablePair(filletStretch, cornerStretch)) }
        set {
            cornerRadius = newValue.first.first
            fillet = newValue.first.second
            filletStretch = newValue.second.first
            cornerStretch = newValue.second.second
        }
    }

    func path(in rect: CGRect) -> Path {
        guard rect.width > 0.5, rect.height > 0.5 else { return Path() }

        let width = rect.width
        let maxFy = max(0, min(fillet, rect.height / 4))
        let r = max(0, min(cornerRadius, (rect.height - 2 * maxFy) / 2, width))
        let fx = max(0, min(fillet, width - r))                 // horizontale Ausdehnung des Übergangs
        let fy = min(maxFy, fx * filletStretch)                 // vertikal: rund oder lang auslaufend
        let top = rect.minY
        let bottom = rect.maxY
        let bodyTop = top + fy
        let bodyBottom = bottom - fy
        // Innere Rundung: horizontal r, vertikal gestreckt (höchstens bis zur Mitte)
        let ry = max(0, min(r * max(1, cornerStretch), (bodyBottom - bodyTop) / 2))
        let k: CGFloat = 0.5523                                  // Kreisannäherung mit Bézierkurven

        // Für den rechten Rand zeichnen (Rand bei maxX), für links spiegeln.
        let edgeX = rect.maxX
        let innerX = rect.minX

        var p = Path()
        p.move(to: CGPoint(x: edgeX, y: top))
        // konkaver Übergang oben
        p.addCurve(to: CGPoint(x: edgeX - fx, y: bodyTop),
                   control1: CGPoint(x: edgeX, y: top + k * fy),
                   control2: CGPoint(x: edgeX - fx + k * fx, y: bodyTop))
        p.addLine(to: CGPoint(x: innerX + r, y: bodyTop))
        // weiche Ecke oben innen
        p.addCurve(to: CGPoint(x: innerX, y: bodyTop + ry),
                   control1: CGPoint(x: innerX + r - k * r, y: bodyTop),
                   control2: CGPoint(x: innerX, y: bodyTop + ry - k * ry))
        p.addLine(to: CGPoint(x: innerX, y: bodyBottom - ry))
        // weiche Ecke unten innen
        p.addCurve(to: CGPoint(x: innerX + r, y: bodyBottom),
                   control1: CGPoint(x: innerX, y: bodyBottom - ry + k * ry),
                   control2: CGPoint(x: innerX + r - k * r, y: bodyBottom))
        p.addLine(to: CGPoint(x: edgeX - fx, y: bodyBottom))
        // konkaver Übergang unten
        p.addCurve(to: CGPoint(x: edgeX, y: bottom),
                   control1: CGPoint(x: edgeX - fx + k * fx, y: bodyBottom),
                   control2: CGPoint(x: edgeX, y: bottom - k * fy))
        if closed { p.closeSubpath() }

        if edge == .left {
            let mirror = CGAffineTransform(translationX: rect.minX + rect.maxX, y: 0).scaledBy(x: -1, y: 1)
            return p.applying(mirror)
        }
        return p
    }
}
