import AppKit
import QuartzCore

/// Glas hinter der losgelösten Ablage, in einem eigenen Begleitfenster: Liquid Glass reagiert
/// auf Fokus und Klicks des Fensters, in dem es liegt (heller, anders getönt). Dieses Fenster
/// bekommt nie den Fokus, nimmt keine Klicks an und hängt als Kindfenster unter der Ablage,
/// bewegt sich also mit ihr. So bleibt das Glas immer gleich.
final class ShelfGlassWindow: NSPanel {
    private var glassView = NSView()

    convenience init() {
        self.init(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
                  styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView()
            glass.cornerRadius = EdgeTear.cornerRadius
            glass.tintColor = nil
            glassView = glass
        } else {
            let blur = NSVisualEffectView()
            blur.material = .hudWindow
            blur.blendingMode = .behindWindow
            blur.state = .active
            blur.maskImage = Self.mask(EdgeTear.cornerRadius)
            glassView = blur
        }
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        isReleasedWhenClosed = false
        animationBehavior = .none
        hidesOnDeactivate = false
        appearance = NSAppearance(named: .darkAqua)
        let content = NSView()
        content.addSubview(glassView)
        contentView = content
        alphaValue = 0
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// Glas an die Lage der Ablage im Fenster `parent` anpassen (`body` in dessen Koordinaten).
    /// `edge`: Seite zum Bildschirmrand, solange die Ablage mit ihm verbunden ist
    func follow(_ parent: NSWindow, body: NSRect, edge: ScreenEdge? = nil) {
        if level != parent.level { level = parent.level }
        // Glas folgt dem hellen oder dunklen Erscheinungsbild des Systems (hell: heller)
        let light = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .aqua
        let look = NSAppearance(named: light ? .aqua : .darkAqua)
        if appearance?.name != look?.name { appearance = look }
        if collectionBehavior != parent.collectionBehavior { collectionBehavior = parent.collectionBehavior }
        // Das Fenster ist genau so groß wie die Ablage: Nur sein Rand schneidet das Glas
        // zuverlässig ab. Das Glas zeichnet das Fenstersystem, ein Ausschnitt in einer Ebene
        // darüber (masksToBounds) gilt dafür nicht.
        let target = NSRect(x: parent.frame.minX + body.minX, y: parent.frame.minY + body.minY,
                            width: body.width, height: body.height)
        if frame != target { setFrame(target, display: false) }
        // Verbunden: Früher war das Glas auf der Randseite 6 pt schmaler, damit seine helle Kante
        // nicht als Linie zu sehen war. Seine runden Ecken blieben, und daneben lag ein Streifen
        // ohne Glas: am Rand ein zweiter Rand mit eigenen Ecken. Jetzt reicht das Glas dort über
        // das Fenster hinaus; Kante und Ecken liegen außerhalb, das Fenster schneidet gerade ab.
        // Die Ecken der Ablage auf dieser Seite deckt das Schwarz der Verbindung (TearGoo).
        var glass = NSRect(origin: .zero, size: body.size)
        if let edge {
            let over = EdgeTear.cornerRadius + 4
            glass.size.width += over
            if edge == .left { glass.origin.x -= over }
        }
        if glassView.frame != glass { glassView.frame = glass }
        if parent.childWindows?.contains(self) != true {
            parent.addChildWindow(self, ordered: .below)
        }
    }

    /// Ein- und ausblenden (0 bis 1), auf Wunsch weich
    func show(_ amount: CGFloat, duration: TimeInterval = 0) {
        let target = max(0, min(1, amount))
        if duration > 0 {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = duration
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                animator().alphaValue = target
            }
        } else {
            alphaValue = target
        }
    }

    /// Ganz weg und vom Fenster der Ablage gelöst
    func detach() {
        alphaValue = 0
        parent?.removeChildWindow(self)
        orderOut(nil)
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
