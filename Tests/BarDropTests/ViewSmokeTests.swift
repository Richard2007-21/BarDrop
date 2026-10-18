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
    private let keys = ["language", "twoActionRows", "pinFromShelf", "excludedApps", "openMode", "titleStyle"]

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
        s.titleStyle = (saved["titleStyle"] as? String).flatMap(ShelfTitle.init(rawValue:)) ?? .bardrop
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

    /// Einstellungsseite auf der Fläche des Fensters wie in der App
    private func page<V: View>(_ view: V) -> some View {
        view.background(SettingsTheme.contentBackdrop)
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
                settings.titleStyle = variant ? .shelf : .bardrop
                settings.openMode = variant ? .click : .automatic
                settings.excludedApps = variant ? ["com.apple.finder", "example.missing.app"] : []
                // Hell und dunkel, auf der Fläche des Fensters wie in der App
                for appearance in [NSAppearance.Name.aqua, .darkAqua] {
                    let tag = "\(language.rawValue) \(variant) \(appearance == .aqua ? "hell" : "dunkel")"
                    render(page(GeneralSettings(settings: settings)), size: size, "Allgemein \(tag)", appearance: appearance)
                    render(page(OpeningSettings(settings: settings)), size: size, "Öffnen \(tag)", appearance: appearance)
                    render(page(AppearanceSettings(settings: settings)), size: size, "Aussehen \(tag)", appearance: appearance)
                    render(page(ItemSettings(settings: settings, store: store)), size: size, "Objekte \(tag)", appearance: appearance)
                    render(page(ActionSettings(settings: settings)), size: size, "Aktionen \(tag)", appearance: appearance)
                    render(page(KeyboardSettings(settings: settings)), size: size, "Tastatur \(tag)", appearance: appearance)
                    render(page(AboutSettings(settings: settings, showOnboarding: {})), size: size, "Über \(tag)", appearance: appearance)
                }
            }
        }
    }

    func testIntroductionPagesRender() {
        _ = NSApplication.shared
        let settings = AppSettings.shared
        let sample = OnboardingController.makeSample()
        defer { if let sample { try? FileManager.default.removeItem(at: sample.deletingLastPathComponent()) } }
        for (language, appearance) in [(AppLanguage.german, NSAppearance.Name.darkAqua),
                                       (.english, .darkAqua), (.german, .aqua), (.english, .aqua)] {
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

    /// Das echte Fenster der Einführung (Titelleiste, Werkzeugleiste, volle Inhaltsfläche):
    /// Es behält seine Größe, und die Ansicht füllt es ganz, auch unter der Titelleiste.
    func testIntroductionWindow() {
        _ = NSApplication.shared
        let settings = AppSettings.shared
        let controller = OnboardingController(store: ShelfStore(baseDirectory: base),
                                              ui: ShelfUIModel(), settings: settings)
        let window = controller.makeWindow()
        defer { window.orderOut(nil) }
        for step in OnboardingModel.Step.allCases {
            controller.model.go(to: step)
            window.contentView?.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.2))
            XCTAssertEqual(window.contentLayoutRect.width, OnboardingController.size.width, accuracy: 1, "\(step)")
            XCTAssertEqual(window.frame.height, window.frameRect(forContentRect: NSRect(origin: .zero, size: OnboardingController.size)).height,
                           accuracy: 1, "\(step): Fenster ist gewachsen")
            guard let view = window.contentView,
                  let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return XCTFail("kein Bild") }
            view.cacheDisplay(in: view.bounds, to: rep)
            if let dir = ProcessInfo.processInfo.environment["BARDROP_PREVIEW_DIR"], !dir.isEmpty,
               let png = rep.representation(using: .png, properties: [:]) {
                try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
                try? png.write(to: URL(fileURLWithPath: dir).appendingPathComponent("Fenster_\(step.rawValue)_\(step).png"))
            }
        }
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
        for (variant, title) in [(false, ShelfTitle.shelf), (true, .bardrop), (true, .hidden)] {
            settings.twoActionRows = variant
            settings.titleStyle = title
            render(ShelfRootView(ui: ui, store: store, settings: settings, actions: actions),
                   size: CGSize(width: 420, height: 720), "Ablage \(variant) \(title.rawValue)")
        }
        // Geöffneter Stapel
        if let stack = store.entries.first(where: \.isStack) {
            ui.openStack = stack.id
            render(ShelfRootView(ui: ui, store: store, settings: settings, actions: actions),
                   size: CGSize(width: 420, height: 720), "Stapel")
        }
    }

    /// Bilder für die Produktseite auf GitHub: die echte Ablage mit echten Dateien und
    /// Vorschaubildern, die echten Einstellungen und die Einführung, in doppelter Auflösung
    /// mit durchsichtigem Hintergrund. Nur mit BARDROP_PREVIEW_DIR.
    func testProductShots() async throws {
        guard let dir = ProcessInfo.processInfo.environment["BARDROP_PREVIEW_DIR"], !dir.isEmpty else {
            throw XCTSkip("Nur in CI")
        }
        let settings = AppSettings.shared
        let saved = (settings.tileIconSize, settings.shelfHeight, settings.shelfWidth, settings.language,
                     settings.showOutline, settings.edge)
        defer {
            settings.tileIconSize = saved.0; settings.shelfHeight = saved.1; settings.shelfWidth = saved.2
            settings.language = saved.3; settings.showOutline = saved.4; settings.edge = saved.5
        }
        settings.tileIconSize = 64
        settings.showOutline = true
        settings.edge = .right

        for language in [AppLanguage.english, .german] {
            settings.language = language
            let lang = language.rawValue
            let files = base.appendingPathComponent("Produkt-\(lang)")
            try FileManager.default.createDirectory(at: files, withIntermediateDirectories: true)
            let examples = Self.productFiles(in: files)

            let store = ShelfStore(baseDirectory: base.appendingPathComponent("Store-\(lang)"))
            let ui = ShelfUIModel()
            let actions = ShelfActions(store: store, ui: ui, settings: settings)
            settings.stackMultiple = false
            store.add(examples.singles.reversed().map { ShelfFile(url: $0, owned: false) })
            // Vorschaubilder vorab laden: Die Kacheln zeigen sie dann sofort
            for url in examples.singles + examples.stack {
                _ = await Thumbnails.load(url, size: 64)
                Thumbnails.shownOnce.insert(url.path)
            }
            ui.level = .expanded
            ui.isKey = true

            // 1. Ablage mit sechs Objekten, eines ausgewählt
            settings.shelfWidth = 300
            settings.shelfHeight = 400
            ui.expandedBody = CGRect(x: 0, y: 0, width: 300, height: 400)
            ui.selection = Set(store.entries.dropFirst(1).prefix(1).map(\.id))
            shot(ShelfRootView(ui: ui, store: store, settings: settings, actions: actions),
                 size: CGSize(width: 440, height: 600), "Produkt Ablage \(lang)", dir: dir)

            // Aktion im Einsatz: eine Datei liegt über der Ordner-Aktion
            ui.selection = []
            ui.previewTargetedAction = settings.quickActions.first { $0.kind == .folder }?.id
            shot(ShelfRootView(ui: ui, store: store, settings: settings, actions: actions),
                 size: CGSize(width: 440, height: 600), "Produkt Aktion \(lang)", dir: dir)
            ui.previewTargetedAction = nil
            ui.selection = Set(store.entries.dropFirst(1).prefix(1).map(\.id))

            // Für das Vorschau-GIF: ohne Auswahl, mit und ohne den See, und leer
            if language == .english {
                ui.selection = []
                ui.showSampleTile = false
                let lake = store.entries.first { $0.urls.first?.lastPathComponent == "Lake.jpg" }
                shot(ShelfRootView(ui: ui, store: store, settings: settings, actions: actions),
                     size: CGSize(width: 440, height: 600), "Produkt GIF mit", dir: dir)
                if let lake {
                    let fresh = ShelfStore(baseDirectory: base.appendingPathComponent("GIF"))
                    fresh.add(store.entries.reversed().filter { $0.id != lake.id }.flatMap(\.files))
                    let freshActions = ShelfActions(store: fresh, ui: ui, settings: settings)
                    shot(ShelfRootView(ui: ui, store: fresh, settings: settings, actions: freshActions),
                         size: CGSize(width: 440, height: 600), "Produkt GIF ohne", dir: dir)
                    fresh.add(lake.files)
                    shot(ShelfRootView(ui: ui, store: fresh, settings: settings, actions: freshActions),
                         size: CGSize(width: 440, height: 600), "Produkt GIF oben", dir: dir)
                }
            }

            // Zweites Vorschau-GIF: Fotos als Stapel ablegen, eines in eine Präsentation ziehen,
            // eine Notiz in den Papierkorb und alles zurück (echter Kreislauf)
            if language == .english {
                let gifStore = ShelfStore(baseDirectory: base.appendingPathComponent("GIF2"))
                let gifActions = ShelfActions(store: gifStore, ui: ui, settings: settings)
                let byName = Dictionary((examples.singles + examples.stack).map { ($0.lastPathComponent, $0) },
                                        uniquingKeysWith: { a, _ in a })
                let old = ["Notes.txt", "Trip.pdf", "Chart.png"].compactMap { byName[$0] }
                let photos = examples.stack
                for url in photos {
                    try? FileManager.default.copyItem(at: url, to: URL(fileURLWithPath: dir)
                        .appendingPathComponent("GIF2 " + url.lastPathComponent).deletingPathExtension()
                        .appendingPathExtension("jpg"))
                }
                settings.stackMultiple = false
                gifStore.add(old.reversed().map { ShelfFile(url: $0, owned: false) })
                settings.stackMultiple = true
                settings.stackThreshold = 2
                TrashState.shared.isFull = false
                ui.selection = []
                ui.openStack = nil
                ui.memberSelection = []
                func gif(_ name: String) {
                    shot(ShelfRootView(ui: ui, store: gifStore, settings: settings, actions: gifActions),
                         size: CGSize(width: 440, height: 600), "GIF2 \(name)", dir: dir)
                }
                gif("0")
                ui.isDropTargeted = true
                gif("0 drop")
                ui.isDropTargeted = false
                gifStore.add(photos.map { ShelfFile(url: $0, owned: false) })
                gif("1")
                if let stack = gifStore.entries.first(where: \.isStack) {
                    ui.openStack = stack.id
                    gif("2")
                    ui.memberSelection = Set(stack.files.dropFirst().prefix(1).map(\.id))
                    gif("2 sel")
                    ui.memberSelection = []
                    gifStore.forgetFiles(at: [photos[1]])
                    gif("3")
                    ui.openStack = nil
                    gif("4")
                    ui.selection = Set(gifStore.entries.filter { $0.urls.first?.lastPathComponent == "Notes.txt" }.map(\.id))
                    gif("4 notes")
                    ui.selection = []
                    ui.previewTargetedAction = settings.quickActions.first { $0.kind == .trash }?.id
                    gif("4 trash")
                    ui.previewTargetedAction = nil
                    let withoutNotes = ShelfStore(baseDirectory: base.appendingPathComponent("GIF2b"))
                    settings.stackMultiple = false
                    withoutNotes.add(gifStore.entries.reversed().filter { $0.urls.first?.lastPathComponent != "Notes.txt" && !$0.isStack }.flatMap(\.files))
                    settings.stackMultiple = true
                    withoutNotes.add(gifStore.entries.filter(\.isStack).flatMap(\.files))
                    TrashState.shared.isFull = true
                    shot(ShelfRootView(ui: ui, store: withoutNotes, settings: settings,
                                       actions: ShelfActions(store: withoutNotes, ui: ui, settings: settings)),
                         size: CGSize(width: 440, height: 600), "GIF2 5", dir: dir)
                    TrashState.shared.isFull = false
                    if let restacked = gifStore.entries.first(where: \.isStack) {
                        ui.selection = [restacked.id]
                        gif("6 sel")
                    }
                    ui.selection = []
                }
                ui.openStack = nil
                settings.stackMultiple = false
            }

            // 2. Mit Stapel
            settings.stackMultiple = true
            settings.stackThreshold = 2
            store.add(examples.stack.map { ShelfFile(url: $0, owned: false) })
            ui.selection = Set(store.entries.prefix(1).map(\.id))
            shot(ShelfRootView(ui: ui, store: store, settings: settings, actions: actions),
                 size: CGSize(width: 440, height: 600), "Produkt Stapel \(lang)", dir: dir)
            if let stack = store.entries.first(where: \.isStack) {
                ui.selection = []
                ui.openStack = stack.id
                ui.memberSelection = Set(stack.files.prefix(1).map(\.id))
                shot(ShelfRootView(ui: ui, store: store, settings: settings, actions: actions),
                     size: CGSize(width: 440, height: 600), "Produkt Stapel offen \(lang)", dir: dir)
                ui.openStack = nil
                ui.memberSelection = []
            }

            // 3. Einstellungen (Standardgröße der Ablage)
            settings.shelfWidth = ShelfDefaults.width
            settings.shelfHeight = ShelfDefaults.height
            let panes: [(AnyView, String)] = [
                (AnyView(GeneralSettings(settings: settings)), "Allgemein"),
                (AnyView(OpeningSettings(settings: settings)), "Oeffnen"),
                (AnyView(AppearanceSettings(settings: settings)), "Aussehen"),
                (AnyView(ItemSettings(settings: settings, store: store)), "Objekte"),
                (AnyView(ActionSettings(settings: settings)), "Aktionen"),
                (AnyView(KeyboardSettings(settings: settings)), "Tastatur")
            ]
            for (pane, name) in panes {
                for (appearance, look) in [(NSAppearance.Name.darkAqua, "dunkel"), (.aqua, "hell")] {
                    shot(pane.background(SettingsTheme.contentBackdrop), size: CGSize(width: 436, height: 640),
                         "Produkt \(name) \(lang) \(look)", dir: dir, appearance: appearance)
                }
            }

            // Ganzes Einstellungsfenster im Dunkelmodus (Seitenleiste und Inhalt)
            for (pane, name) in [(SettingsPane.general, "Allgemein"), (.actions, "Aktionen"), (.items, "Objekte")] {
                shot(SettingsRoot(settings: settings, store: store, showOnboarding: {}, pane: pane)
                        .background(Color(nsColor: NSColor(white: 0.17, alpha: 1))),
                     size: CGSize(width: SettingsWindowFactory.size.width, height: SettingsWindowFactory.size.height),
                     "Produkt Fenster \(name) \(lang)", dir: dir, appearance: .darkAqua)
                shot(SettingsRoot(settings: settings, store: store, showOnboarding: {}, pane: pane)
                        .background(Color(nsColor: NSColor(white: 0.93, alpha: 1))),
                     size: CGSize(width: SettingsWindowFactory.size.width, height: SettingsWindowFactory.size.height),
                     "Produkt Fenster \(name) \(lang) hell", dir: dir, appearance: .aqua)
            }

            // 4. Einführung
            let controller = OnboardingController(store: ShelfStore(baseDirectory: base.appendingPathComponent("Intro-\(lang)")),
                                                  ui: ShelfUIModel(), settings: settings)
            controller.model.onFinish = { _ in }
            for step in [OnboardingModel.Step.allCases.first, OnboardingModel.Step.allCases.dropFirst().first].compactMap({ $0 }) {
                controller.model.go(to: step)
                RunLoop.main.run(until: Date().addingTimeInterval(0.6))
                shot(OnboardingView(model: controller.model, openSettings: {}).background(SettingsTheme.contentBackdrop),
                     size: OnboardingController.size, "Produkt Einfuehrung \(step.rawValue) \(lang)", dir: dir,
                     appearance: .darkAqua)
            }
        }
    }

    /// Beispieldateien für die Produktbilder: die der Einführung und ein paar weitere
    private static func productFiles(in dir: URL) -> (singles: [URL], stack: [URL]) {
        var singles = DemoShelf.makeExamples(in: dir)
        func photo(_ name: String, _ top: NSColor, _ bottom: NSColor, sun: NSColor, hill: NSColor) -> URL {
            let url = dir.appendingPathComponent(name)
            let image = NSImage(size: NSSize(width: 800, height: 600), flipped: false) { rect in
                NSGradient(starting: top, ending: bottom)?.draw(in: rect, angle: -90)
                sun.setFill()
                NSBezierPath(ovalIn: NSRect(x: 520, y: 330, width: 130, height: 130)).fill()
                hill.setFill()
                let path = NSBezierPath()
                path.move(to: .zero)
                path.curve(to: NSPoint(x: 800, y: 160), controlPoint1: NSPoint(x: 260, y: 330),
                           controlPoint2: NSPoint(x: 520, y: 40))
                path.line(to: NSPoint(x: 800, y: 0))
                path.close()
                path.fill()
                return true
            }
            if let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
               let jpg = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.9]) {
                try? jpg.write(to: url)
            }
            return url
        }
        singles.append(photo(L("Lake.jpg", "See.jpg"), NSColor(red: 0.45, green: 0.72, blue: 1, alpha: 1),
                             NSColor(red: 0.85, green: 0.93, blue: 1, alpha: 1),
                             sun: NSColor(red: 1, green: 0.95, blue: 0.7, alpha: 1),
                             hill: NSColor(red: 0.2, green: 0.5, blue: 0.35, alpha: 1)))
        let notes = dir.appendingPathComponent(L("Notes.txt", "Notizen.txt"))
        try? Data(L("Shopping list\n- Coffee\n- Bread\n", "Einkaufsliste\n- Kaffee\n- Brot\n").utf8).write(to: notes)
        singles.append(notes)
        let folder = dir.appendingPathComponent(L("Project", "Projekt"), isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        singles.append(folder)
        let stack = [
            photo(L("Sunset 1.jpg", "Sonnenuntergang 1.jpg"), NSColor(red: 1, green: 0.55, blue: 0.4, alpha: 1),
                  NSColor(red: 1, green: 0.85, blue: 0.6, alpha: 1), sun: .white,
                  hill: NSColor(red: 0.55, green: 0.25, blue: 0.3, alpha: 1)),
            photo(L("Sunset 2.jpg", "Sonnenuntergang 2.jpg"), NSColor(red: 0.6, green: 0.35, blue: 0.85, alpha: 1),
                  NSColor(red: 1, green: 0.7, blue: 0.6, alpha: 1), sun: NSColor(red: 1, green: 0.9, blue: 0.6, alpha: 1),
                  hill: NSColor(red: 0.3, green: 0.2, blue: 0.4, alpha: 1)),
            photo(L("Sunset 3.jpg", "Sonnenuntergang 3.jpg"), NSColor(red: 0.95, green: 0.4, blue: 0.5, alpha: 1),
                  NSColor(red: 1, green: 0.8, blue: 0.5, alpha: 1), sun: NSColor(red: 1, green: 1, blue: 0.85, alpha: 1),
                  hill: NSColor(red: 0.35, green: 0.15, blue: 0.25, alpha: 1))
        ]
        return (singles, stack)
    }

    /// Wie `render`, aber in doppelter Auflösung
    private func shot<V: View>(_ view: V, size: CGSize, _ name: String, dir: String,
                               appearance: NSAppearance.Name? = nil) {
        // Doppelte Auflösung ohne Bildschirm mit Retina: die Ansicht in normaler Größe
        // auslegen und beim Zeichnen auf das Doppelte vergrößern. Text und Symbole sind
        // Vektoren bzw. haben Bilder in doppelter Auflösung und bleiben dabei scharf.
        let scaled = view
            .frame(width: size.width, height: size.height)
            .scaleEffect(2, anchor: .topLeading)
            .frame(width: size.width * 2, height: size.height * 2, alignment: .topLeading)
        let host = NSHostingView(rootView: scaled)
        if let appearance { host.appearance = NSAppearance(named: appearance) }
        host.frame = CGRect(origin: .zero, size: CGSize(width: size.width * 2, height: size.height * 2))
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return XCTFail(name) }
        host.cacheDisplay(in: host.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else { return XCTFail(name) }
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try? png.write(to: URL(fileURLWithPath: dir).appendingPathComponent(name.replacingOccurrences(of: " ", with: "_") + ".png"))
    }

    /// Beim Verstellen der Symbolgröße: Beispieldateien in der neuen Größe, auch in einer
    /// leeren Ablage
    func testSizeGuidesRender() {
        let settings = AppSettings.shared
        let store = ShelfStore(baseDirectory: base)
        let ui = ShelfUIModel()
        let actions = ShelfActions(store: store, ui: ui, settings: settings)
        ui.level = .expanded
        ui.showSampleTile = true
        ui.expandedBody = CGRect(x: 0, y: 0, width: settings.shelfWidth, height: settings.shelfHeight)
        let before = settings.tileIconSize
        defer { settings.tileIconSize = before }
        for size in [40.0, 64.0, 96.0] {
            settings.tileIconSize = size
            render(ShelfRootView(ui: ui, store: store, settings: settings, actions: actions),
                   size: CGSize(width: 420, height: 720), "Symbolgroesse \(Int(size))")
        }
    }
}
