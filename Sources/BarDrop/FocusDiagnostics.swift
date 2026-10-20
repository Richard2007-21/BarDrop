import AppKit
import Quartz

/// Diagnoseprotokoll (nur Beta, nur wenn eingeschaltet): wer gerade den Tastaturfokus hat
/// und wann BarDrop aktiv wird oder es abgibt. Dient der Fehlersuche bei Fokusverlusten
/// (Leertaste landet im Fenster dahinter, Einstellungen springen nach vorn). Fenster
/// erscheinen nur als Art (Ablage, Übersicht, Einstellungen …), fremde Apps nur als
/// „andere App“ bzw. „Dienst“, nie mit Namen.
final class FocusDiagnostics {
    private var observers: [NSObjectProtocol] = []
    private let settingsWindow: () -> NSWindow?

    init(settingsWindow: @escaping () -> NSWindow?) {
        self.settingsWindow = settingsWindow
        let center = NotificationCenter.default
        for (name, sign) in [(NSWindow.didBecomeKeyNotification, "+"), (NSWindow.didResignKeyNotification, "-")] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                guard let self, let window = note.object as? NSWindow else { return }
                Diagnostics.shared.record("focus", "key\(sign) \(self.kind(window)) appActive=\(NSApp.isActive)")
            })
        }
        observers.append(center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil,
                                            queue: .main) { [weak self] _ in
            guard let self else { return }
            Diagnostics.shared.record("focus", "app active key=\(NSApp.keyWindow.map(self.kind) ?? "–")")
        })
        observers.append(center.addObserver(forName: NSApplication.didResignActiveNotification, object: nil,
                                            queue: .main) { _ in
            Diagnostics.shared.record("focus", "app inactive")
        })
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
            let what = app.activationPolicy == .regular ? "andere App"
                : (SettingsFocusReturn.menuBarServices.contains(app.bundleIdentifier ?? "") ? "Menüleisten-Dienst" : "Dienst")
            Diagnostics.shared.record("focus", "frontmost \(what)")
        })
    }

    private func kind(_ window: NSWindow) -> String {
        if window is ShelfPanel { return "Ablage" }
        if window is QLPreviewPanel { return "Übersicht" }
        if window is IntroWindow { return "Einführung" }
        if window === settingsWindow() { return "Einstellungen" }
        if window is ChoicePopup { return "Auswahlliste" }
        return String(describing: type(of: window))
    }
}
