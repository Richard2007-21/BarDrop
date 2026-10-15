import AppKit
import SwiftUI
import Combine
import ServiceManagement
import Carbon

// MARK: Ablauf

/// Einführung beim ersten Start, aufgebaut wie eine Produktvorstellung: je Schritt eine
/// große, bewegte Szene auf einem kleinen Bildschirm, eine Überschrift, ein Satz. Vier
/// kurze Übungen (ablegen, herausziehen, zurückholen, Kurzbefehl) erkennen von selbst,
/// wann sie geschafft sind. Farben, Schalter und Knöpfe wie in den Einstellungen.
final class OnboardingModel: ObservableObject {
    enum Step: Int, CaseIterable, Identifiable {
        case welcome, drop, retrieve, undo, shortcut, features
        var id: Int { rawValue }
    }

    @Published private(set) var step: Step = .welcome
    /// Geschaffte Schritte (Häkchen in der Seitenleiste)
    @Published private(set) var completed: Set<Step> = []
    /// Beim ersten Start vorgeschlagen; wird die Einführung später erneut geöffnet,
    /// zeigt der Schalter den tatsächlichen Zustand
    @Published var launchAtLogin: Bool
    /// Die Einführung läuft nicht zum ersten Mal (z. B. über Einstellungen → Über geöffnet)
    let isRerun: Bool

    let settings: AppSettings
    /// Beispieldatei; wird umbenannt, wenn auf der ersten Seite die Sprache wechselt
    @Published var sampleURL: URL?
    /// Liegt die Beispieldatei gerade in der Ablage? (für die Anleitung beim Zurückholen)
    @Published var sampleInShelf = false
    var onFinish: (_ completed: Bool) -> Void = { _ in }
    /// Ziehen der Beispieldatei hat begonnen: Die Ablage muss davon erfahren, denn
    /// Ziehen aus dem eigenen Fenster melden die Ereignisse des Systems nicht.
    var onSampleDragStarted: () -> Void = {}

    init(settings: AppSettings, sampleURL: URL?) {
        self.settings = settings
        self.sampleURL = sampleURL
        isRerun = settings.didLaunchBefore
        launchAtLogin = settings.didLaunchBefore ? SMAppService.mainApp.status == .enabled : true
    }

    enum LoginItemChange: Equatable { case register, unregister }

    /// Was beim Abschluss mit „Beim Anmelden öffnen“ geschieht. Nur „Fertig“ ändert etwas
    /// (Überspringen und Schließen nie); abgemeldet wird nur bei einem erneuten Durchlauf,
    /// beim ersten Start bleibt es beim Anmelden auf Wunsch.
    static func loginItemChange(completed: Bool, wanted: Bool, isRerun: Bool, enabled: Bool) -> LoginItemChange? {
        guard completed else { return nil }
        if wanted && !enabled { return .register }
        if !wanted && enabled && isRerun { return .unregister }
        return nil
    }

    /// Schritte zum Mitmachen
    static let practice: [Step] = [.drop, .retrieve, .undo, .shortcut]

    /// Der aktuelle Schritt ist geschafft
    var stepDone: Bool { completed.contains(step) }

    func go(to step: Step) {
        withAnimation(.easeOut(duration: 0.18)) { self.step = step }
    }

    /// Einen Schritt zurück
    func back() {
        guard let previous = Step(rawValue: step.rawValue - 1) else { return }
        go(to: previous)
    }

    func advance() {
        guard let next = Step(rawValue: step.rawValue + 1) else {
            onFinish(true)
            return
        }
        go(to: next)
    }

    /// Ein Schritt wurde gemacht: abhaken, kurz stehen lassen, weiter.
    func complete(_ done: Step) {
        guard step == done, !completed.contains(done) else { return }
        Haptics.tap()
        withAnimation(.spring(response: 0.4, dampingFraction: 0.75)) { _ = completed.insert(done) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            guard let self, self.step == done else { return }
            self.advance()
        }
    }
}

final class OnboardingController: NSObject, NSWindowDelegate {
    private let store: ShelfStore
    private let ui: ShelfUIModel
    private let settings: AppSettings
    /// Ohne „private“, damit Tests den Ablauf steuern können
    let model: OnboardingModel
    private var window: NSWindow?
    private var subscriptions: Set<AnyCancellable> = []

    /// Einträge vor dem Schritt „Ablegen“
    private var baseline: Set<UUID> = []
    /// Einträge mit der Beispieldatei: werden am Ende wieder entfernt
    private var sampleEntries: Set<UUID> = []
    /// Schritt „Zurückholen“: Die Beispieldatei war seit Beginn des Schritts einmal weg
    private var sampleWasGone = false
    private var finished = false

    /// Wird nach dem Schließen aufgerufen, damit der Besitzer loslassen kann.
    var onClose: () -> Void = {}
    /// Öffnet am Ende auf Wunsch die Einstellungen.
    var openSettings: () -> Void = {}
    /// Weckt die Ablage, damit sie das Ziehen der Beispieldatei bemerkt.
    var wakeShelf: () -> Void = {} {
        didSet { model.onSampleDragStarted = wakeShelf }
    }

    var isVisible: Bool { window?.isVisible == true }

    init(store: ShelfStore, ui: ShelfUIModel, settings: AppSettings) {
        self.store = store
        self.ui = ui
        self.settings = settings
        self.model = OnboardingModel(settings: settings, sampleURL: Self.makeSample())
        super.init()
        model.onFinish = { [weak self] completed in self?.finish(completed: completed) }
        observe()
    }

    func show() {
        if window == nil { window = makeWindow() }
        NSApp.activate(ignoringOtherApps: true)
        window?.center()
        window?.makeKeyAndOrderFront(nil)
    }

    /// Der globale Kurzbefehl wurde gedrückt.
    func hotKeyPressed() {
        model.complete(.shortcut)
    }

    // MARK: Erkennen, dass ein Schritt geschafft ist

    private func observe() {
        model.$step
            .sink { [weak self] step in self?.prepare(step) }
            .store(in: &subscriptions)

        store.$entries
            .receive(on: RunLoop.main)
            .sink { [weak self] entries in self?.entriesChanged(entries) }
            .store(in: &subscriptions)

    }

    private func prepare(_ step: OnboardingModel.Step) {
        switch step {
        case .drop:
            baseline = Set(store.entries.map(\.id))
            renameSampleForLanguage()
        case .undo:
            // Nach dem Herausziehen ist das Bild meist schon weg; dann genügt ⌘Z
            sampleWasGone = !containsSample(store.entries)
        default:
            break
        }
    }

    private func entriesChanged(_ entries: [ShelfEntry]) {
        let name = model.sampleURL?.lastPathComponent
        for entry in entries where entry.files.contains(where: { $0.url.lastPathComponent == name }) {
            if !baseline.contains(entry.id) { sampleEntries.insert(entry.id) }
        }
        let present = containsSample(entries)
        if model.sampleInShelf != present { model.sampleInShelf = present }
        switch model.step {
        case .drop:
            if entries.contains(where: { !baseline.contains($0.id) }) {
                model.complete(.drop)
            }
        case .undo:
            // Erst weg (entfernt oder herausgezogen), dann wieder da: zurückgeholt
            if !present {
                sampleWasGone = true
            } else if sampleWasGone {
                model.complete(.undo)
            }
        default:
            break
        }
    }

    /// Liegt die Beispieldatei in einem der Einträge?
    private func containsSample(_ entries: [ShelfEntry]) -> Bool {
        guard let name = model.sampleURL?.lastPathComponent else { return false }
        return entries.contains { $0.files.contains { $0.url.lastPathComponent == name } }
    }

    /// Die Sprache kann auf der ersten Seite gewechselt worden sein: Die Beispieldatei
    /// bekommt den Namen in der aktuellen Sprache, bevor sie zum ersten Mal zu sehen ist.
    private func renameSampleForLanguage() {
        guard let url = model.sampleURL, url.lastPathComponent != Self.sampleName else { return }
        let renamed = url.deletingLastPathComponent().appendingPathComponent(Self.sampleName)
        if (try? FileManager.default.moveItem(at: url, to: renamed)) != nil {
            model.sampleURL = renamed
        }
    }

    // MARK: Ende

    private func finish(completed: Bool) {
        guard !finished else { return }
        finished = true
        settings.didLaunchBefore = true
        // Die Beispieldatei hat ihren Zweck erfüllt. Nur sie selbst entfernen, nicht was
        // inzwischen dazugelegt wurde (z. B. eigene Dateien, die mit ihr einen Stapel bilden)
        let name = model.sampleURL?.lastPathComponent
        let sampleFiles = store.entries
            .filter { sampleEntries.contains($0.id) }
            .flatMap(\.files)
            .filter { $0.url.lastPathComponent == name }
            .map(\.url)
        if !sampleFiles.isEmpty { store.forgetFiles(at: sampleFiles) }
        if let url = model.sampleURL { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        switch OnboardingModel.loginItemChange(completed: completed, wanted: model.launchAtLogin,
                                               isRerun: model.isRerun,
                                               enabled: SMAppService.mainApp.status == .enabled) {
        case .register:
            do {
                try SMAppService.mainApp.register()
            } catch {
                Log.edge.error("Anmeldeobjekt nicht möglich: \(error.localizedDescription, privacy: .public)")
            }
        case .unregister:
            do {
                try SMAppService.mainApp.unregister()
            } catch {
                Log.edge.error("Anmeldeobjekt ließ sich nicht entfernen: \(error.localizedDescription, privacy: .public)")
            }
        case nil:
            break
        }
        subscriptions.removeAll()
        window?.delegate = nil
        window?.close()
        window = nil
        onClose()
    }

    func windowWillClose(_ notification: Notification) {
        // Mit dem Schließknopf beendet: gilt als erledigt, nichts wird nachgefragt
        DispatchQueue.main.async { [weak self] in self?.finish(completed: false) }
    }

    // MARK: Fenster

    /// Etwas kleiner als die Einstellungen (680 × 700), im selben Aufbau
    static let size = NSSize(width: 680, height: 620)

    /// Fenster wie die Einstellungen: hohe, durchsichtige Titelleiste, leicht durchscheinend,
    /// feste Größe, mittig. Bleibt über anderen Fenstern, damit man beim Üben zum Rand ziehen kann.
    private func makeWindow() -> NSWindow {
        let window = IntroWindow(contentRect: NSRect(origin: .zero, size: Self.size),
                                 styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
                                 backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.toolbar = NSToolbar(identifier: "BarDropIntroduction")
        window.toolbarStyle = .unified
        window.titlebarSeparatorStyle = .none
        window.title = L("Welcome to BarDrop", "Willkommen bei BarDrop")
        window.isMovableByWindowBackground = false
        window.isReleasedWhenClosed = false
        window.isOpaque = false
        window.backgroundColor = .clear
        window.level = .floating
        window.collectionBehavior = [.moveToActiveSpace]
        window.delegate = self
        let root = OnboardingView(model: model, openSettings: { [weak self] in
            self?.openSettings()
        })
        window.contentView = NSHostingView(rootView: root)
        window.setContentSize(Self.size)
        window.center()
        return window
    }

    static var sampleName: String { L("Welcome to BarDrop.png", "Willkommen bei BarDrop.png") }

    /// Beispielbild zum Ablegen. Liegt in einem temporären Ordner und wird beim
    /// Ablegen wie ein Bild aus dem Web in die Ablage kopiert.
    static func makeSample() -> URL? {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("BarDropEinfuehrung-\(UUID().uuidString)", isDirectory: true)
        let url = dir.appendingPathComponent(sampleName)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            return nil
        }
        let side: CGFloat = 512
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            let card = NSBezierPath(roundedRect: rect, xRadius: side * 0.22, yRadius: side * 0.22)
            NSGradient(colors: [NSColor(white: 0.24, alpha: 1), NSColor(white: 0.03, alpha: 1)])?
                .draw(in: card, angle: -90)
            NSColor(white: 1, alpha: 0.12).setStroke()
            card.lineWidth = 4
            card.stroke()
            if let icon = NSApp.applicationIconImage {
                icon.draw(in: rect.insetBy(dx: side * 0.2, dy: side * 0.2))
            }
            return true
        }
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]),
              (try? png.write(to: url)) != nil else { return nil }
        return url
    }
}

// MARK: Oberfläche

/// Fenster der Einführung. Eigene Klasse, damit ⌘W sie wie mit dem Schließknopf beendet
/// (siehe AppDelegate) und sie Tastatureingaben bekommt (Eingabetaste, Escape).
final class IntroWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

extension OnboardingModel.Step {
    var title: String {
        switch self {
        case .welcome: return L("Welcome", "Willkommen")
        case .drop: return L("Drop", "Ablegen")
        case .retrieve: return L("Drag Out", "Herausziehen")
        case .undo: return L("Get Back", "Zurückholen")
        case .shortcut: return L("Shortcut", "Kurzbefehl")
        case .features: return L("Discover More", "Mehr entdecken")
        }
    }
}

struct OnboardingView: View {
    @ObservedObject var model: OnboardingModel
    /// Sprache, Rand und Einstellungen ändern alle Texte sofort
    @ObservedObject private var settings = AppSettings.shared
    var openSettings: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            page
                .id(model.step)
                .transition(.opacity)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.top, 34)          // unter der Titelleiste

            footer
                .padding(.horizontal, 22)
                .frame(height: 64)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(SettingsTheme.content.opacity(SettingsTheme.backdropOpacity))
        .background(SettingsBackdrop().ignoresSafeArea())
        .ignoresSafeArea()
    }

    @ViewBuilder
    private var page: some View {
        switch model.step {
        case .welcome: WelcomePage(model: model, settings: settings)
        case .drop: DropPage(model: model, settings: settings)
        case .retrieve: RetrievePage(model: model, settings: settings)
        case .undo: UndoPage(model: model, settings: settings)
        case .shortcut: ShortcutPage(model: model, settings: settings)
        case .features: FeaturesPage(settings: settings)
        }
    }

    // MARK: Unten: Zurück, Fortschritt, Weiter

    private var footer: some View {
        ZStack {
            StepDots(current: model.step, completed: model.completed) { model.go(to: $0) }
            HStack(spacing: 8) {
                switch model.step {
                case .welcome:
                    Button(L("Skip", "Überspringen")) { model.onFinish(false) }
                        .buttonStyle(KlackButtonStyle())
                        .keyboardShortcut(.cancelAction)
                    Spacer()
                    Button(L("Let’s Go", "Los geht’s")) { model.advance() }
                        .buttonStyle(KlackButtonStyle(prominent: true))
                        .keyboardShortcut(.defaultAction)
                case .features:
                    Button(L("Back", "Zurück")) { model.back() }
                        .buttonStyle(KlackButtonStyle())
                    Spacer()
                    Button(L("Done", "Fertig")) { model.advance() }
                        .buttonStyle(KlackButtonStyle(prominent: true))
                        .keyboardShortcut(.defaultAction)
                default:
                    Button(L("Back", "Zurück")) { model.back() }
                        .buttonStyle(KlackButtonStyle())
                    Spacer()
                    if model.stepDone {
                        Button(L("Continue", "Weiter")) { model.advance() }
                            .buttonStyle(KlackButtonStyle(prominent: true))
                            .keyboardShortcut(.defaultAction)
                    } else {
                        Button(L("Skip", "Überspringen")) { model.advance() }
                            .buttonStyle(KlackButtonStyle())
                            .keyboardShortcut(.cancelAction)
                    }
                }
            }
        }
    }
}

/// Fortschritt als Punkte; geschaffte Übungen grün, ein Klick springt zum Schritt.
private struct StepDots: View {
    let current: OnboardingModel.Step
    let completed: Set<OnboardingModel.Step>
    let go: (OnboardingModel.Step) -> Void

    var body: some View {
        HStack(spacing: 6) {
            ForEach(OnboardingModel.Step.allCases) { step in
                Button { go(step) } label: {
                    Capsule()
                        .fill(color(step))
                        .frame(width: step == current ? 18 : 7, height: 7)
                        .padding(.vertical, 6)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(step.title)
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: current)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L("Step \(current.rawValue + 1) of \(OnboardingModel.Step.allCases.count)",
                              "Schritt \(current.rawValue + 1) von \(OnboardingModel.Step.allCases.count)"))
    }

    private func color(_ step: OnboardingModel.Step) -> Color {
        if step == current { return Color.primary.opacity(0.85) }
        if completed.contains(step) { return Color.green.opacity(0.85) }
        return Color.primary.opacity(0.2)
    }
}

// MARK: Aufbau einer Seite

/// Eine Seite: große Szene oben, Überschrift, ein Satz, darunter die Übung.
private struct PresentationPage<Hero: View, Practice: View>: View {
    let title: String
    let text: String
    @ViewBuilder let hero: () -> Hero
    @ViewBuilder let practice: () -> Practice

    var body: some View {
        VStack(spacing: 0) {
            hero()
                .frame(height: 252)
            Text(title)
                .font(.system(size: 24, weight: .semibold))
                .padding(.top, 22)
            Text(text)
                .font(.system(size: 13.5))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 440)
                .padding(.top, 6)
            practice()
                .padding(.top, 20)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 30)
        .frame(maxWidth: .infinity)
    }
}

/// Übung mit Ergebnis: vorher der Inhalt, danach ein grüner Haken mit kurzer Bestätigung
private struct PracticeResult<Content: View>: View {
    let done: Bool
    let confirmation: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        ZStack {
            if done {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 22))
                        .foregroundStyle(.white, .green)
                    Text(confirmation)
                        .font(.system(size: 14, weight: .medium))
                }
                .transition(.scale(scale: 0.8).combined(with: .opacity))
            } else {
                content()
                    .transition(.opacity)
            }
        }
        .frame(height: 96)
        .animation(.spring(response: 0.4, dampingFraction: 0.75), value: done)
    }
}

/// Wort für den gewählten Rand im Satz („an den rechten Rand“)
private func edgeWord(_ settings: AppSettings) -> String {
    settings.edge == .right ? L("right", "rechten") : L("left", "linken")
}

// MARK: Willkommen

private struct WelcomePage: View {
    @ObservedObject var model: OnboardingModel
    @ObservedObject var settings: AppSettings

    var body: some View {
        PresentationPage(title: L("Welcome to BarDrop", "Willkommen bei BarDrop"),
                         text: L("A shelf at the edge of your screen for anything you want to keep at hand.",
                                 "Eine Ablage am Rand deines Bildschirms für alles, was du gleich wieder brauchst.")) {
            DemoScreen(scene: .overview, edge: settings.edge)
        } practice: {
            SettingsCard {
                SettingsRow(L("Language", "Sprache")) {
                    SegmentedValue(selection: $settings.language,
                                   options: AppLanguage.allCases.map { ($0, $0.title) })
                }
                SettingsRow(L("Screen edge", "Bildschirmrand")) {
                    SegmentedValue(selection: $settings.edge,
                                   options: ScreenEdge.allCases.map { ($0, $0.title) })
                }
                ToggleRow(L("Open at login", "Beim Anmelden öffnen"), isOn: $model.launchAtLogin)
            }
            .frame(maxWidth: 400)
        }
    }
}

// MARK: Ablegen

private struct DropPage: View {
    @ObservedObject var model: OnboardingModel
    @ObservedObject var settings: AppSettings

    var body: some View {
        PresentationPage(title: L("Drop", "Ablegen"),
                         text: L("Drag something to the \(edgeWord(settings)) edge of your screen. The shelf opens, and you let go.",
                                 "Zieh etwas an den \(edgeWord(settings)) Rand deines Bildschirms. Die Ablage öffnet sich, und du lässt los.")) {
            DemoScreen(scene: .drop, edge: settings.edge)
        } practice: {
            PracticeResult(done: model.stepDone,
                           confirmation: L("The image is in the shelf.", "Das Bild liegt in der Ablage.")) {
                HStack(spacing: 14) {
                    if settings.edge == .left { EdgeArrows(edge: .left) }
                    SampleTile(url: model.sampleURL, onDragStarted: model.onSampleDragStarted)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L("Your turn", "Jetzt du"))
                            .font(.system(size: 13, weight: .semibold))
                        Text(L("Drag this image to the edge of the screen.",
                               "Zieh dieses Bild an den Bildschirmrand."))
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                    if settings.edge == .right { EdgeArrows(edge: .right) }
                }
            }
        }
    }
}

// MARK: Herausziehen

private struct RetrievePage: View {
    @ObservedObject var model: OnboardingModel
    @ObservedObject var settings: AppSettings

    /// Wie man die Ablage öffnet, passend zu den Einstellungen
    private var howToOpen: String {
        if settings.openMode == .click {
            return L("Move the pointer to the \(edgeWord(settings)) edge and click the strip.",
                     "Fahr an den \(edgeWord(settings)) Rand und klick auf den Streifen.")
        }
        return L("Move the pointer to the \(edgeWord(settings)) edge. The shelf opens, and you drag out what you need.",
                 "Fahr mit dem Zeiger an den \(edgeWord(settings)) Rand. Die Ablage öffnet sich, und du ziehst heraus, was du brauchst.")
    }

    var body: some View {
        PresentationPage(title: L("Drag Out", "Herausziehen"), text: howToOpen) {
            DemoScreen(scene: .dragOut, edge: settings.edge)
        } practice: {
            PracticeResult(done: model.stepDone,
                           confirmation: L("Works with any app.", "Klappt mit jeder App.")) {
                ReturnDropZone {
                    model.complete(.retrieve)
                }
            }
        }
    }
}

// MARK: Zurückholen

private struct UndoPage: View {
    @ObservedObject var model: OnboardingModel
    @ObservedObject var settings: AppSettings

    var body: some View {
        PresentationPage(title: L("Get Back", "Zurückholen"),
                         text: L("Removed something by mistake? In the open shelf, ⌘Z brings it back.",
                                 "Versehentlich entfernt? In der offenen Ablage holt ⌘Z es zurück.")) {
            DemoScreen(scene: .undo, edge: settings.edge)
        } practice: {
            PracticeResult(done: model.stepDone,
                           confirmation: L("The image is back.", "Das Bild ist wieder da.")) {
                HStack(spacing: 14) {
                    KeyCaps(keys: [("⌘", "command"), ("Z", "")], size: 50, pressed: false)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L("Your turn", "Jetzt du"))
                            .font(.system(size: 13, weight: .semibold))
                        Text(model.sampleInShelf
                             ? L("Open the shelf, select the image, press ⌫ and then ⌘Z.",
                                 "Öffne die Ablage, wähl das Bild, drück ⌫ und dann ⌘Z.")
                             : L("Open the shelf and press ⌘Z.",
                                 "Öffne die Ablage und drück ⌘Z."))
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: 240, alignment: .leading)
                }
            }
        }
    }
}

// MARK: Kurzbefehl

private struct ShortcutPage: View {
    @ObservedObject var model: OnboardingModel
    @ObservedObject var settings: AppSettings

    /// Reihenfolge wie bei Apple und in `hotKeyDescription`: ⌃ ⌥ ⇧ ⌘
    private var keys: [(symbol: String, name: String)] {
        let m = settings.hotKeyModifiers
        var keys: [(symbol: String, name: String)] = []
        if m & controlKey != 0 { keys.append((symbol: "⌃", name: "control")) }
        if m & optionKey != 0 { keys.append((symbol: "⌥", name: "option")) }
        if m & shiftKey != 0 { keys.append((symbol: "⇧", name: "shift")) }
        if m & cmdKey != 0 { keys.append((symbol: "⌘", name: "command")) }
        keys.append((symbol: settings.hotKeyLabel, name: ""))
        return keys
    }

    var body: some View {
        PresentationPage(title: L("Open from Anywhere", "Von überall öffnen"),
                         text: L("Press \(settings.hotKeyDescription). Press it again to close the shelf. You can change it in Settings → Keyboard.",
                                 "Drück \(settings.hotKeyDescription). Noch einmal, und die Ablage geht wieder zu. Ändern kannst du das unter Einstellungen → Tastatur.")) {
            KeyCaps(keys: keys, size: 76, pressed: model.stepDone)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } practice: {
            PracticeResult(done: model.stepDone,
                           confirmation: L("That’s it.", "Genau so.")) {
                Text(L("Your turn: press the keys now.", "Jetzt du: Drück die Tasten."))
                    .font(.system(size: 13, weight: .semibold))
            }
        }
    }
}

/// Tasten als Kappen wie unter Einstellungen → Tastatur; nach dem Drücken in Akzentfarbe
private struct KeyCaps: View {
    let keys: [(symbol: String, name: String)]
    let size: CGFloat
    let pressed: Bool

    var body: some View {
        HStack(spacing: size * 0.13) {
            ForEach(Array(keys.enumerated()), id: \.offset) { _, key in
                VStack(alignment: .leading, spacing: 0) {
                    if key.name.isEmpty {
                        Text(key.symbol)
                            .font(.system(size: size * 0.32, weight: .medium))
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        Text(key.symbol).font(.system(size: size * 0.24, weight: .medium))
                        Spacer(minLength: 0)
                        Text(key.name).font(.system(size: size * 0.17, weight: .medium))
                    }
                }
                .foregroundStyle(pressed ? Color.white : Color.primary)
                .padding(.horizontal, size * 0.15)
                .padding(.vertical, size * 0.12)
                .frame(width: key.name.isEmpty ? size : size * 1.2, height: size, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: size * 0.16, style: .continuous)
                        .fill(pressed ? Color(nsColor: .controlAccentColor) : Color.primary.opacity(0.1))
                        .shadow(color: .black.opacity(0.18), radius: 1.5, y: 1.5)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: size * 0.16, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.1), lineWidth: 1)
                )
                .scaleEffect(pressed ? 0.96 : 1)
            }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.6), value: pressed)
    }
}

// MARK: Mehr entdecken

private struct FeaturesPage: View {
    @ObservedObject var settings: AppSettings

    private struct Feature: Identifiable {
        let id: String
        let symbol: String
        let tint: Color
        let title: String
        let text: String
    }

    /// Automatisches Entfernen, mit dem eingestellten Wert
    private var cleanup: String {
        let hours = Int(settings.autoRemoveAfter / 3_600)
        if hours <= 0 { return L("Stays until you remove it", "Bleibt, bis du es entfernst") }
        return hours == 1 ? L("Gone by itself after 1 hour", "Nach 1 Stunde von selbst weg")
                          : L("Gone by itself after \(hours) hours", "Nach \(hours) Stunden von selbst weg")
    }

    private var features: [Feature] {
        [
            Feature(id: "actions", symbol: "paperplane.fill", tint: Color(red: 0.2, green: 0.47, blue: 1),
                    title: L("Actions", "Aktionen"),
                    text: L("Drag onto AirDrop, a folder or the Trash", "Auf AirDrop, Ordner oder Papierkorb ziehen")),
            Feature(id: "convert", symbol: "arrow.triangle.2.circlepath", tint: Color(red: 0.2, green: 0.78, blue: 0.4),
                    title: L("Convert", "Umwandeln"),
                    text: L("Right-click for JPEG, PDF and more", "Per Rechtsklick in JPEG, PDF und mehr")),
            Feature(id: "stacks", symbol: "square.stack.fill", tint: Color(red: 0.18, green: 0.68, blue: 0.75),
                    title: L("Stacks", "Stapel"),
                    text: L("Several items at once stay together", "Mehrere auf einmal bleiben zusammen")),
            Feature(id: "cleanup", symbol: "clock.fill", tint: Color(red: 0.92, green: 0.3, blue: 0.55),
                    title: L("Cleanup", "Aufräumen"), text: cleanup)
        ]
    }

    private let columns = [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]

    var body: some View {
        VStack(spacing: 0) {
            Image(systemName: "sparkles")
                .font(.system(size: 46, weight: .regular))
                .foregroundStyle(Color(nsColor: .controlAccentColor))
                .frame(height: 70)
                .padding(.top, 10)
            Text(L("And There’s More", "Und noch mehr"))
                .font(.system(size: 24, weight: .semibold))
                .padding(.top, 12)
            Text(L("Everything can be adjusted in Settings: right-click an empty spot in the shelf.",
                   "Alles lässt sich in den Einstellungen anpassen: Rechtsklick auf eine leere Stelle der Ablage."))
                .font(.system(size: 13.5))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 440)
                .padding(.top, 6)

            LazyVGrid(columns: columns, spacing: 12) {
                ForEach(features) { feature in
                    HStack(spacing: 12) {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(LinearGradient(colors: [feature.tint.opacity(0.85), feature.tint],
                                                 startPoint: .top, endPoint: .bottom))
                            .overlay(
                                Image(systemName: feature.symbol)
                                    .font(.system(size: 18, weight: .semibold))
                                    .foregroundStyle(.white)
                            )
                            .frame(width: 40, height: 40)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(feature.title)
                                .font(.system(size: 13.5, weight: .semibold))
                            Text(feature.text)
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, minHeight: 68, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: SettingsTheme.cardRadius, style: .continuous)
                            .fill(SettingsTheme.card)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: SettingsTheme.cardRadius, style: .continuous)
                            .strokeBorder(SettingsTheme.cardBorder, lineWidth: 1)
                    )
                }
            }
            .frame(maxWidth: 520)
            .padding(.top, 26)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 30)
    }
}

// MARK: Szene auf einem kleinen Bildschirm

/// Ein kleiner Mac-Bildschirm, auf dem gezeigt wird, was passiert: Eine Datei wandert an den
/// Rand, die Ablage wächst heraus (in ihrer echten Form) und nimmt sie auf; oder sie wird
/// wieder herausgezogen; oder entfernt und mit ⌘Z zurückgeholt. Läuft in einer Schleife;
/// mit „Bewegung reduzieren“ steht ein Standbild.
private struct DemoScreen: View {
    enum Scene { case overview, drop, dragOut, undo }
    let scene: Scene
    let edge: ScreenEdge

    private let size = CGSize(width: 420, height: 252)
    private let inset: CGFloat = 8
    private var screen: CGSize { CGSize(width: size.width - 2 * inset, height: size.height - 2 * inset) }
    private let shelfWidth: CGFloat = 104
    private let shelfHeight: CGFloat = 150

    private var period: Double {
        switch scene {
        case .overview: return 1
        case .drop: return 4.6
        case .dragOut: return 4.8
        case .undo: return 4.8
        }
    }

    /// Standbild bei „Bewegung reduzieren“: der aussagekräftigste Moment
    private var stillTime: Double {
        switch scene {
        case .overview: return 0
        case .drop: return 2.6
        case .dragOut: return 2.0
        case .undo: return 3.4
        }
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: AnimationStyle.reduceMotion || scene == .overview)) { context in
            let t = AnimationStyle.reduceMotion || scene == .overview
                ? stillTime
                : context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: period)
            frame(at: t)
        }
        .frame(width: size.width, height: size.height)
        .accessibilityHidden(true)
    }

    // MARK: Zeitlicher Ablauf

    /// 0 … 1 zwischen `a` und `b`, weich beschleunigt und abgebremst
    private func phase(_ t: Double, _ a: Double, _ b: Double) -> CGFloat {
        let x = min(max((t - a) / (b - a), 0), 1)
        return CGFloat(x * x * (3 - 2 * x))
    }

    private func mix(_ a: CGFloat, _ b: CGFloat, _ p: CGFloat) -> CGFloat { a + (b - a) * p }

    /// Waagrechte Lage, gemessen vom Rand der Ablage aus (gespiegelt für links)
    private func x(fromEdge d: CGFloat) -> CGFloat {
        edge == .right ? screen.width - d : d
    }

    private var centerY: CGFloat { screen.height / 2 + 6 }
    private var windowCenter: CGPoint { CGPoint(x: x(fromEdge: screen.width - 120), y: centerY + 4) }
    private var shelfSlot: CGPoint { CGPoint(x: x(fromEdge: shelfWidth / 2 + 2), y: centerY - 18) }

    private struct Pose {
        var shelf: CGFloat = 0           // sichtbare Breite der Ablage
        var file = CGPoint.zero
        var fileScale: CGFloat = 1
        var fileOpacity: Double = 1
        var pointer = CGPoint.zero
        var pointerOpacity: Double = 1
        var keyOpacity: Double = 0       // „⌘Z“ einblenden
        var otherTiles: Double = 1       // weitere Objekte in der Ablage
    }

    private func pose(at t: Double) -> Pose {
        var s = Pose()
        let start = windowCenter
        let slot = shelfSlot
        let nearEdge = CGPoint(x: x(fromEdge: 30), y: centerY - 6)
        switch scene {
        case .overview:
            s.shelf = shelfWidth
            s.file = slot
            s.fileScale = 0.82
            s.pointer = CGPoint(x: x(fromEdge: shelfWidth + 40), y: centerY + 40)
        case .drop:
            // Datei mit dem Zeiger zum Rand, Ablage wächst heraus, Datei landet darin
            let move = phase(t, 0.4, 1.6)
            let land = phase(t, 1.9, 2.3)
            s.file = CGPoint(x: mix(mix(start.x, nearEdge.x, move), slot.x, land),
                             y: mix(mix(start.y, nearEdge.y, move), slot.y, land))
            s.fileScale = mix(1, 0.82, land)
            s.shelf = shelfWidth * phase(t, 1.3, 1.85) + 8 * phase(t, 1.05, 1.3) * (1 - phase(t, 1.3, 1.85))
            let close = phase(t, 3.6, 4.0)
            s.shelf *= (1 - close)
            s.fileOpacity = Double(min(1 - close, phase(t, 0.0, 0.25)))
            s.pointer = CGPoint(x: s.file.x + 10 + mix(0, edge == .right ? -60 : 60, land),
                                y: s.file.y + 14 + mix(0, 40, land))
            s.pointerOpacity = Double(phase(t, 0.0, 0.25) * (1 - close))
            s.otherTiles = Double(1 - close)
        case .dragOut:
            // Zeiger an den Rand, Ablage öffnet sich, Datei wird ins Fenster gezogen
            let approach = phase(t, 0.3, 1.0)
            let open = phase(t, 1.0, 1.4)
            let grab = phase(t, 1.6, 2.6)
            let close = phase(t, 2.8, 3.2)
            s.shelf = (8 * phase(t, 0.8, 1.0) * (1 - open) + shelfWidth * open) * (1 - close)
            s.file = CGPoint(x: mix(slot.x, start.x, grab), y: mix(slot.y, start.y, grab))
            s.fileScale = mix(0.82, 1, grab)
            s.fileOpacity = Double(max(open, grab)) * Double(1 - phase(t, 4.3, 4.7))
            let pointerStart = CGPoint(x: start.x, y: start.y + 30)
            let atFile = CGPoint(x: slot.x + 10, y: slot.y + 14)
            let p1 = CGPoint(x: mix(pointerStart.x, atFile.x, approach), y: mix(pointerStart.y, atFile.y, approach))
            s.pointer = CGPoint(x: mix(p1.x, s.file.x + 10, grab), y: mix(p1.y, s.file.y + 14, grab))
            s.pointerOpacity = Double(1 - phase(t, 4.3, 4.7))
            s.otherTiles = Double(1 - close)
        case .undo:
            // Ablage offen, Datei verschwindet, ⌘Z erscheint, Datei ist wieder da
            s.shelf = shelfWidth
            s.file = slot
            let gone = phase(t, 0.8, 1.1) * (1 - phase(t, 2.6, 2.95))
            s.fileScale = 0.82 * (1 - 0.4 * gone)
            s.fileOpacity = Double(1 - gone)
            s.keyOpacity = Double(phase(t, 1.7, 2.0) * (1 - phase(t, 3.6, 4.0)))
            s.pointer = CGPoint(x: x(fromEdge: shelfWidth + 46), y: centerY + 46)
        }
        return s
    }

    // MARK: Zeichnen

    private func frame(at t: Double) -> some View {
        let s = pose(at: t)
        return ZStack(alignment: .topLeading) {
            // Gehäuse
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(white: 0.13))
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.25), radius: 10, y: 5)

            // Bildschirm
            ZStack(alignment: .topLeading) {
                LinearGradient(colors: [Color(red: 0.36, green: 0.47, blue: 0.86),
                                        Color(red: 0.62, green: 0.42, blue: 0.78),
                                        Color(red: 0.93, green: 0.62, blue: 0.55)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                // Menüleiste
                Rectangle()
                    .fill(Color.white.opacity(0.28))
                    .frame(height: 11)
                // Fenster einer anderen App
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color.white.opacity(0.9))
                    .overlay(alignment: .topLeading) {
                        HStack(spacing: 4) {
                            Circle().fill(Color(red: 1, green: 0.37, blue: 0.34))
                            Circle().fill(Color(red: 1, green: 0.74, blue: 0.18))
                            Circle().fill(Color(red: 0.16, green: 0.79, blue: 0.25))
                        }
                        .frame(width: 34, height: 8)
                        .padding(7)
                    }
                    .frame(width: 176, height: 118)
                    .shadow(color: .black.opacity(0.18), radius: 6, y: 3)
                    .position(windowCenter)

                // Die Ablage in ihrer echten Form
                if s.shelf > 0.5 {
                    EdgeBlobShape(edge: edge, cornerRadius: min(16, s.shelf * 0.5), fillet: 10)
                        .fill(Color.black)
                        .frame(width: s.shelf, height: shelfHeight)
                        .position(x: x(fromEdge: s.shelf / 2), y: centerY)
                    // weitere Objekte darin
                    VStack(spacing: 8) {
                        miniTile(symbol: "doc.fill", tint: Color(white: 0.85))
                        miniTile(symbol: "link", tint: Color(red: 0.35, green: 0.6, blue: 1))
                    }
                    .scaleEffect(0.82)
                    .opacity(s.shelf > shelfWidth * 0.8 ? s.otherTiles : 0)
                    .position(x: x(fromEdge: shelfWidth / 2 + 2), y: centerY + 30)
                }

                // Die Datei
                fileTile
                    .scaleEffect(s.fileScale)
                    .opacity(s.fileOpacity)
                    .position(s.file)

                // ⌘Z
                if s.keyOpacity > 0 {
                    HStack(spacing: 4) {
                        miniKey("⌘")
                        miniKey("Z")
                    }
                    .opacity(s.keyOpacity)
                    .position(x: windowCenter.x, y: windowCenter.y)
                }

                // Zeiger
                Image(systemName: "cursorarrow")
                    .font(.system(size: 17, weight: .regular))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.5), radius: 1, y: 1)
                    .opacity(s.pointerOpacity)
                    .position(s.pointer)
            }
            .frame(width: screen.width, height: screen.height)
            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            .offset(x: inset, y: inset)
        }
        .frame(width: size.width, height: size.height)
    }

    private var fileTile: some View {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(LinearGradient(colors: [Color(red: 1, green: 0.62, blue: 0.3), Color(red: 0.95, green: 0.35, blue: 0.45)],
                                 startPoint: .top, endPoint: .bottom))
            .overlay(
                Image(systemName: "photo.fill")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white)
            )
            .frame(width: 42, height: 42)
            .shadow(color: .black.opacity(0.3), radius: 3, y: 2)
    }

    private func miniTile(symbol: String, tint: Color) -> some View {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(Color.white.opacity(0.12))
            .overlay(
                Image(systemName: symbol)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(tint)
            )
            .frame(width: 42, height: 42)
    }

    private func miniKey(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(Color(white: 0.15))
            .frame(width: 34, height: 34)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color.white)
                    .shadow(color: .black.opacity(0.25), radius: 2, y: 1.5)
            )
    }
}

/// Drei Pfeile in Richtung Bildschirmrand, die nacheinander aufleuchten
private struct EdgeArrows: View {
    let edge: ScreenEdge

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: AnimationStyle.reduceMotion)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            HStack(spacing: 1) {
                ForEach(0..<3, id: \.self) { i in
                    let order = edge == .right ? Double(i) : Double(2 - i)
                    let wave = 0.5 + 0.5 * sin((t * 3.2) - order * 0.9)
                    Image(systemName: edge == .right ? "chevron.right" : "chevron.left")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(Color.secondary.opacity(AnimationStyle.reduceMotion ? 0.6 : 0.25 + 0.6 * wave))
                }
            }
        }
        .accessibilityHidden(true)
    }
}

/// Das Beispielbild als Kachel, zum Herausziehen wie aus dem Finder
private struct SampleTile: View {
    let url: URL?
    var onDragStarted: () -> Void = {}
    @State private var hovering = false

    var body: some View {
        preview
            .frame(width: 64, height: 64)
            .shadow(color: .black.opacity(0.25), radius: 4, y: 2)
            .scaleEffect(hovering ? 1.05 : 1)
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: hovering)
            .onHover { hovering = $0 }
            .overlay(
                Group {
                    if let url { SampleDragArea(url: url, onDragStarted: onDragStarted) }
                }
            )
            .help(L("Drag to the edge", "Zum Rand ziehen"))
    }

    @ViewBuilder
    private var preview: some View {
        if let url, let image = NSImage(contentsOf: url) {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
        } else {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.secondary.opacity(0.15))
        }
    }
}

/// Fläche, aus der sich die Beispieldatei wie aus dem Finder herausziehen lässt.
private struct SampleDragArea: NSViewRepresentable {
    let url: URL
    var onDragStarted: () -> Void

    func makeNSView(context: Context) -> SampleDragView {
        let view = SampleDragView()
        view.url = url
        view.onDragStarted = onDragStarted
        return view
    }

    func updateNSView(_ view: SampleDragView, context: Context) {
        view.url = url
        view.onDragStarted = onDragStarted
    }
}

final class SampleDragView: NSView, NSDraggingSource {
    var url: URL?
    var onDragStarted: () -> Void = {}
    private var downEvent: NSEvent?

    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .openHand)
    }

    override func mouseDown(with event: NSEvent) {
        downEvent = event
    }

    override func mouseUp(with event: NSEvent) {
        downEvent = nil
    }

    override func mouseDragged(with event: NSEvent) {
        guard let down = downEvent, let url else { return }
        downEvent = nil
        let item = NSDraggingItem(pasteboardWriter: url as NSURL)
        let image = NSImage(contentsOf: url) ?? NSWorkspace.shared.icon(forFile: url.path)
        let side: CGFloat = 84
        let point = convert(down.locationInWindow, from: nil)
        item.setDraggingFrame(NSRect(x: point.x - side / 2, y: point.y - side / 2, width: side, height: side),
                              contents: image)
        let session = beginDraggingSession(with: [item], event: down, source: self)
        // Nicht abgelegt: einfach verschwinden statt zur Karte zurückzuschnellen
        session.animatesToStartingPositionsOnCancelOrFail = false
        onDragStarted()
    }

    func draggingSession(_ session: NSDraggingSession, movedTo screenPoint: NSPoint) {
        // Takt der Ablage wach halten, solange gezogen wird
        onDragStarted()
    }

    func draggingSession(_ session: NSDraggingSession,
                         sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        .copy
    }
}

/// Fläche, in die das Bild aus der Ablage zurückgezogen wird. Nimmt nur Objekte an,
/// die aus der Ablage kommen, damit man genau das Herausziehen übt.
private struct ReturnDropZone: View {
    let onDrop: () -> Void
    @State private var targeted = false

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.primary.opacity(targeted ? 0.1 : 0.04))
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.secondary.opacity(targeted ? 0.8 : 0.45),
                              style: StrokeStyle(lineWidth: 1.5, dash: [6, 5]))
            HStack(spacing: 10) {
                Image(systemName: "tray.and.arrow.down")
                    .font(.system(size: 22, weight: .regular))
                    .foregroundStyle(Color.secondary.opacity(targeted ? 1 : 0.7))
                VStack(alignment: .leading, spacing: 2) {
                    Text(L("Your turn", "Jetzt du"))
                        .font(.system(size: 13, weight: .semibold))
                    Text(L("Drag the image from the shelf back here.", "Zieh das Bild aus der Ablage hierher zurück."))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(width: 360, height: 84)
        .scaleEffect(targeted ? 1.02 : 1)
        .animation(.spring(response: 0.3, dampingFraction: 0.75), value: targeted)
        .overlay(ReturnDropTarget(enabled: true, targeted: $targeted, onDrop: onDrop))
    }
}

private struct ReturnDropTarget: NSViewRepresentable {
    let enabled: Bool
    @Binding var targeted: Bool
    let onDrop: () -> Void

    func makeNSView(context: Context) -> ReturnDropView {
        let view = ReturnDropView()
        configure(view)
        return view
    }

    func updateNSView(_ view: ReturnDropView, context: Context) { configure(view) }

    private func configure(_ view: ReturnDropView) {
        view.enabled = enabled
        view.onTargeted = { value in if targeted != value { targeted = value } }
        view.onDrop = onDrop
    }
}

final class ReturnDropView: NSView {
    var enabled = true
    var onTargeted: (Bool) -> Void = { _ in }
    var onDrop: () -> Void = {}

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes(ShelfStore.acceptedTypes)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    /// Nur Objekte aus der Ablage
    private func accepts(_ sender: NSDraggingInfo) -> Bool {
        enabled && sender.draggingSource is DragSourceNSView
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard accepts(sender) else { return [] }
        onTargeted(true)
        Haptics.tap()
        return .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        accepts(sender) ? .copy : []
    }

    override func draggingExited(_ sender: NSDraggingInfo?) { onTargeted(false) }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard accepts(sender) else { return false }
        onTargeted(false)
        Haptics.drop()
        DispatchQueue.main.async { self.onDrop() }
        return true
    }

    override func concludeDragOperation(_ sender: NSDraggingInfo?) { onTargeted(false) }
}

