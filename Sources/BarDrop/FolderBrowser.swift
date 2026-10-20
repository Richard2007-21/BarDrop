import AppKit
import CryptoKit
import SwiftUI

/// Inhalt eines angehefteten Ordners, in der Ablage gezeigt wie ein geöffneter Stapel.
///
/// Die Dateien bleiben, wo sie sind: Verschieben, Papierkorb und Hineinziehen wirken wie
/// im Finder auf den echten Ordner. Ändert sich der Ordner (Finder, Downloads, eigene
/// Aktionen), zieht die Ansicht sofort nach.
final class FolderBrowser: ObservableObject {
    /// Steht in `ShelfUIModel.openStack`, solange ein Ordner offen ist
    static let entryID = UUID(uuidString: "B0D0F01D-0000-4000-8000-000000000001")!

    /// Angehefteter Ordner, mit dem es losging
    @Published private(set) var root: URL?
    /// Gerade gezeigter Ordner: der angeheftete oder ein Unterordner davon
    @Published private(set) var folder: URL?
    /// Inhalt, neueste zuerst (wie die Ablage)
    @Published private(set) var files: [ShelfFile] = []
    /// Wird noch gelesen (großer Ordner, Netzlaufwerk): noch nicht „leer“ zeigen
    @Published private(set) var isLoading = false

    /// Der Ordner ist verschwunden (gelöscht, Laufwerk abgezogen): Ansicht schließen
    var onVanished: () -> Void = {}

    private var watcher: DispatchSourceFileSystemObject?
    private var reloadWork: DispatchWorkItem?
    private var generation = 0
    private let queue = DispatchQueue(label: "io.github.zzuuuiii.bardrop.folder", qos: .userInitiated)

    var isOpen: Bool { folder != nil }

    /// Der Inhalt als Eintrag, damit die Ansicht des Stapels ihn zeigen kann
    var entry: ShelfEntry {
        var entry = ShelfEntry(files: files)
        entry.id = Self.entryID
        return entry
    }

    var name: String { folder.map { Self.displayName($0) } ?? "" }

    /// In einem Unterordner des angehefteten Ordners
    var isNested: Bool {
        guard let folder, let root else { return false }
        return folder.standardizedFileURL != root.standardizedFileURL
    }

    /// Name des Ordners, zu dem „Zurück“ führt; nil: zurück zur Ablage
    var parentName: String? {
        guard isNested, let folder else { return nil }
        return Self.displayName(folder.deletingLastPathComponent())
    }

    static func displayName(_ url: URL) -> String {
        FileManager.default.displayName(atPath: url.path)
    }

    /// Ordner, in die man hineingehen kann (keine Pakete wie Apps)
    static func isBrowsable(_ url: URL) -> Bool {
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
        return values?.isDirectory == true && values?.isPackage != true
    }

    func open(_ url: URL) {
        root = url
        show(url)
    }

    /// In einen Unterordner hineingehen
    func enter(_ url: URL) {
        guard isOpen else { return }
        show(url)
    }

    /// Eine Ebene hoch; false, wenn schon der angeheftete Ordner zu sehen ist
    @discardableResult
    func goUp() -> Bool {
        guard isNested, let folder else { return false }
        show(folder.deletingLastPathComponent())
        return true
    }

    func close() {
        stopWatching()
        reloadWork?.cancel()
        generation += 1
        root = nil
        folder = nil
        files = []
        isLoading = false
    }

    private func show(_ url: URL) {
        folder = url
        files = []
        isLoading = true
        watch(url)
        reload(after: 0)
    }

    /// Neu lesen; mehrere Änderungen kurz hintereinander zählen als eine
    func reload(after delay: TimeInterval = 0.15) {
        reloadWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.load() }
        reloadWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func load() {
        guard let folder else { return }
        generation += 1
        let current = generation
        queue.async { [weak self] in
            let listed = Self.list(folder)
            DispatchQueue.main.async {
                guard let self, self.generation == current, self.folder == folder else { return }
                self.isLoading = false
                guard let listed else { return self.vanished() }
                guard listed != self.files else { return }
                withAnimation(.spring(response: 0.35, dampingFraction: 0.88)) { self.files = listed }
            }
        }
    }

    /// Gezeigter Ordner ist weg: zum nächsten noch vorhandenen darüber, sonst schließen
    private func vanished() {
        var candidate = folder?.deletingLastPathComponent()
        while isNested, let next = candidate, root.map({ next.path.hasPrefix($0.path) }) == true {
            if Self.isBrowsable(next) { return show(next) }
            candidate = next.deletingLastPathComponent()
        }
        close()
        onVanished()
    }

    /// Sichtbare Objekte des Ordners, neueste zuerst: wann sie in den Ordner kamen (wie
    /// „Hinzugefügt am“ im Finder), sonst erstellt bzw. geändert. nil: nicht lesbar.
    static func list(_ folder: URL) -> [ShelfFile]? {
        let keys: [URLResourceKey] = [.addedToDirectoryDateKey, .creationDateKey, .contentModificationDateKey]
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return nil }
        let dated = urls.map { url -> (url: URL, date: Date) in
            let values = try? url.resourceValues(forKeys: Set(keys))
            return (url, values?.addedToDirectoryDate ?? values?.creationDate
                         ?? values?.contentModificationDate ?? .distantPast)
        }
        return dated
            .sorted { a, b in
                if a.date != b.date { return a.date > b.date }
                return a.url.lastPathComponent.localizedStandardCompare(b.url.lastPathComponent) == .orderedAscending
            }
            .map { ShelfFile(listed: $0.url, id: id(for: $0.url)) }
    }

    /// Feste Kennung je Pfad: Auswahl und Kacheln bleiben beim Neulesen dieselben
    static func id(for url: URL) -> UUID {
        let digest = SHA256.hash(data: Data(url.standardizedFileURL.path.utf8))
        var bytes = Array(digest.prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return bytes.withUnsafeBytes { UUID(uuid: $0.load(as: uuid_t.self)) }
    }

    // MARK: Beobachten

    private func watch(_ url: URL) {
        stopWatching()
        let descriptor = Darwin.open(url.path, O_EVTONLY)
        guard descriptor >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .delete, .rename, .link, .attrib, .extend, .revoke],
            queue: .main)
        source.setEventHandler { [weak self] in self?.reload() }
        source.setCancelHandler { Darwin.close(descriptor) }
        source.resume()
        watcher = source
    }

    private func stopWatching() {
        watcher?.cancel()
        watcher = nil
    }

    deinit { watcher?.cancel() }
}
