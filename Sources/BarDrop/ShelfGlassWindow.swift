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

    /// Glas an die Lage der Ablage im Fenster `parent` anpassen (`body` in dessen Koordinaten)
    func follow(_ parent: NSWindow, body: NSRect) {
        if level != parent.level { level = parent.level }
        if collectionBehavior != parent.collectionBehavior { collectionBehavior = parent.collectionBehavior }
        if frame != parent.frame { setFrame(parent.frame, display: false) }
        if glassView.frame != body { glassView.frame = body }
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
