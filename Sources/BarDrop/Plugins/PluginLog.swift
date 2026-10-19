import AppKit

/// Eigenes Protokoll für Plugins (Einstellungen → Plugins → Protokoll). Hält fest, welches
/// Plugin wann läuft, was klappt und was fehlschlägt: Rechte, nachgeladene Programme,
/// gestartete Programme mit ihrem Ergebnis, Anfragen ins Internet, Ausgaben des Skripts.
///
/// Getrennt vom Diagnoseprotokoll von BarDrop: eigene Datei, eigener Schalter, in allen
/// Versionen verfügbar. Anders als das anonyme Diagnoseprotokoll nennt es Dateinamen und
/// Fehlermeldungen, damit man Plugins wirklich untersuchen kann. Es bleibt auf diesem Mac.
final class PluginLog {
    static let shared = PluginLog()

    /// ~/Library/Logs/BarDrop/Plugins.log (ab 2 MB wird es zu Plugins-alt.log)
    let logURL: URL
    private let queue = DispatchQueue(label: "BarDrop.pluginlog", qos: .utility)
    private let lock = NSLock()
    private var enabled = false
    private let formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    static let maxSize = 2_000_000

    /// `directory` nur für Tests
    init(directory: URL? = nil) {
        let dir = directory ?? FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs/BarDrop", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        logURL = dir.appendingPathComponent("Plugins.log")
    }

    /// Von den Einstellungen gesetzt; aus allen Threads lesbar
    var isEnabled: Bool {
        get { lock.lock(); defer { lock.unlock() }; return enabled }
        set { lock.lock(); enabled = newValue; lock.unlock() }
    }

    /// Eine Zeile: Zeit, Plugin, Art des Ereignisses, Text. `kind`: kurz, z. B. "start", "ok",
    /// "fehler", "recht", "programm", "netz", "skript".
    func record(_ plugin: String, _ kind: String, _ text: @autoclosure () -> String) {
        guard isEnabled else { return }
        let message = text().replacingOccurrences(of: "\n", with: " ⏎ ")
        let line = "\(formatter.string(from: Date()))  \(plugin)  [\(kind)]  \(message.prefix(2000))\n"
        queue.async { [logURL] in
            let fm = FileManager.default
            if let size = (try? fm.attributesOfItem(atPath: logURL.path))?[.size] as? Int, size > Self.maxSize {
                let old = logURL.deletingLastPathComponent().appendingPathComponent("Plugins-alt.log")
                try? fm.removeItem(at: old)
                try? fm.moveItem(at: logURL, to: old)
            }
            if !fm.fileExists(atPath: logURL.path) { fm.createFile(atPath: logURL.path, contents: nil) }
            if let handle = try? FileHandle(forWritingTo: logURL) {
                handle.seekToEndOfFile()
                handle.write(Data(line.utf8))
                try? handle.close()
            }
        }
    }

    /// Wartet, bis alle Zeilen geschrieben sind (Tests, Anzeigen)
    func flush() {
        queue.sync {}
    }

    /// Protokoll leeren (auch die ältere Datei)
    func clear() {
        queue.sync {
            try? FileManager.default.removeItem(at: logURL)
            try? FileManager.default.removeItem(at: logURL.deletingLastPathComponent().appendingPathComponent("Plugins-alt.log"))
        }
    }

    /// In der App Konsole öffnen (oder der App, die .log-Dateien öffnet)
    func reveal() {
        flush()
        if !FileManager.default.fileExists(atPath: logURL.path) {
            FileManager.default.createFile(atPath: logURL.path, contents: nil)
        }
        NSWorkspace.shared.open(logURL)
    }
}
