import AppKit

/// Kontrollzentrum, Mitteilungen und die Menüs von macOS in der Menüleiste nehmen BarDrop
/// kurz den Fokus. Schließt man sie wieder, gibt macOS ihn nicht an BarDrop zurück
/// (eine App ohne Dock-Symbol wird dabei übergangen), sondern an die App davor: Die
/// Einstellungen waren dann nicht mehr aktiv, obwohl man nirgends anders hingeklickt hatte.
///
/// Darum: Hatten die Einstellungen den Fokus und ging er an einen dieser Dienste, bekommen
/// sie ihn zurück, sobald danach eine andere App aktiv
/// wird, ohne dass man in deren Fenster geklickt hat. Klicks in die Menüleiste und in die
/// Fenster des Menüs selbst zählen nicht. Wer bewusst zu einer anderen App wechselt (Klick
/// in ihr Fenster, ⌘⇥ direkt aus den Einstellungen), wird nicht zurückgeholt. Spotlight
/// gehört bewusst nicht dazu: Wer von dort eine App startet, will zu ihr.
final class SettingsFocusReturn {
    /// Dienste der Menüleiste von macOS (Kontrollzentrum, Mitteilungen, Menüleisten-Symbole
    /// und Eingabequellen)
    static let menuBarServices: Set<String> = [
        "com.apple.controlcenter", "com.apple.notificationcenterui",
        "com.apple.systemuiserver", "com.apple.TextInputMenuAgent"
    ]

    private let settingsWindow: () -> NSWindow?
    private var observers: [NSObjectProtocol] = []
    private var clickMonitor: Any?
    /// Die Einstellungen hatten eben noch den Fokus
    private var settingsWereKey = false
    /// BarDrop war zuletzt die vorderste App (laut macOS, nicht nur Fokus in der Ablage)
    private var ownAppFrontmost = AppActivation.isFrontmost
    /// Der Fokus ging an eine App ohne Fenster in der Menüleiste: deren Prozess und wann
    private var pending: (pid: pid_t, since: Date)?
    /// So lange darf das Menü offen gewesen sein, danach wird nichts mehr zurückgeholt
    private static let maximumWait: TimeInterval = 120

    init(settingsWindow: @escaping () -> NSWindow?) {
        self.settingsWindow = settingsWindow
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: NSApplication.willResignActiveNotification, object: nil,
                                            queue: .main) { [weak self] _ in
            guard let self else { return }
            // Nur, wenn man wirklich in den Einstellungen war (BarDrop vorderste App). Gab die
            // Ablage den Fokus ab, wurden die Einstellungen teils im Hintergrund Schlüsselfenster,
            // ohne dass man dort war; nach dem Kontrollzentrum sprangen sie dann ungefragt nach vorn
            self.settingsWereKey = self.settingsWindow()?.isKeyWindow == true
        })
        observers.append(center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil,
                                            queue: .main) { [weak self] _ in
            self?.pending = nil
        })
        let workspace = NSWorkspace.shared.notificationCenter
        observers.append(workspace.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil,
                                               queue: .main) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            self?.activated(app)
        })
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.clicked(at: NSEvent.mouseLocation)
        }
    }

    deinit {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
    }

    private func activated(_ app: NSRunningApplication?) {
        let wasFrontmost = ownAppFrontmost
        ownAppFrontmost = app?.processIdentifier == ProcessInfo.processInfo.processIdentifier
        guard let app, app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
        if app.activationPolicy != .regular {
            guard Self.menuBarServices.contains(app.bundleIdentifier ?? "") else {
                // Andere Apps ohne Fenster (Spotlight, Starter): nichts zurückholen
                settingsWereKey = false
                pending = nil
                return
            }
            // Kontrollzentrum & Co.: merken, wenn die Einstellungen den Fokus hatten. Nur, wenn
            // BarDrop davor wirklich vorn war: Gab die Ablage den Fokus ab, wurden die
            // Einstellungen teils im Hintergrund Schlüsselfenster, ohne dass man dort war, und
            // sprangen nach dem Kontrollzentrum ungefragt nach vorn
            if settingsWereKey, wasFrontmost, settingsWindow()?.isVisible == true {
                pending = (app.processIdentifier, Date())
            }
            settingsWereKey = false
            return
        }
        settingsWereKey = false
        guard let waiting = pending else { return }
        pending = nil
        guard Date().timeIntervalSince(waiting.since) < Self.maximumWait,
              let window = settingsWindow(), window.isVisible else { return }
        // Das Menü ist zu und macOS hat eine andere App aktiviert: zurück zu den Einstellungen
        Diagnostics.shared.record("focus", "Einstellungen zurückgeholt nach Menüleistendienst")
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    /// Ein Klick in das Fenster einer anderen App: Dorthin wollte man, nichts zurückholen
    private func clicked(at point: NSPoint) {
        guard let waiting = pending else { return }
        if Self.inMenuBar(point) { return }
        if Self.ownerOfWindow(at: point) == waiting.pid { return }   // im Menü selbst
        pending = nil
    }

    /// Über dem sichtbaren Bereich eines Bildschirms liegt die Menüleiste
    private static func inMenuBar(_ point: NSPoint) -> Bool {
        NSScreen.screens.contains { $0.frame.contains(point) && point.y >= $0.visibleFrame.maxY }
    }

    /// Prozess des obersten Fensters an einem Punkt (Bildschirmkoordinaten von AppKit)
    private static func ownerOfWindow(at point: NSPoint) -> pid_t? {
        guard let primary = NSScreen.screens.first else { return nil }
        // CoreGraphics zählt von oben links des Hauptbildschirms
        let flipped = CGPoint(x: point.x, y: primary.frame.maxY - point.y)
        let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] ?? []
        for entry in info {
            guard let bounds = entry[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary),
                  let pid = entry[kCGWindowOwnerPID as String] as? pid_t else { continue }
            if rect.contains(flipped) { return pid }
        }
        return nil
    }
}
