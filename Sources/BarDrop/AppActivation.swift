import AppKit

/// BarDrop aktivieren, ohne andere eigene Fenster nach vorn zu holen.
///
/// Wird eine App aktiviert, holt macOS ihre Fenster nach vorn. Für die Ablage ist das
/// falsch: Ein Rechtsklick, die Übersicht oder eine Rückfrage aus der Ablage holten so
/// auch die Einstellungen hervor, die gerade hinter anderen Fenstern lagen, und sie
/// blieben danach vorn. Hier wird vorher gemerkt, welches fremde Fenster direkt über
/// jedem eigenen Fenster lag, und das eigene Fenster danach wieder darunter gelegt.
enum AppActivation {
    /// Ist BarDrop die vorderste App? Nicht `NSApp.isActive`: Das meldet schon „aktiv“,
    /// sobald die Ablage (ein nicht aktivierendes Fenster) den Tastaturfokus hat, obwohl die
    /// App davor vorn bleibt. Laut Diagnoseprotokoll griff der Schutz unten deshalb nie.
    static var isFrontmost: Bool {
        NSWorkspace.shared.frontmostApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier
    }

    /// Aktivieren; mit `timeout` auf die Bestätigung des Systems warten (nur
    /// Systemereignisse der Aktivierung, Klicks und Tasten bleiben in der Warteschlange)
    static func activateKeepingWindows(timeout: TimeInterval = 0) {
        guard !isFrontmost else { return }
        let placements = currentPlacements()
        Diagnostics.shared.record("focus", "activate from shelf, keeps \(placements.count) window(s) in place")
        NSApp.activate(ignoringOtherApps: true)
        if timeout > 0 {
            let deadline = Date().addingTimeInterval(timeout)
            while !isFrontmost, Date() < deadline {
                guard let event = NSApp.nextEvent(matching: [.appKitDefined, .systemDefined], until: deadline,
                                                  inMode: .default, dequeue: true) else { break }
                NSApp.sendEvent(event)
            }
        }
        restore(placements)
        // Die Aktivierung wirkt teils erst einen Moment später: dann noch einmal
        DispatchQueue.main.async { AppActivation.restore(placements) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { AppActivation.restore(placements) }
    }

    /// Eigenes normales Fenster und das fremde Fenster, das direkt darüber lag
    private struct Placement {
        weak var window: NSWindow?
        let below: Int
    }

    private static func currentPlacements() -> [Placement] {
        let own = Dictionary(NSApp.windows.filter(isRegular).map { ($0.windowNumber, $0) },
                             uniquingKeysWith: { first, _ in first })
        guard !own.isEmpty else { return [] }
        let me = ProcessInfo.processInfo.processIdentifier
        // Von vorn nach hinten, nur die normale Fensterebene (keine Menüleiste, kein Dock)
        let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] ?? []
        var placements: [Placement] = []
        var lastForeign: Int?
        for entry in info {
            guard (entry[kCGWindowLayer as String] as? Int) == 0,
                  let number = entry[kCGWindowNumber as String] as? Int,
                  let pid = entry[kCGWindowOwnerPID as String] as? Int32 else { continue }
            if pid == me {
                if let window = own[number], let above = lastForeign {
                    placements.append(Placement(window: window, below: above))
                }
            } else {
                lastForeign = number
            }
        }
        return placements
    }

    private static func restore(_ placements: [Placement]) {
        for placement in placements {
            guard let window = placement.window, window.isVisible else { continue }
            window.order(.below, relativeTo: placement.below)
        }
    }

    /// Einstellungen, Skriptansicht und ähnliche Fenster (nicht Ablage, Menüs, Übersicht)
    private static func isRegular(_ window: NSWindow) -> Bool {
        window.isVisible && window.level == .normal && !(window is NSPanel)
    }
}
