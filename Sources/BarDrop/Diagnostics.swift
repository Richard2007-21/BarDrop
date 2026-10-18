import AppKit
import CryptoKit
import OSLog

/// Ausführliches Diagnoseprotokoll für Beta-Versionen. Standardmäßig aus; nur wer es unter
/// Über BarDrop selbst einschaltet (nach einem Hinweis), bekommt es. Alles bleibt auf diesem
/// Mac: BarDrop schickt nichts weg. Mit „Protokoll sichern“ entsteht eine Textdatei, die man
/// selbst weitergeben kann.
///
/// Anonym: Keine Datei- oder Ordnernamen, keine Pfade, keine Inhalte. Dateien erscheinen als
/// Kennung (kurzer Hash des Pfads, damit sich dieselbe Datei verfolgen lässt), Herkunft und
/// Dateiendung.
final class Diagnostics {
    static let shared = Diagnostics()

    /// Eingeschaltet (Einstellung, nur in Beta-Versionen wirksam)
    var isEnabled: Bool { AppSettings.shared.diagnosticsEnabled && AppSettings.shared.betaUpdates }

    private let queue = DispatchQueue(label: "BarDrop.diagnostics", qos: .utility)
    private let started = Date()
    private let formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    /// ~/Library/Logs/BarDrop/Diagnose.log (wird ab 4 MB in Diagnose-alt.log umbenannt)
    let logURL: URL = {
        let dir = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs/BarDrop", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("Diagnose.log")
    }()

    private init() {}

    // MARK: Festhalten

    /// Ein Ereignis festhalten. `category`: kurz, z. B. "drop", "edge", "intro".
    func record(_ category: String, _ message: @autoclosure () -> String) {
        guard isEnabled else { return }
        let text = message()
        let line = "\(formatter.string(from: Date()))  [\(category)]  \(text)\n"
        queue.async { [logURL] in
            let fm = FileManager.default
            if let size = (try? fm.attributesOfItem(atPath: logURL.path))?[.size] as? Int, size > 4_000_000 {
                let old = logURL.deletingLastPathComponent().appendingPathComponent("Diagnose-alt.log")
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

    /// Protokoll löschen (beim Ausschalten)
    func clear() {
        queue.async { [logURL] in
            try? FileManager.default.removeItem(at: logURL)
            try? FileManager.default.removeItem(at: logURL.deletingLastPathComponent().appendingPathComponent("Diagnose-alt.log"))
        }
    }

    // MARK: Anonymisieren

    /// Datei als Kennung: Herkunft, kurzer Hash des Pfads und Endung, z. B. "user#3f9a1c.pdf"
    static func anon(_ url: URL) -> String {
        let path = url.standardizedFileURL.path
        let digest = SHA256.hash(data: Data(path.utf8)).prefix(3).map { String(format: "%02x", $0) }.joined()
        let ext = url.pathExtension.lowercased()
        return "\(origin(of: url))#\(digest)" + (ext.isEmpty ? "" : ".\(ext)")
    }

    static func anon(_ urls: [URL]) -> String {
        urls.isEmpty ? "–" : urls.prefix(20).map { anon($0) }.joined(separator: ", ") + (urls.count > 20 ? " …+\(urls.count - 20)" : "")
    }

    /// Grobe Herkunft einer Datei, ohne den Ort zu verraten
    static func origin(of url: URL) -> String {
        let path = url.standardizedFileURL.path
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if path.contains("/Application Support/BarDrop/") { return "stored" }
        if path.hasPrefix(home + "/Library/Mobile Documents/") || path.hasPrefix(home + "/Library/CloudStorage/") { return "cloud" }
        if path.hasPrefix("/Volumes/") { return "volume" }
        if path.hasPrefix(NSTemporaryDirectory()) || path.contains("/T/") || path.contains("/tmp/") { return "temp" }
        if path.hasPrefix(home + "/") { return "user" }
        return "other"
    }

    // MARK: Bericht

    /// Bericht zum Sichern: Umgebung, Einstellungen, Zustand der Ablage, eigene Ereignisse und
    /// das Systemprotokoll von BarDrop seit dem Start (private Angaben bleiben verdeckt)
    func report(store: ShelfStore?) -> String {
        var out: [String] = []
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        out.append("BarDrop Diagnose / Diagnostics")
        out.append("Erstellt / Created: \(formatter.string(from: Date()))")
        out.append("")
        out.append("## Umgebung / Environment")
        out.append("BarDrop \(version) (\(build))")
        let os = ProcessInfo.processInfo.operatingSystemVersion
        out.append("macOS \(os.majorVersion).\(os.minorVersion).\(os.patchVersion)")
        out.append("Mac: \(Self.sysctl("hw.model")), \(ProcessInfo.processInfo.processorCount) cores, \(ProcessInfo.processInfo.physicalMemory / 1_073_741_824) GB")
        out.append("Laufzeit / Uptime of BarDrop: \(Int(Date().timeIntervalSince(started))) s")
        out.append("Sprache / Language: \(AppSettings.shared.language.rawValue) → \(AppLanguage.current.rawValue), System: \(Locale.preferredLanguages.prefix(3).joined(separator: ", "))")
        out.append("Aussehen / Appearance: \(NSApp.effectiveAppearance.name.rawValue)")
        for (i, screen) in NSScreen.screens.enumerated() {
            out.append("Bildschirm \(i + 1): \(Int(screen.frame.width))×\(Int(screen.frame.height)) pt, ×\(screen.backingScaleFactor)\(screen == NSScreen.main ? ", main" : "")")
        }
        out.append("Toneffekte / UI sounds: \(Sounds.interfaceSoundsEnabled)")
        out.append("")
        out.append("## Einstellungen / Settings")
        out.append(contentsOf: settingsSnapshot())
        out.append("")
        out.append("## Ablage / Shelf")
        out.append(contentsOf: shelfSnapshot(store))
        out.append("")
        out.append("## Ereignisse / Events (Diagnose.log)")
        let old = logURL.deletingLastPathComponent().appendingPathComponent("Diagnose-alt.log")
        for url in [old, logURL] {
            if let text = try? String(contentsOf: url, encoding: .utf8) { out.append(text) }
        }
        out.append("")
        out.append("## Systemprotokoll seit dem Start / System log since launch")
        out.append(contentsOf: systemLog())
        return out.joined(separator: "\n")
    }

    private func settingsSnapshot() -> [String] {
        let s = AppSettings.shared
        var lines: [String] = [
            "edge=\(s.edge.rawValue) adaptive=\(s.adaptivePosition) middleHalf=\(s.adaptiveMiddleThird) spot=\(s.verticalPosition) displays=\(s.displayMode.rawValue)",
            "openMode=\(s.openMode.rawValue) openDelay=\(s.openDelay) dragReveal=\(s.dragReveal.rawValue) smallHitArea=\(s.exactPointer) fullScreen=\(s.openInFullScreen) excludedApps=\(s.excludedApps.count)",
            "size=\(Int(s.shelfWidth))×\(Int(s.shelfHeight)) icon=\(Int(s.tileIconSize)) strip=\(s.peekThickness)/\(s.peekLength)/\(s.peekRoundness) outline=\(s.showOutline) title=\(s.titleStyle.rawValue) animation=\(s.animationStyle.rawValue) reduceMotion=\(AnimationStyle.reduceMotion)",
            "sort=\(s.sortOrder.rawValue) stacks=\(s.stackMultiple ? String(s.stackThreshold) : "off") reopenWhereLeft=\(s.reopenWhereLeft) removeAfterDragOut=\(s.removeAfterDragOut) keepAfterAction=\(s.keepAfterAction) dragOutCopyOnly=\(s.dragOutCopyOnly)",
            "finderFiles=\(s.copyAllFiles ? "copy" : "original") webAsPNGorJPEG=\(s.convertWebImages) screenshots=\(s.addScreenshots) autoRemove=\(Int(s.autoRemoveAfter))s",
            "actions=\(s.quickActions.map(\.kind.rawValue).joined(separator: ",")) split=\(s.effectiveActionSplit) actionIcon=\(Int(s.actionIconSize)) labels=\(s.showActionLabels ? (s.labelsOnlyFolders ? "folders" : "all") : "none") pin=\(s.pinFromShelf)",
            "hotKey=\(s.hotKeyDescription) haptics=\(s.hapticsEnabled) autoUpdate=\(s.autoUpdateCheck) beta=\(s.betaUpdates) introDone=\(s.didLaunchBefore)"
        ]
        lines.append("trashFull=\(TrashState.shared.isFull)")
        return lines
    }

    private func shelfSnapshot(_ store: ShelfStore?) -> [String] {
        guard let store else { return ["–"] }
        let files = store.entries.flatMap(\.files)
        var byExt: [String: Int] = [:]
        for f in files { byExt[f.url.pathExtension.lowercased().isEmpty ? "(none)" : f.url.pathExtension.lowercased(), default: 0] += 1 }
        var byOrigin: [String: Int] = [:]
        for f in files { byOrigin[Self.origin(of: f.url), default: 0] += 1 }
        let missing = files.filter { !FileManager.default.fileExists(atPath: $0.url.path) }.count
        return [
            "entries=\(store.entries.count) stacks=\(store.entries.filter(\.isStack).count) files=\(files.count) owned=\(files.filter(\.owned).count) missing=\(missing) pendingImports=\(store.pendingImports)",
            "byType: " + byExt.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " "),
            "byOrigin: " + byOrigin.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " "),
            "items: " + Self.anon(files.map(\.url))
        ]
    }

    /// Einträge von BarDrop im Systemprotokoll seit dem Start dieses Programms. Was dort
    /// als privat markiert ist (Namen, Pfade), liefert macOS nur verdeckt.
    private func systemLog() -> [String] {
        guard let store = try? OSLogStore(scope: .currentProcessIdentifier) else { return ["(nicht lesbar / not readable)"] }
        let subsystem = Bundle.main.bundleIdentifier ?? "com.zzuuuiii.bardrop"
        let position = store.position(date: started)
        guard let entries = try? store.getEntries(at: position,
                                                  matching: NSPredicate(format: "subsystem == %@", subsystem)) else {
            return ["(nicht lesbar / not readable)"]
        }
        var lines: [String] = []
        for case let entry as OSLogEntryLog in entries {
            lines.append("\(formatter.string(from: entry.date))  [\(entry.category)] \(entry.level.rawValue)  \(entry.composedMessage)")
            if lines.count > 4000 { lines.append("…"); break }
        }
        return lines.isEmpty ? ["–"] : lines
    }

    private static func sysctl(_ name: String) -> String {
        var size = 0
        sysctlbyname(name, nil, &size, nil, 0)
        guard size > 0 else { return "?" }
        var buffer = [CChar](repeating: 0, count: size)
        sysctlbyname(name, &buffer, &size, nil, 0)
        return String(cString: buffer)
    }

    // MARK: Sichern

    /// Fragt nach einem Ort und schreibt den Bericht dorthin
    func saveReport(store: ShelfStore?) {
        let panel = NSSavePanel()
        let stamp = DateFormatter.localizedString(from: Date(), dateStyle: .short, timeStyle: .none)
            .replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ".", with: "-")
        panel.nameFieldStringValue = "BarDrop-Diagnose-\(stamp).txt"
        panel.allowedContentTypes = [.plainText]
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let text = report(store: store)
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } catch {
            NSSound.beep()
        }
    }
}
