import SwiftUI
import AppKit

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
    static let tearDistance: CGFloat = 85
    /// Zusätzliche dunkle Tönung über dem Glas der losgelösten Ablage
    static let glassDarken: Double = 0.5
    /// Bis zu diesem Abstand zum Rand zieht er die Ablage wieder an
    static let attachZone: CGFloat = 70
    /// Dehnen bis zum Lösen: höchstens so weit (pt) folgt die Ablage, und so schnell wird es
    /// zäh (anfangs folgt sie gut, kurz vor dem Reißen kaum noch)
    static let stretchMax: CGFloat = 18
    static let stretchSoftness: CGFloat = 32
    /// Griff oben in der Mitte und die Fläche um ihn herum, an der man ziehen kann
    static let grabWidth: CGFloat = 120
    static let grabHeight: CGFloat = 26
    /// Eckenradius der schwebenden Ablage (wie die offene Ablage innen)
    static let cornerRadius: CGFloat = 28
    /// Höhe der Kopfzeile (Abstand oben, Zeile, Abstand unten, siehe ShelfContent)
    static let headerHeight: CGFloat = 46
}

/// Die schwarze Form, solange die Ablage gezogen wird: Ablage, Verbindung und ein Stück
/// Rand verschmelzen wie Flüssigkeit (Unschärfe, dann harte Schwelle). Je weiter die
/// Ablage vom Rand weg ist, desto dünner die Verbindung, bis sie reißt.
struct TearGoo: View, Animatable {
    let tear: ShelfUIModel.Tear
    /// Platz über und unter der Ablage im Rahmen (Rand-Übergänge)
    let inset: CGFloat
    /// Platz links und rechts der Ablage im Rahmen
    let reach: CGFloat
    /// Feiner heller Rahmen wie am Rand (Einstellung „Rahmen“ bzw. in der Einführung)
    var outline = false
    /// Losgelöst aus Glas (0 schwarz wie am Rand, 1 Glas). Je näher sie einem Rand kommt,
    /// desto schwärzer, damit sie beim Andocken nahtlos in die schwarze Ablage übergeht.
    var glass: Double = 0

    /// Der Übergang zu Glas wird Bild für Bild berechnet (sonst sprang der Verlauf sofort ans
    /// Ende, während das Glas erst einblendete: kurz war alles durchsichtig)
    var animatableData: Double {
        get { glass }
        set { glass = newValue }
    }

    var body: some View {
        let attach = Double(max(0, min(1, tear.attach)))
        let black = max(1 - glass, attach)
        ZStack {
            if glass > 0.001 {
                // Schatten nur außerhalb der Ablage: Unter dem Glas sähe man ihn sonst durch
                bodyShape
                    .fill(Color.black)
                    .shadow(color: .black.opacity(0.45), radius: 18, x: 0, y: 8)
                    .mask {
                        ZStack {
                            Rectangle()
                            bodyShape.blendMode(.destinationOut)
                        }
                        .compositingGroup()
                    }
                    .opacity(1 - black)
                ShelfGlass(cornerRadius: EdgeTear.cornerRadius)
                    .padding(.horizontal, reach)
                    .padding(.vertical, inset)
                    .opacity(glass)
                // Eigene dunkle Tönung über dem Glas: Liquid Glass passt seine Helligkeit dem
                // Hintergrund und dem Fokus an und wurde sonst ohne Fokus deutlich heller
                bodyShape
                    .fill(Color.black.opacity(EdgeTear.glassDarken))
                    .opacity(glass)
            }
            if glass < 0.999 || attach > 0.001 {
                // Das Schwarz zieht sich zum Rand hin zurück, als bliebe es dort hängen (beim
                // Andocken kommt es von dort wieder)
                solid.mask { darkness(attach: attach) }
            }
            if outline {
                outlineStroke
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// Wie schwarz die Ablage wo ist: an der Seite zum Rand zuletzt durchsichtig, in Randnähe
    /// (Verbindung) überall schwarz
    private func darkness(attach: Double) -> some View {
        // Übergangskante wandert mit dem Glas von der fernen Seite zum Rand
        let width = 0.45
        let edge = (1 + width) * (1 - glass) - width
        let stops: [Gradient.Stop] = (0...12).map { i in
            let x = Double(i) / 12
            let t = max(0, min(1, (x - edge) / width))
            let sweep = 1 - t * t * (3 - 2 * t)
            return Gradient.Stop(color: Color.black.opacity(max(sweep, attach)), location: x)
        }
        let fromLeft = tear.side == .left
        // Verlauf über die Ablage selbst (links und rechts liegt im Fenster noch `reach`)
        return GeometryReader { geo in
            let w = max(1, geo.size.width)
            let near = UnitPoint(x: fromLeft ? reach / w : 1 - reach / w, y: 0.5)
            let far = UnitPoint(x: fromLeft ? 1 - reach / w : reach / w, y: 0.5)
            LinearGradient(stops: stops, startPoint: near, endPoint: far)
        }
    }

    /// Umriss der Ablage im Rahmen
    private var bodyShape: TearBodyShape {
        TearBodyShape(reach: reach, inset: inset)
    }

    /// Schwarze Ablage wie am Rand (angedockt, beim Dehnen, beim Andocken)
    @ViewBuilder
    private var solid: some View {
        Group {
            if tear.attach > 0.01 {
                // Mit dem Rand verbunden: verschmelzende Formen (aufwendig, nur dann)
                goo(grow: 0, color: .black)
                    .shadow(color: .black.opacity(0.45), radius: 18, x: 0, y: 8)
            } else {
                // Gelöst oder schwebend: ein einfaches abgerundetes Rechteck, das kostet beim
                // Ziehen fast nichts
                // Mit Rahmen 1 pt größer: Der Rahmen liegt dann ganz auf Schwarz, ohne
                // durchscheinenden Spalt zwischen Rahmen und Fläche
                RoundedRectangle(cornerRadius: EdgeTear.cornerRadius + (outline ? 1 : 0), style: .continuous)
                    .fill(Color.black)
                    .padding(.horizontal, reach - (outline ? 1 : 0))
                    .padding(.vertical, inset - (outline ? 1 : 0))
                    .shadow(color: .black.opacity(0.45), radius: 18, x: 0, y: 8)
            }
        }
    }

    /// Feiner heller Rahmen, scharf gezeichnet (nicht aus der verschmolzenen Form: dort wurde er
    /// an den Ecken zu dünn). Wo die Verbindung zum Rand ansetzt, ausgespart, wie am Rand selbst.
    private var outlineStroke: some View {
        Canvas { context, size in
            let body = CGRect(x: reach, y: inset, width: max(0, size.width - 2 * reach),
                              height: max(0, size.height - 2 * inset))
            guard body.width > 0, body.height > 0 else { return }
            let a = max(0, min(1, tear.attach))
            if a > 0.01 {
                let right = tear.side == .right
                // Verbindung samt ihren weichen Übergängen (etwa so breit wie die Unschärfe)
                let height = body.height * pow(a, 1.6) + 30
                // Nur ein schmaler Streifen an der Seite zum Rand: Bis zur Mitte ausgespart fehlte
                // der Rahmen oben und unten auf halber Breite und wuchs beim Lösen von den Ecken
                // her nach (bei großer Ablage deutlich zu sehen), angedockt war er dann plötzlich da
                let cut: CGFloat = 14
                let zone = CGRect(x: right ? body.maxX - cut : 0, y: body.midY - height / 2,
                                  width: right ? size.width - (body.maxX - cut) : body.minX + cut, height: height)
                var mask = Path(CGRect(origin: .zero, size: size))
                mask.addRect(zone)
                context.clip(to: mask, style: FillStyle(eoFill: true))
            }
            let path = Path(roundedRect: body.insetBy(dx: -0.5, dy: -0.5),
                            cornerRadius: EdgeTear.cornerRadius + 0.5, style: .continuous)
            context.stroke(path, with: .color(.white.opacity(0.2)), lineWidth: 1)
        }
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

/// Die losgelöste Ablage im größeren Fenster: abgerundetes Rechteck in der Mitte
struct TearBodyShape: Shape {
    let reach: CGFloat
    let inset: CGFloat

    func path(in rect: CGRect) -> Path {
        let body = rect.insetBy(dx: reach, dy: inset)
        guard body.width > 0, body.height > 0 else { return Path() }
        return Path(roundedRect: body, cornerRadius: EdgeTear.cornerRadius, style: .continuous)
    }
}

/// Glas hinter der losgelösten Ablage: ab macOS 26 Liquid Glass (mit der leichten Verzerrung
/// an den Rändern), dunkel getönt, damit Schrift und Symbole gut lesbar bleiben. Davor eine
/// dunkle Unschärfe des Hintergrunds.
struct ShelfGlass: NSViewRepresentable {
    var cornerRadius: CGFloat

    func makeNSView(context: Context) -> NSView {
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView()
            glass.appearance = NSAppearance(named: .darkAqua)
            glass.cornerRadius = cornerRadius
            // Ohne Tönung des Systems: Mit ihr wurde das Glas ohne Fokus deutlich heller.
            // Abgedunkelt wird darüber selbst (EdgeTear.glassDarken), unabhängig vom Fokus
            glass.tintColor = nil
            return glass
        }
        let blur = NSVisualEffectView()
        blur.appearance = NSAppearance(named: .darkAqua)
        blur.material = .hudWindow
        blur.blendingMode = .behindWindow
        blur.state = .active
        blur.maskImage = Self.mask(cornerRadius)
        return blur
    }

    func updateNSView(_ view: NSView, context: Context) {
        if #available(macOS 26.0, *), let glass = view as? NSGlassEffectView {
            glass.cornerRadius = cornerRadius
        }
    }

    private static func mask(_ radius: CGFloat) -> NSImage {
        let side = radius * 2 + 1
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }
}
