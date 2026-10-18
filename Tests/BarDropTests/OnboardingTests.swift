import XCTest
import AppKit
@testable import BarDrop

/// Einführung: was beim Abschluss mit „Beim Anmelden öffnen“ geschieht.
final class OnboardingTests: XCTestCase {
    private func change(completed: Bool, wanted: Bool, rerun: Bool, enabled: Bool) -> OnboardingModel.LoginItemChange? {
        OnboardingModel.loginItemChange(completed: completed, wanted: wanted, isRerun: rerun, enabled: enabled)
    }

    func testFirstLaunchRegistersWhenWantedLikeBefore() {
        XCTAssertEqual(change(completed: true, wanted: true, rerun: false, enabled: false), .register)
        XCTAssertNil(change(completed: true, wanted: false, rerun: false, enabled: false))
        XCTAssertEqual(change(completed: true, wanted: false, rerun: false, enabled: true), .unregister,
                       "Ab dem ersten Start angemeldet: in der Einführung ausgeschaltet heißt abmelden")
    }

    func testRerunUnregistersWhenSwitchedOff() {
        XCTAssertEqual(change(completed: true, wanted: false, rerun: true, enabled: true), .unregister)
        XCTAssertNil(change(completed: true, wanted: true, rerun: true, enabled: true), "Schon angemeldet")
        XCTAssertEqual(change(completed: true, wanted: true, rerun: true, enabled: false), .register)
        XCTAssertNil(change(completed: true, wanted: false, rerun: true, enabled: false), "Schon abgemeldet")
    }

    func testSkippingOrClosingChangesNothing() {
        for wanted in [true, false] {
            for rerun in [true, false] {
                for enabled in [true, false] {
                    XCTAssertNil(change(completed: false, wanted: wanted, rerun: rerun, enabled: enabled))
                }
            }
        }
    }
}

/// Beispieldatei der Einführung: Sprachwechsel auf der ersten Seite und Aufräumen am Ende.
final class OnboardingSampleTests: XCTestCase {
    private var base: URL!
    private var language: AppLanguage!
    private var didLaunchBefore = false

    override func setUp() {
        super.setUp()
        // Die Beispieldatei zeichnet das App-Symbol über NSApp; im Testprozess gibt es
        // die App sonst noch nicht
        _ = NSApplication.shared
        base = FileManager.default.temporaryDirectory.appendingPathComponent("BarDropIntro-\(UUID().uuidString)")
        language = AppSettings.shared.language
        didLaunchBefore = AppSettings.shared.didLaunchBefore
        AppSettings.shared.stackMultiple = true
        AppSettings.shared.stackThreshold = 2
    }

    override func tearDown() {
        AppSettings.shared.language = language
        AppSettings.shared.didLaunchBefore = didLaunchBefore
        try? FileManager.default.removeItem(at: base)
        super.tearDown()
    }

    /// Legt eine Datei so in die Ablage, wie es das Ziehen aus der Einführung tut.
    private func drop(_ urls: [URL], into store: ShelfStore) {
        let pb = NSPasteboard(name: NSPasteboard.Name("BarDropIntro-\(UUID().uuidString)"))
        defer { pb.releaseGlobally() }
        pb.clearContents()
        pb.writeObjects(urls as [NSURL])
        let done = expectation(description: "Ingest")
        store.ingest(from: pb) { _ in done.fulfill() }
        wait(for: [done], timeout: 10)
        // Die Einführung beobachtet die Ablage über den Hauptthread
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
    }

    func testSampleIsRemovedUnderItsNameAfterLanguageChange() throws {
        let settings = AppSettings.shared
        settings.language = .english
        let store = ShelfStore(baseDirectory: base)
        let controller = OnboardingController(store: store, ui: ShelfUIModel(), settings: settings)
        let model = controller.model
        XCTAssertEqual(model.sampleURL?.lastPathComponent, "Photo.jpg")

        // Sprache auf der ersten Seite wechseln, dann zum Schritt „Ablegen“
        settings.language = .german
        model.go(to: .drop)
        let sample = try XCTUnwrap(model.sampleURL)
        XCTAssertEqual(sample.lastPathComponent, "Foto.jpg")
        XCTAssertTrue(FileManager.default.fileExists(atPath: sample.path))

        // Ablegen und eine eigene Datei dazulegen (Stapel)
        drop([sample], into: store)
        XCTAssertEqual(store.entries.count, 1)
        XCTAssertEqual(store.entries[0].files[0].url.lastPathComponent, "Foto.jpg")
        let own = base.appendingPathComponent("eigen.txt")
        try Data("meins".utf8).write(to: own)
        let pb = NSPasteboard(name: NSPasteboard.Name("BarDropIntro-\(UUID().uuidString)"))
        defer { pb.releaseGlobally() }
        pb.clearContents()
        pb.writeObjects([own] as [NSURL])
        let done = expectation(description: "Dazulegen")
        store.ingest(from: pb, into: store.entries[0].id) { _ in done.fulfill() }
        wait(for: [done], timeout: 10)
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        XCTAssertEqual(store.entries.count, 1)
        XCTAssertEqual(store.entries[0].files.count, 2)

        // Schließen ohne „Fertig“: nur die Beispieldatei verschwindet
        model.onFinish(false)
        XCTAssertEqual(store.entries.count, 1)
        XCTAssertEqual(store.entries[0].files.map(\.url.lastPathComponent), ["eigen.txt"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: sample.deletingLastPathComponent().path),
                       "Temporärer Ordner der Beispieldatei ist weg")
    }

    func testSampleKeepsItsNameWithoutLanguageChange() {
        AppSettings.shared.language = .german
        let controller = OnboardingController(store: ShelfStore(baseDirectory: base), ui: ShelfUIModel(),
                                              settings: AppSettings.shared)
        let before = controller.model.sampleURL
        controller.model.go(to: .drop)
        XCTAssertEqual(controller.model.sampleURL, before)
        controller.model.onFinish(false)
    }
}
