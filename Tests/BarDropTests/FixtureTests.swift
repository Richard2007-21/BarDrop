import XCTest
@testable import BarDrop

/// Gespeicherte Ablagen aller veröffentlichten Versionen ab 1.26 (Tests/Fixtures) müssen
/// sich vollständig lesen lassen. Fällt hier ein Eintrag weg, hat eine Änderung an
/// `ShelfFile` oder `ShelfEntry` ein Pflichtfeld eingeführt (siehe README, Entwicklung).
final class FixtureTests: XCTestCase {
    private var base: URL!

    override func setUp() {
        super.setUp()
        base = FileManager.default.temporaryDirectory.appendingPathComponent("BarDropFixtures-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: base)
        super.tearDown()
    }

    private static var fixturesDirectory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()        // BarDropTests
            .deletingLastPathComponent()        // Tests
            .appendingPathComponent("Fixtures", isDirectory: true)
    }

    private static func fixtures() throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: fixturesDirectory, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("shelf-") && $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// Die Fixtures nennen statt eines echten Orts `__ROOT__`: hier durch einen Testordner ersetzen.
    private func materialize(_ fixture: URL) throws -> (data: Data, root: URL) {
        let root = base.appendingPathComponent(fixture.deletingPathExtension().lastPathComponent, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let text = try String(contentsOf: fixture, encoding: .utf8)
            .replacingOccurrences(of: "__ROOT__", with: root.path.replacingOccurrences(of: "/", with: "\\/"))
        return (Data(text.utf8), root)
    }

    func testFixturesCoverEveryVersionSince126() throws {
        let names = Set(try Self.fixtures().map(\.lastPathComponent))
        for version in ["1.26.0", "1.27.0", "1.28.1", "1.29.0", "1.30.0-beta.1", "1.30.0-beta.2", "1.30.0-beta.5"] {
            XCTAssertTrue(names.contains("shelf-\(version).json"), "Fixture fehlt: \(version)")
        }
    }

    /// Jeder Eintrag jeder Fixture ist lesbar, streng ohne den nachsichtigen Leser der Ablage.
    func testEveryEntryOfEveryReleaseDecodes() throws {
        for fixture in try Self.fixtures() {
            let (data, _) = try materialize(fixture)
            let raw = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [Any], fixture.lastPathComponent)
            XCTAssertFalse(raw.isEmpty, fixture.lastPathComponent)
            XCTAssertNoThrow(try JSONDecoder().decode([ShelfEntry].self, from: data),
                             "\(fixture.lastPathComponent): mindestens ein Eintrag ist unlesbar")
            let decoded = (try? JSONDecoder().decode([ShelfEntry].self, from: data)) ?? []
            XCTAssertEqual(decoded.count, raw.count, fixture.lastPathComponent)
        }
    }

    /// Die Ablage lädt jede Fixture ohne Verlust: gleiche Einträge, gleiche Dateien,
    /// Lesezeichen und Original von Kopien bleiben erhalten, keine Sicherung entsteht.
    func testStoreLoadsEveryReleaseWithoutLoss() throws {
        for fixture in try Self.fixtures() {
            let name = fixture.lastPathComponent
            let (data, root) = try materialize(fixture)
            let expected = try JSONDecoder().decode([ShelfEntry].self, from: data)

            // Alle genannten Dateien anlegen, wie sie auf dem Mac lägen
            for file in expected.flatMap(\.files) {
                try FileManager.default.createDirectory(at: file.url.deletingLastPathComponent(),
                                                        withIntermediateDirectories: true)
                try Data("Inhalt".utf8).write(to: file.url)
            }
            let storeDir = root.appendingPathComponent("Support/BarDrop", isDirectory: true)
            try FileManager.default.createDirectory(at: storeDir, withIntermediateDirectories: true)
            try data.write(to: storeDir.appendingPathComponent("shelf.json"))

            let store = ShelfStore(baseDirectory: storeDir)
            XCTAssertEqual(store.entries.map(\.id), expected.map(\.id), name)
            XCTAssertEqual(store.entries.flatMap(\.files).map(\.id), expected.flatMap(\.files).map(\.id), name)
            XCTAssertEqual(store.entries.flatMap(\.files).map(\.owned), expected.flatMap(\.files).map(\.owned), name)
            XCTAssertEqual(store.entries.flatMap(\.files).map { $0.originBookmark != nil },
                           expected.flatMap(\.files).map { $0.originBookmark != nil }, name)
            XCTAssertEqual(store.entries.map(\.added), expected.map(\.added), name)
            let backups = try FileManager.default.contentsOfDirectory(atPath: storeDir.path)
                .filter { $0.hasPrefix("shelf-unlesbar-") }
            XCTAssertTrue(backups.isEmpty, "\(name): Liste galt als unlesbar")
            for file in expected.flatMap(\.files) where file.owned {
                XCTAssertTrue(FileManager.default.fileExists(atPath: file.url.path), "\(name): eigene Datei aufgeräumt")
            }
        }
    }
}
