import AppKit
import Combine

/// Legt neue Bildschirmfotos automatisch in die Ablage (Einstellung „Neue Bildschirmfotos“).
/// Zwei Wege, damit es auch klappt, wenn Spotlight den Ort nicht oder verspätet indiziert:
/// der Ordner, den macOS für Bildschirmfotos verwendet (Bildschirmfoto-App → Optionen),
/// wird direkt beobachtet, und Spotlight meldet Dateien, die macOS als Bildschirmfoto
/// kennzeichnet. Läuft nur, solange die Einstellung an ist.
final class ScreenshotWatcher {
    private let store: ShelfStore
    private let onAdded: () -> Void
    private var query: NSMetadataQuery?
    private var observers: [NSObjectProtocol] = []
    private var settingObserver: AnyCancellable?
    /// Schon übernommene Dateien, damit keine doppelt landet
    private var seen = Set<String>()
    private let pasteboard = NSPasteboard(name: NSPasteboard.Name("io.github.zzuuuiii.bardrop.screenshots"))
    /// Beobachteter Ordner und Zeitpunkt des Starts (ältere Dateien zählen nicht)
    private var folderSource: DispatchSourceFileSystemObject?
    private var folderDescriptor: Int32 = -1
    private var watchedFolder: URL?
    private var startedAt = Date()

    init(store: ShelfStore, onAdded: @escaping () -> Void) {
        self.store = store
        self.onAdded = onAdded
        settingObserver = AppSettings.shared.$addScreenshots
            .removeDuplicates()
            .sink { [weak self] on in
                DispatchQueue.main.async { on ? self?.start() : self?.stop() }
            }
    }

    deinit { stop() }

    private func start() {
        guard query == nil else { return }
        startedAt = Date()
        watchFolder()
        let query = NSMetadataQuery()
        // Nur, was ab jetzt aufgenommen wird
        query.predicate = NSPredicate(format: "kMDItemIsScreenCapture == 1 AND kMDItemFSCreationDate >= %@",
                                      Date() as NSDate)
        query.searchScopes = [NSMetadataQueryLocalComputerScope]
        query.notificationBatchingInterval = 0.3
        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: .NSMetadataQueryDidFinishGathering, object: query, queue: .main) { [weak self] _ in
                // Was beim Start schon da ist, gilt als gesehen
                self?.markAllSeen()
            },
            center.addObserver(forName: .NSMetadataQueryDidUpdate, object: query, queue: .main) { [weak self] note in
                // macOS schreibt Bildschirmfotos erst unter verstecktem Namen und benennt sie
                // dann um: Spotlight meldet sie dann oft als geändert statt als neu
                let added = note.userInfo?[NSMetadataQueryUpdateAddedItemsKey] as? [NSMetadataItem] ?? []
                let changed = note.userInfo?[NSMetadataQueryUpdateChangedItemsKey] as? [NSMetadataItem] ?? []
                self?.take(added + changed)
            }
        ]
        self.query = query
        if !query.start() {
            Log.importing.error("Bildschirmfotos: Spotlight-Abfrage ließ sich nicht starten")
            Diagnostics.shared.failure("screenshots", "Spotlight-Abfrage ließ sich nicht starten")
            // Nur Spotlight aufgeben: Der Ordner wird weiter beobachtet (das ist der zweite Weg).
            // `query` bleibt gesetzt, damit `start` den Ordner nicht ein zweites Mal öffnet.
            observers.forEach(NotificationCenter.default.removeObserver)
            observers = []
        }
    }

    private func stop() {
        query?.stop()
        query = nil
        folderSource?.cancel()
        folderSource = nil
        watchedFolder = nil
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
    }

    private func markAllSeen() {
        guard let query else { return }
        query.disableUpdates()
        for case let item as NSMetadataItem in query.results {
            if let path = item.value(forAttribute: NSMetadataItemPathKey) as? String { seen.insert(path) }
        }
        query.enableUpdates()
    }

    private func take(_ items: [NSMetadataItem]) {
        let paths = items.compactMap { $0.value(forAttribute: NSMetadataItemPathKey) as? String }
        add(paths.map { URL(fileURLWithPath: $0) })
    }

    // MARK: Ordner der Bildschirmfotos

    /// Wo macOS Bildschirmfotos speichert: eingestellter Ort, sonst der Schreibtisch
    static func screenshotFolder() -> URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        if let location = UserDefaults(suiteName: "com.apple.screencapture")?.string(forKey: "location"),
           !location.isEmpty {
            let url = URL(fileURLWithPath: (location as NSString).expandingTildeInPath, isDirectory: true)
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue { return url }
        }
        return home.appendingPathComponent("Desktop", isDirectory: true)
    }

    /// Beobachtet den Ordner der Bildschirmfotos auf neue Dateien
    private func watchFolder() {
        let folder = Self.screenshotFolder()
        let fd = open(folder.path, O_EVTONLY)
        guard fd >= 0 else {
            Log.importing.error("Bildschirmfotos: Ordner nicht lesbar (\(folder.path, privacy: .private))")
            Diagnostics.shared.failure("screenshots", "Ordner nicht lesbar \(Diagnostics.anon(folder)) errno=\(errno) \(String(cString: strerror(errno)))")
            return
        }
        folderDescriptor = fd
        watchedFolder = folder
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: .write, queue: .main)
        source.setEventHandler { [weak self] in self?.folderChanged() }
        source.setCancelHandler { close(fd) }
        folderSource = source
        source.resume()
        Log.importing.info("Bildschirmfotos: beobachte Ordner")
    }

    /// Etwas im Ordner hat sich geändert: kurz danach nachsehen (macOS setzt die Kennzeichnung
    /// als Bildschirmfoto erst nach dem Umbenennen)
    private func folderChanged() {
        for delay in [0.3, 1.2, 3.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in self?.scanFolder() }
        }
    }

    private func scanFolder() {
        guard let folder = watchedFolder else { return }
        let keys: [URLResourceKey] = [.creationDateKey, .isRegularFileKey]
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys,
                                                                  options: [.skipsHiddenFiles])) ?? []
        let fresh = files.filter { url in
            guard !seen.contains(url.path),
                  let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true,
                  let created = values.creationDate, created >= startedAt.addingTimeInterval(-1) else { return false }
            return Self.isScreenCapture(url)
        }
        add(fresh)
    }

    /// Von macOS als Bildschirmfoto gekennzeichnet (dasselbe Merkmal, das Spotlight liest)
    static func isScreenCapture(_ url: URL) -> Bool {
        let name = "com.apple.metadata:kMDItemIsScreenCapture"
        return getxattr(url.path, name, nil, 0, 0, 0) > 0
    }

    // MARK: Übernehmen

    private func add(_ candidates: [URL]) {
        let urls = candidates.filter { url in
            guard !seen.contains(url.path), FileManager.default.fileExists(atPath: url.path) else { return false }
            seen.insert(url.path)
            return true
        }
        guard !urls.isEmpty, AppSettings.shared.addScreenshots else { return }
        Log.importing.info("\(urls.count, privacy: .public) Bildschirmfoto(s) übernommen")
        // Derselbe Weg wie beim Ablegen aus dem Finder
        pasteboard.clearContents()
        pasteboard.writeObjects(urls as [NSURL])
        store.ingest(from: pasteboard) { [weak self] files in
            if !files.isEmpty { self?.onAdded() }
        }
    }
}
