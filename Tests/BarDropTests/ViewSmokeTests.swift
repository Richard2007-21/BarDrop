import XCTest
import SwiftUI
import AppKit
@testable import BarDrop

/// Baut und zeichnet jede Einstellungsseite und die offene Ablage einmal, in beiden
/// Sprachen und mit den Einstellungen, die den Aufbau verändern. Findet Abstürze und
/// Laufzeitfehler in den Ansichten, ohne dass jemand die App öffnen muss.
@MainActor
final class ViewSmokeTests: XCTestCase {
    private var base: URL!
    private var saved: [String: Any] = [:]
    private let keys = ["language", "twoActionRows", "pinFromShelf", "excludedApps", "openMode", "showTitle"]

    override func setUp() async throws {
        try await super.setUp()
        base = FileManager.default.temporaryDirectory.appendingPathComponent("BarDropViews-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        for key in keys {
            if let value = UserDefaults.standard.object(forKey: key) { saved[key] = value }
        }
    }

    override func tearDown() async throws {
        let s = AppSettings.shared
        s.language = (saved["language"] as? String).flatMap(AppLanguage.init(rawValue:)) ?? .english
        s.twoActionRows = saved["twoActionRows"] as? Bool ?? false
        s.pinFromShelf = saved["pinFromShelf"] as? Bool ?? false
        s.excludedApps = saved["excludedApps"] as? [String] ?? []
        s.openMode = (saved["openMode"] as? String).flatMap(OpenMode.init(rawValue:)) ?? .automatic
        s.showTitle = saved["showTitle"] as? Bool ?? true
        try? FileManager.default.removeItem(at: base)
        try await super.tearDown()
    }

    /// Ansicht in einem Fenster auslegen und in ein Bild zeichnen
    /// Ist BARDROP_PREVIEW_DIR gesetzt (CI), wird jedes Bild dort als PNG abgelegt,
    /// damit man die Ansichten ansehen kann, ohne die App zu starten.
    private func render<V: View>(_ view: V, size: CGSize, _ name: String, appearance: NSAppearance.Name? = nil,
                                 file: StaticString = #filePath, line: UInt = #line) {
        let host = NSHostingView(rootView: view)
        if let appearance { host.appearance = NSAppearance(named: appearance) }
        host.frame = CGRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
            return XCTFail("\(name): kein Bild", file: file, line: line)
        }
        host.cacheDisplay(in: host.bounds, to: rep)
        XCTAssertGreaterThan(rep.pixelsWide, 0, name, file: file, line: line)
        if let dir = ProcessInfo.processInfo.environment["BARDROP_PREVIEW_DIR"], !dir.isEmpty,
           let png = rep.representation(using: .png, properties: [:]) {
            let safe = name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: " ", with: "_")
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            try? png.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(safe).png"))
        }
    }

    func testSettingsPagesRender() {
        let settings = AppSettings.shared
        let store = ShelfStore(baseDirectory: base)
        let size = CGSize(width: 520, height: 900)
        for language in [AppLanguage.english, .german] {
            settings.language = language
            for variant in [false, true] {
                settings.twoActionRows = variant
                settings.pinFromShelf = variant
                settings.showTitle = !variant
                settings.openMode = variant ? .click : .automatic
                settings.excludedApps = variant ? ["com.apple.finder", "example.missing.app"] : []
                let tag = "\(language.rawValue) \(variant)"
                render(GeneralSettings(settings: settings), size: size, "Allgemein \(tag)")
                render(OpeningSettings(settings: settings), size: size, "Öffnen \(tag)")
                render(AppearanceSettings(settings: settings), size: size, "Aussehen \(tag)")
                render(ItemSettings(settings: settings, store: store), size: size, "Objekte \(tag)")
                render(ActionSettings(settings: settings), size: size, "Aktionen \(tag)")
                render(KeyboardSettings(settings: settings), size: size, "Tastatur \(tag)")
                render(AboutSettings(settings: settings, showOnboarding: {}), size: size, "Über \(tag)")
            }
        }
    }

    func testIntroductionPagesRender() {
        _ = NSApplication.shared
        let settings = AppSettings.shared
        let sample = OnboardingController.makeSample()
        defer { if let sample { try? FileManager.default.removeItem(at: sample.deletingLastPathComponent()) } }
        for (language, appearance) in [(AppLanguage.german, NSAppearance.Name.darkAqua),
                                       (.english, .darkAqua), (.german, .aqua)] {
            settings.language = language
            let model = OnboardingModel(settings: settings, sampleURL: sample)
            model.onFinish = { _ in }
            for step in OnboardingModel.Step.allCases {
                model.go(to: step)
                render(OnboardingView(model: model, openSettings: {}),
                       size: OnboardingController.size,
                       "Einführung \(language.rawValue) \(appearance == .aqua ? "hell" : "dunkel") \(step.rawValue) \(step)",
                       appearance: appearance)
            }
            XCTAssertEqual(model.step, .features)
        }
    }

    /// Das Fenster der Einführung hat eine feste Größe. Keine Seite darf mehr Platz
    /// verlangen, sonst wächst das Fenster (NSHostingView übernimmt Mindestgröße und
    /// gewünschte Größe der Ansicht).
    func testIntroductionFitsWindow() {
        _ = NSApplication.shared
        let settings = AppSettings.shared
        let sample = OnboardingController.makeSample()
        defer { if let sample { try? FileManager.default.removeItem(at: sample.deletingLastPathComponent()) } }
        let model = OnboardingModel(settings: settings, sampleURL: sample)
        model.onFinish = { _ in }
        for edge in ScreenEdge.allCases {
            settings.edge = edge
            for step in OnboardingModel.Step.allCases {
                model.go(to: step)
                let host = NSHostingView(rootView: OnboardingView(model: model, openSettings: {}))
                let fitting = host.fittingSize
                let intrinsic = host.intrinsicContentSize
                let size = OnboardingController.size
                XCTAssertLessThanOrEqual(fitting.height, size.height, "\(step) \(edge): fitting \(fitting), intrinsic \(intrinsic)")
                XCTAssertLessThanOrEqual(fitting.width, size.width, "\(step) \(edge): fitting \(fitting), intrinsic \(intrinsic)")
                if intrinsic.height != NSView.noIntrinsicMetric {
                    XCTAssertLessThanOrEqual(intrinsic.height, size.height, "\(step) \(edge): intrinsic \(intrinsic)")
                }
            }
        }
        settings.edge = .right
    }

    func testOpenShelfRenders() throws {
        let settings = AppSettings.shared
        let store = ShelfStore(baseDirectory: base)
        let ui = ShelfUIModel()
        let actions = ShelfActions(store: store, ui: ui, settings: settings)

        // Ein paar Dateien des Nutzers, zwei davon als Stapel
        let files = try (1...5).map { i -> ShelfFile in
            let url = base.appendingPathComponent("Datei \(i).txt")
            try Data("\(i)".utf8).write(to: url)
            return ShelfFile(url: url, owned: false)
        }
        store.add(Array(files.prefix(3)))
        store.add(Array(files.suffix(2)))

        ui.level = .expanded
        for variant in [false, true] {
            settings.twoActionRows = variant
            settings.showTitle = variant
            render(ShelfRootView(ui: ui, store: store, settings: settings, actions: actions),
                   size: CGSize(width: 420, height: 720), "Ablage \(variant)")
        }
        // Geöffneter Stapel
        if let stack = store.entries.first(where: \.isStack) {
            ui.openStack = stack.id
            render(ShelfRootView(ui: ui, store: store, settings: settings, actions: actions),
                   size: CGSize(width: 420, height: 720), "Stapel")
        }
    }
}
