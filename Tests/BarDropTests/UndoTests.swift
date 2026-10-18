import XCTest
import AppKit
@testable import BarDrop

/// Entfernen widerrufen und wiederholen, eigene Dateien bleiben bis dahin erhalten.
final class UndoTests: XCTestCase {
    private var base: URL!
    private var store: ShelfStore!

    override func setUp() {
        super.setUp()
        base = FileManager.default.temporaryDirectory.appendingPathComponent("BarDropUndo-\(UUID().uuidString)")
        AppSettings.shared.stackMultiple = true
        AppSettings.shared.stackThreshold = 2
        store = ShelfStore(baseDirectory: base)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: base)
        super.tearDown()
    }

    /// Legt eine eigene Datei (wie ein Bild aus dem Web) und eine Datei des Nutzers ab.
    private func addFiles() -> (owned: ShelfFile, user: ShelfFile) {
        let items = base.appendingPathComponent("Items/\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: items, withIntermediateDirectories: true)
        let ownedURL = items.appendingPathComponent("Bild.png")
        try? Data("bild".utf8).write(to: ownedURL)
        let userDir = base.appendingPathComponent("Nutzer")
        try? FileManager.default.createDirectory(at: userDir, withIntermediateDirectories: true)
        let userURL = userDir.appendingPathComponent("Notiz.txt")
        try? Data("notiz".utf8).write(to: userURL)
        let owned = ShelfFile(url: ownedURL, owned: true)
        let user = ShelfFile(url: userURL, owned: false)
        AppSettings.shared.stackMultiple = false
        store.add([owned, user])
        AppSettings.shared.stackMultiple = true
        return (owned, user)
    }

    func testUndoRestoresEntriesInPlace() {
        let (owned, _) = addFiles()
        let order = store.entries.map(\.id)
        XCTAssertEqual(order.count, 2)

        store.remove([order[0]])
        XCTAssertEqual(store.entries.count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: owned.url.path), "Eigene Datei bleibt bis zum Verfall")

        store.undoManager.undo()
        XCTAssertEqual(store.entries.map(\.id), order, "Eintrag kommt an seine alte Stelle zurück")

        store.undoManager.redo()
        XCTAssertEqual(store.entries.count, 1)

        store.undoManager.undo()
        XCTAssertEqual(store.entries.map(\.id), order)
    }

    func testRemoveAllIsUndoable() {
        _ = addFiles()
        let order = store.entries.map(\.id)
        store.removeAll()
        XCTAssertTrue(store.entries.isEmpty)
        store.undoManager.undo()
        XCTAssertEqual(store.entries.map(\.id), order)
    }

    func testExpiredRemovalDeletesHeldFiles() {
        let (owned, user) = addFiles()
        store.removeAll()
        store.discardUndoHistory()
        XCTAssertFalse(store.undoManager.canUndo)
        let gone = expectation(description: "Datei gelöscht")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            XCTAssertFalse(FileManager.default.fileExists(atPath: owned.url.path), "Eigene Datei wird gelöscht")
            XCTAssertTrue(FileManager.default.fileExists(atPath: user.url.path), "Datei des Nutzers bleibt")
            gone.fulfill()
        }
        wait(for: [gone], timeout: 3)
    }

    /// Automatisches Entfernen belegt ⌘Z nicht; eigene Dateien bleiben noch 15 Minuten
    func testAutomaticRemovalIsNotUndoable() {
        let (owned, _) = addFiles()
        Thread.sleep(forTimeInterval: 0.05)
        store.removeExpired(olderThan: 0.01)    // alles gilt als abgelaufen
        XCTAssertTrue(store.entries.isEmpty)
        XCTAssertFalse(store.undoManager.canUndo)
        XCTAssertTrue(FileManager.default.fileExists(atPath: owned.url.path), "Eigene Datei bleibt noch erhalten")
    }

    /// Papierkorb wie im Finder: ⌘Z legt die Datei an ihren alten Ort und in die Ablage zurück
    func testTrashIsUndoable() throws {
        let (_, user) = addFiles()
        let trashed = expectation(description: "Papierkorb")
        var count = 0
        store.moveToTrash([user.url]) { n in
            count = n
            trashed.fulfill()
        }
        wait(for: [trashed], timeout: 15)
        try XCTSkipIf(count == 0, "Kein Papierkorb in dieser Umgebung")
        XCTAssertFalse(FileManager.default.fileExists(atPath: user.url.path), "Datei liegt im Papierkorb")
        XCTAssertFalse(store.entries.flatMap(\.files).contains { $0.id == user.id })
        XCTAssertTrue(store.undoManager.canUndo)

        let restored = store.undoLast()
        XCTAssertTrue(restored.contains(user.id))
        XCTAssertTrue(FileManager.default.fileExists(atPath: user.url.path), "Datei wieder an ihrem Ort")
        XCTAssertTrue(store.entries.flatMap(\.files).contains { $0.id == user.id })
    }

    /// Direkt aus dem Finder auf die Aktion Papierkorb: ⌘Z legt zurück und in die Ablage
    func testTrashFromFinderIsUndoable() throws {
        let dir = base.appendingPathComponent("Finder")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("Brief.txt")
        try Data("brief".utf8).write(to: file)
        let done = expectation(description: "Papierkorb")
        var count = 0
        store.moveToTrash([file]) { n in count = n; done.fulfill() }
        wait(for: [done], timeout: 15)
        try XCTSkipIf(count == 0, "Kein Papierkorb in dieser Umgebung")
        XCTAssertTrue(store.undoManager.canUndo)
        _ = store.undoLast()
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path), "Wieder an seinem Ort")
        XCTAssertTrue(store.entries.flatMap(\.urls).contains { $0.standardizedFileURL == file.standardizedFileURL },
                      "Und in der Ablage")
    }

    func testFolderOperationLikeFinder() {
        let (_, user) = addFiles()
        let folder = base.appendingPathComponent("Ziel")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        XCTAssertEqual(ShelfActions.folderOperation(for: user.url, into: folder, modifiers: []), .move,
                       "Dieselbe Platte: verschieben")
        XCTAssertEqual(ShelfActions.folderOperation(for: user.url, into: folder, modifiers: .option), .copy,
                       "⌥ kopiert immer")
        XCTAssertEqual(ShelfActions.folderOperation(for: user.url, into: folder, modifiers: .command), .move,
                       "⌘ verschiebt immer")
    }

    func testSystemLanguageFallsBackToEnglish() {
        XCTAssertEqual(AppLanguage.systemLanguage(preferred: ["de-DE", "en-US"]), .german)
        XCTAssertEqual(AppLanguage.systemLanguage(preferred: ["fr-FR"]), .english)
        XCTAssertEqual(AppLanguage.systemLanguage(preferred: ["fr-FR", "de-AT"]), .german, "Wie macOS: erste Sprache, die BarDrop kann")
        XCTAssertEqual(AppLanguage.systemLanguage(preferred: []), .english)
        XCTAssertNotEqual(AppLanguage.system.resolved, .system)
    }

    func testOldestFirstReversesDisplayOrder() {
        _ = addFiles()
        let ui = ShelfUIModel()
        let actions = ShelfActions(store: store, ui: ui, settings: AppSettings.shared)
        let previous = AppSettings.shared.sortOrder
        defer { AppSettings.shared.sortOrder = previous }
        AppSettings.shared.sortOrder = .newestFirst
        let newest = actions.orderedEntries.map(\.id)
        AppSettings.shared.sortOrder = .oldestFirst
        XCTAssertEqual(actions.orderedEntries.map(\.id), newest.reversed())
    }
}
