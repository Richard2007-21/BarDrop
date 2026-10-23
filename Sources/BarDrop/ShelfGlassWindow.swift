import AppKit
import QuartzCore

/// Glas hinter der losgelösten Ablage, in einem eigenen Begleitfenster: Liquid Glass reagiert
/// auf Fokus und Klicks des Fensters, in dem es liegt (heller, anders getönt). Dieses Fenster
/// bekommt nie den Fokus, nimmt keine Klicks an und hängt als Kindfenster unter der Ablage,
/// bewegt sich also mit ihr. So bleibt das Glas immer gleich.
final class ShelfGlassWindow: NSPanel {
    private var glassView = NSView()
    /// Schneidet das Glas zu: Mit dem Rand verbunden, reicht das Glas auf der Randseite unter
    /// diesem Rahmen hindurch, und der Rahmen rundet dort so wie die Ablage selbst
    private let clip = NSView()

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
        clip.wantsLayer = true
        clip.layer?.masksToBounds = true
        clip.layer?.cornerCurve = .continuous
        clip.addSubview(glassView)
        let content = NSView()
        content.addSubview(clip)
        contentView = content
        alphaValue = 0
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// Glas an die Lage der Ablage im Fenster `parent` anpassen (`body` in dessen Koordinaten).
    /// `edge`: Seite zum Bildschirmrand und Rundung der Ablage dort, solange sie verbunden ist
    func follow(_ parent: NSWindow, body: NSRect, edge: (side: ScreenEdge, radius: CGFloat)? = nil) {
        if level != parent.level { level = parent.level }
        // Glas folgt dem hellen oder dunklen Erscheinungsbild des Systems (hell: heller)
        let light = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .aqua
        let look = NSAppearance(named: light ? .aqua : .darkAqua)
        if appearance?.name != look?.name { appearance = look }
        if collectionBehavior != parent.collectionBehavior { collectionBehavior = parent.collectionBehavior }
        if frame != parent.frame { setFrame(parent.frame, display: false) }
        if clip.frame != body { clip.frame = body }
        // Verbunden: Früher wurde das Glas auf der Randseite 6 pt schmaler, damit seine helle
        // Kante nicht als Linie zu sehen war. Seine runden Ecken blieben aber, und daneben lag
        // ein Streifen ohne Glas: am Rand ein doppelter Rand mit zwei Rundungen übereinander.
        // Jetzt reicht das Glas dort über den Rahmen hinaus (Kante und Ecken liegen außerhalb),
        // und der Rahmen rundet die Randseite genau wie die Tönung (EdgeTear.edgeRadius).
        var glass = NSRect(origin: .zero, size: body.size)
        if let edge {
            let over = EdgeTear.cornerRadius + 4
            glass.size.width += over
            if edge.side == .left { glass.origin.x -= over }
            clip.layer?.cornerRadius = edge.radius
            clip.layer?.maskedCorners = edge.side == .left
                ? [.layerMinXMinYCorner, .layerMinXMaxYCorner]
                : [.layerMaxXMinYCorner, .layerMaxXMaxYCorner]
        } else {
            clip.layer?.cornerRadius = 0
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
