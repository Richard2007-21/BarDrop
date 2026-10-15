import AppKit
import SwiftUI
import Combine
import ServiceManagement
import Carbon

// MARK: Ablauf

/// Einführung beim ersten Start, gebaut wie die Einstellungen: links die Schritte, die sich
/// beim Schaffen abhaken, rechts dieselben Karten, Schalter und Knöpfe. Drei kurze Schritte
/// zum Mitmachen (ablegen, herausziehen, Kurzbefehl) erkennen von selbst, wann sie
/// geschafft sind. Zum Schluss zeigt sie in Karten, was BarDrop sonst kann.
final class OnboardingModel: ObservableObject {
    enum Step: Int, CaseIterable, Identifiable {
        case welcome, drop, retrieve, shortcut, features
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
    static let practice: [Step] = [.drop, .retrieve, .shortcut]

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
        default:
            break
        }
    }

    private func entriesChanged(_ entries: [ShelfEntry]) {
        let name = model.sampleURL?.lastPathComponent
        for entry in entries where entry.files.contains(where: { $0.url.lastPathComponent == name }) {
            if !baseline.contains(entry.id) { sampleEntries.insert(entry.id) }
        }
        guard model.step == .drop else { return }
        if entries.contains(where: { !baseline.contains($0.id) }) {
            model.complete(.drop)
        }
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
    static let size = NSSize(width: 680, height: 560)

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
        case .shortcut: return L("Shortcut", "Kurzbefehl")
        case .features: return L("Discover More", "Mehr entdecken")
        }
    }

    /// Symbol und Farbe wie die Bereiche der Einstellungen
    var symbol: String {
        switch self {
        case .welcome: return "hand.wave.fill"
        case .drop: return "tray.and.arrow.down.fill"
        case .retrieve: return "hand.draw.fill"
        case .shortcut: return "command"
        case .features: return "square.grid.2x2.fill"
        }
    }

    var tint: Color {
        switch self {
        case .welcome: return Color(red: 0.2, green: 0.47, blue: 1)
        case .drop: return Color(red: 1, green: 0.58, blue: 0.1)
        case .retrieve: return Color(red: 0.18, green: 0.68, blue: 0.75)
        case .shortcut: return Color(red: 0.55, green: 0.35, blue: 0.95)
        case .features: return Color(red: 0.2, green: 0.78, blue: 0.4)
        }
    }
}

/// Farbiges Quadrat mit Symbol, wie `PaneIcon` in den Einstellungen
private struct IntroIcon: View {
    let symbol: String
    let tint: Color
    var size: CGFloat = 22

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
            .fill(LinearGradient(colors: [tint.opacity(0.85), tint], startPoint: .top, endPoint: .bottom))
            .overlay(
                Image(systemName: symbol)
                    .font(.system(size: size * 0.5, weight: .semibold))
                    .foregroundStyle(.white)
            )
            .frame(width: size, height: size)
    }
}

struct OnboardingView: View {
    @ObservedObject var model: OnboardingModel
    /// Sprache, Rand und Einstellungen ändern alle Texte sofort
    @ObservedObject private var settings = AppSettings.shared
    var openSettings: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: 220)
                .frame(maxHeight: .infinity)
                .background(SettingsTheme.sidebar.opacity(SettingsTheme.backdropOpacity))
            Rectangle()
                .fill(SettingsTheme.divider)
                .frame(width: 1)
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(SettingsTheme.content.opacity(SettingsTheme.backdropOpacity))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(SettingsBackdrop().ignoresSafeArea())
        .ignoresSafeArea()
    }

    // MARK: Seitenleiste

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(nsImage: NSApp.applicationIconImage ?? NSImage())
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 34, height: 34)
                VStack(alignment: .leading, spacing: 1) {
                    Text("BarDrop")
                        .font(.system(size: 14, weight: .semibold))
                    Text(L("Introduction", "Einführung"))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.leading, 9)
            .padding(.bottom, 18)

            ForEach(OnboardingModel.Step.allCases) { step in
                IntroSidebarRow(step: step, selected: model.step == step,
                                done: model.completed.contains(step)) {
                    model.go(to: step)
                }
            }
            Spacer(minLength: 12)
            Text(L("You can find this introduction again in Settings → About BarDrop.",
                   "Diese Einführung findest du jederzeit unter Einstellungen → Über BarDrop."))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 9)
                .padding(.bottom, 18)
        }
        .padding(.horizontal, 13)
        .padding(.top, 56)
    }

    // MARK: Inhalt

    private var detail: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                IntroIcon(symbol: model.step.symbol, tint: model.step.tint, size: 24)
                Text(model.step.title)
                    .font(.system(size: 17, weight: .semibold))
                Spacer(minLength: 8)
                Text(L("\(model.step.rawValue + 1) of \(OnboardingModel.Step.allCases.count)",
                       "\(model.step.rawValue + 1) von \(OnboardingModel.Step.allCases.count)"))
                    .font(.system(size: 12))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(L("Step \(model.step.rawValue + 1) of \(OnboardingModel.Step.allCases.count)",
                                          "Schritt \(model.step.rawValue + 1) von \(OnboardingModel.Step.allCases.count)"))
            }
            .padding(.leading, 18)
            .padding(.trailing, 20)
            .frame(height: 52)
            .padding(.top, 4)

            page
                .id(model.step)
                .transition(.opacity)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            Rectangle()
                .fill(SettingsTheme.divider)
                .frame(height: 1)
            footer
                .padding(.horizontal, 20)
                .frame(height: 56)
        }
    }

    @ViewBuilder
    private var page: some View {
        switch model.step {
        case .welcome: WelcomePage(model: model, settings: settings)
        case .drop: DropPage(model: model, settings: settings)
        case .retrieve: RetrievePage(model: model, settings: settings)
        case .shortcut: ShortcutPage(model: model, settings: settings)
        case .features: FeaturesPage(settings: settings)
        }
    }

    // MARK: Knöpfe unten

    private var footer: some View {
        HStack(spacing: 8) {
            switch model.step {
            case .welcome:
                Button(L("Skip Introduction", "Einführung überspringen")) { model.onFinish(false) }
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
                Button(L("Open Settings", "Einstellungen öffnen")) {
                    openSettings()
                    model.advance()
                }
                .buttonStyle(KlackButtonStyle())
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

/// Eintrag der Seitenleiste: wie in den Einstellungen, rechts ein Haken für geschaffte Schritte.
private struct IntroSidebarRow: View {
    let step: OnboardingModel.Step
    let selected: Bool
    let done: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                IntroIcon(symbol: step.symbol, tint: step.tint)
                Text(step.title)
                    .font(.system(size: 14))
                    .foregroundStyle(.primary)
                Spacer(minLength: 0)
                if done {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(.white, .green)
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .padding(.horizontal, 9)
            .frame(height: 42)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(selected ? SettingsTheme.selectedRow : Color.primary.opacity(hovering ? 0.04 : 0))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

// MARK: Bausteine der Seiten

/// Zeile mit kleinem Symbol und Text, für Erklärungen in einer Karte
private struct IntroInfoRow: View {
    let symbol: String
    let title: String
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 11) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 22, height: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13.5))
                Text(text)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, SettingsTheme.rowPadding)
        .padding(.vertical, 10)
    }
}

/// Wort für den gewählten Rand im Satz („an den rechten Rand“)
private func edgeWord(_ settings: AppSettings) -> String {
    settings.edge == .right ? L("right", "rechten") : L("left", "linken")
}

/// Unter einer Übung: Anleitung, nach dem Schaffen die Bestätigung mit Haken
private struct PracticeNote: View {
    let done: Bool
    let instruction: String
    let confirmation: String

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            if done {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(.white, .green)
                    .transition(.scale.combined(with: .opacity))
            }
            Text(done ? confirmation : instruction)
                .font(.system(size: 12))
                .foregroundStyle(done ? Color.primary : Color.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .id(done)
                .transition(.opacity)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
    }
}

// MARK: Willkommen

private struct WelcomePage: View {
    @ObservedObject var model: OnboardingModel
    @ObservedObject var settings: AppSettings

    var body: some View {
        SettingsPage {
            SettingsCard {
                HStack(spacing: 14) {
                    Image(nsImage: NSApp.applicationIconImage ?? NSImage())
                        .resizable()
                        .interpolation(.high)
                        .frame(width: 52, height: 52)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(L("Welcome to BarDrop", "Willkommen bei BarDrop"))
                            .font(.system(size: 15, weight: .semibold))
                        Text(L("A place for files at the edge of your screen. Drag something there and it stays at hand until you need it.",
                               "Ein Platz für Dateien am Rand deines Bildschirms. Zieh etwas dorthin, und es bleibt griffbereit, bis du es brauchst."))
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, SettingsTheme.rowPadding)
                .padding(.vertical, 12)
            }

            SettingsSection(L("How it works", "So funktioniert es")) {
                IntroInfoRow(symbol: "1.circle.fill", title: L("Drop", "Ablegen"),
                             text: L("Drag a file, an image, a link or text to the \(edgeWord(settings)) edge of the screen. The shelf opens and you let go.",
                                     "Zieh eine Datei, ein Bild, einen Link oder Text an den \(edgeWord(settings)) Bildschirmrand. Die Ablage öffnet sich, und du lässt los."))
                IntroInfoRow(symbol: "2.circle.fill", title: L("Keep", "Aufbewahren"),
                             text: L("Everything stays there at hand, even after a restart.",
                                     "Alles bleibt dort griffbereit, auch nach einem Neustart."))
                IntroInfoRow(symbol: "3.circle.fill", title: L("Drag out", "Herausziehen"),
                             text: L("Move the pointer to the edge and drag it into any app.",
                                     "Fahr mit dem Zeiger an den Rand und zieh es in eine beliebige App."))
            }

            SettingsSection(L("Set up", "Einrichten"),
                            note: L("Next, try it out in three short steps.",
                                    "Danach probierst du es in drei kurzen Schritten aus.")) {
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
        }
    }
}

// MARK: Ablegen

private struct DropPage: View {
    @ObservedObject var model: OnboardingModel
    @ObservedObject var settings: AppSettings

    var body: some View {
        SettingsPage {
            VStack(alignment: .leading, spacing: 8) {
                SettingsHeader(L("Try it", "Probier es aus"))
                    .padding(.horizontal, 8)
                SettingsCard {
                    PracticeStage(edge: settings.edge) {
                        SampleTile(url: model.sampleURL, done: model.stepDone,
                                   onDragStarted: model.onSampleDragStarted)
                    }
                }
                PracticeNote(done: model.stepDone,
                             instruction: L("Drag the image to the \(edgeWord(settings)) edge of the screen. As soon as the shelf opens, let go.",
                                            "Zieh das Bild an den \(edgeWord(settings)) Bildschirmrand. Sobald sich die Ablage öffnet, lass es los."),
                             confirmation: L("The image is now in the shelf.", "Das Bild liegt jetzt in der Ablage."))
            }

            SettingsSection(L("Good to know", "Gut zu wissen")) {
                IntroInfoRow(symbol: "safari",
                             title: L("Not just files", "Nicht nur Dateien"),
                             text: L("Images from the browser, links and selected text work the same way.",
                                     "Bilder aus dem Browser, Links und markierter Text gehen genauso."))
                if settings.stackMultiple {
                    IntroInfoRow(symbol: "square.stack.fill",
                                 title: L("Several at once", "Mehrere auf einmal"),
                                 text: L("Several items dropped at once land together in a stack.",
                                         "Mehrere Objekte auf einmal landen zusammen in einem Stapel."))
                }
                IntroInfoRow(symbol: "doc.on.clipboard",
                             title: L("Paste", "Einfügen"),
                             text: L("In the open shelf, ⌘V adds what’s on the clipboard.",
                                     "In der offenen Ablage fügt ⌘V ein, was in der Zwischenablage liegt."))
            }
        }
    }
}

// MARK: Herausziehen

private struct RetrievePage: View {
    @ObservedObject var model: OnboardingModel
    @ObservedObject var settings: AppSettings

    /// Wie man die Ablage öffnet, passend zu den Einstellungen
    private var instruction: String {
        let open: String
        if settings.openMode == .click {
            open = L(" and click the strip", " und klick auf den Streifen")
        } else if settings.openDelay >= AppSettings.clickToOpenMinDelay - 0.01 {
            open = L(" and wait a moment or click the strip", " und warte kurz oder klick auf den Streifen")
        } else {
            open = ""
        }
        // „etwa auf halber Höhe“ als Einschub: das Komma danach nur, wenn noch etwas folgt
        let middle = settings.adaptiveZoneFraction != nil
            ? L(" around the middle", open.isEmpty ? ", etwa auf halber Höhe" : ", etwa auf halber Höhe,") : ""
        return L("Move the pointer to the \(edgeWord(settings)) edge\(middle)\(open). When the shelf opens, drag the image back here.",
                 "Fahr mit dem Zeiger an den \(edgeWord(settings)) Rand\(middle)\(open). Wenn sich die Ablage öffnet, zieh das Bild hierher zurück.")
    }

    var body: some View {
        SettingsPage {
            VStack(alignment: .leading, spacing: 8) {
                SettingsHeader(L("Try it", "Probier es aus"))
                    .padding(.horizontal, 8)
                SettingsCard {
                    PracticeStage(edge: settings.edge) {
                        ReturnDropZone(url: model.sampleURL, done: model.stepDone) {
                            model.complete(.retrieve)
                        }
                    }
                }
                PracticeNote(done: model.stepDone,
                             instruction: instruction,
                             confirmation: L("That’s how you use anything in the shelf: drag it out into any app.",
                                             "So verwendest du alles aus der Ablage: einfach in eine App herausziehen."))
            }

            SettingsSection(L("Good to know", "Gut zu wissen")) {
                if settings.removeAfterDragOut {
                    IntroInfoRow(symbol: "arrow.uturn.backward",
                                 title: L("Gone by mistake?", "Versehentlich weg?"),
                                 text: L("After you drag something out, it leaves the shelf. ⌘Z brings it back within 15 minutes.",
                                         "Nach dem Herausziehen verschwindet es aus der Ablage. ⌘Z holt es innerhalb von 15 Minuten zurück."))
                } else {
                    IntroInfoRow(symbol: "tray.full.fill",
                                 title: L("Stays in the shelf", "Bleibt in der Ablage"),
                                 text: L("Items stay in the shelf after you drag them out.",
                                         "Nach dem Herausziehen bleiben Objekte in der Ablage."))
                }
                IntroInfoRow(symbol: "cursorarrow.click.2",
                             title: L("Several at once", "Mehrere auf einmal"),
                             text: L("Select with ⌘-click or ⇧-click and drag them out together.",
                                     "Mit ⌘-Klick oder ⇧-Klick auswählen und zusammen herausziehen."))
                IntroInfoRow(symbol: "contextualmenu.and.cursorarrow",
                             title: L("More with a right-click", "Mehr per Rechtsklick"),
                             text: L("Open, Show in Finder, Copy, Share and Convert.",
                                     "Öffnen, Im Finder zeigen, Kopieren, Teilen und Umwandeln."))
            }
        }
    }
}

// MARK: Kurzbefehl

private struct ShortcutPage: View {
    @ObservedObject var model: OnboardingModel
    @ObservedObject var settings: AppSettings

    var body: some View {
        SettingsPage {
            VStack(alignment: .leading, spacing: 8) {
                SettingsHeader(L("Try it", "Probier es aus"))
                    .padding(.horizontal, 8)
                SettingsCard {
                    ShortcutKeys(settings: settings, pressed: model.stepDone)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 22)
                }
                PracticeNote(done: model.stepDone,
                             instruction: L("Press \(settings.hotKeyDescription) to open the shelf from anywhere, even without a mouse.",
                                            "Drück \(settings.hotKeyDescription), um die Ablage von überall zu öffnen, auch ohne Maus."),
                             confirmation: L("The same shortcut closes it again. You can change it in Settings → Keyboard.",
                                             "Derselbe Kurzbefehl schließt sie wieder. Ändern kannst du ihn unter Einstellungen → Tastatur."))
            }

            SettingsSection(L("In the open shelf", "In der offenen Ablage"),
                            note: L("All keyboard shortcuts are listed in Settings → Keyboard.",
                                    "Alle Tastenkürzel stehen unter Einstellungen → Tastatur.")) {
                ShortcutRow(L("Quick Look", "Übersicht"), [L("Space", "Leertaste")])
                ShortcutRow(L("Remove selection", "Auswahl entfernen"), ["⌫"])
                ShortcutRow(L("Undo", "Widerrufen"), ["⌘", "Z"])
                ShortcutRow(L("Clear selection, then close", "Auswahl aufheben, dann schließen"), ["esc"])
            }
        }
    }
}

/// Die Tasten des Kurzbefehls als Kappen wie unter Einstellungen → Tastatur.
/// Nach dem Drücken hell hervorgehoben.
private struct ShortcutKeys: View {
    @ObservedObject var settings: AppSettings
    let pressed: Bool

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
        HStack(spacing: 8) {
            ForEach(Array(keys.enumerated()), id: \.offset) { _, key in
                VStack(alignment: .leading, spacing: 0) {
                    if key.name.isEmpty {
                        Text(key.symbol)
                            .font(.system(size: 19, weight: .medium))
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        Text(key.symbol).font(.system(size: 14, weight: .medium))
                        Spacer(minLength: 0)
                        Text(key.name).font(.system(size: 12, weight: .medium))
                    }
                }
                .foregroundStyle(pressed ? Color.white : Color.primary)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .frame(width: key.name.isEmpty ? 62 : 74, height: 62, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(pressed ? Color(nsColor: .controlAccentColor) : Color.black.opacity(0.32))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.06), lineWidth: 1)
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
    private var cleanupText: String {
        let hours = Int(settings.autoRemoveAfter / 3_600)
        if hours <= 0 {
            return L("Items stay until you remove them. They can also disappear by themselves after a few hours (Settings → Items).",
                     "Objekte bleiben, bis du sie entfernst. Auf Wunsch verschwinden sie nach einigen Stunden von selbst (Einstellungen → Objekte).")
        }
        let after = hours == 1 ? L("1 hour", "1 Stunde") : L("\(hours) hours", "\(hours) Stunden")
        return L("Items disappear by themselves after \(after). You can change this in Settings → Items.",
                 "Objekte verschwinden nach \(after) von selbst. Ändern kannst du das unter Einstellungen → Objekte.")
    }

    private var features: [Feature] {
        var list = [
            Feature(id: "actions", symbol: "paperplane.fill", tint: Color(red: 0.2, green: 0.47, blue: 1),
                    title: L("Action bar", "Aktionsleiste"),
                    text: L("Drag items onto AirDrop, a folder or the Trash at the bottom of the shelf, or select them and click an action.",
                            "Zieh Objekte unten in der Ablage auf AirDrop, einen Ordner oder den Papierkorb, oder wähl sie aus und klick auf eine Aktion."))
        ]
        if settings.stackMultiple {
            list.append(Feature(id: "stack", symbol: "square.stack.fill", tint: Color(red: 0.18, green: 0.68, blue: 0.75),
                                title: L("Stacks", "Stapel"),
                                text: L("Several items dropped at once land in a stack. Click it to open it.",
                                        "Mehrere Objekte auf einmal landen in einem Stapel. Ein Klick öffnet ihn.")))
        }
        list.append(Feature(id: "convert", symbol: "arrow.triangle.2.circlepath", tint: Color(red: 0.2, green: 0.78, blue: 0.4),
                            title: L("Convert", "Umwandeln"),
                            text: L("Right-click an item to turn images into JPEG or PDF, resize them and more.",
                                    "Rechtsklick auf ein Objekt, um Bilder in JPEG oder PDF umzuwandeln, zu verkleinern und mehr.")))
        if settings.pinFromShelf {
            list.append(Feature(id: "pin", symbol: "pin.fill", tint: Color(red: 0.95, green: 0.6, blue: 0.1),
                                title: L("Pin", "Anheften"),
                                text: L("Drag a folder or app over the shelf and drop it on “Pin” at the end of the action bar.",
                                        "Zieh einen Ordner oder eine App über die Ablage und lass sie auf „Anheften“ am Ende der Aktionsleiste los.")))
        }
        list.append(Feature(id: "cleanup", symbol: "clock.fill", tint: Color(red: 0.92, green: 0.3, blue: 0.55),
                            title: L("Cleanup", "Aufräumen"), text: cleanupText))
        list.append(Feature(id: "settings", symbol: "gearshape.fill", tint: Color(white: 0.55),
                            title: L("Settings", "Einstellungen"),
                            text: L("Right-click an empty spot in the shelf, press ⌘, there, or simply open BarDrop again.",
                                    "Rechtsklick auf eine leere Stelle der Ablage, dort ⌘, drücken oder BarDrop einfach noch einmal öffnen.")))
        return list
    }

    private let columns = [GridItem(.flexible(), spacing: 10, alignment: .top),
                           GridItem(.flexible(), spacing: 10, alignment: .top)]

    var body: some View {
        SettingsPage {
            LazyVGrid(columns: columns, alignment: .leading, spacing: 10) {
                ForEach(features) { feature in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 9) {
                            IntroIcon(symbol: feature.symbol, tint: feature.tint, size: 24)
                            Text(feature.title)
                                .font(.system(size: 13.5, weight: .semibold))
                        }
                        Text(feature.text)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, minHeight: 108, alignment: .topLeading)
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
        }
    }
}

// MARK: Bühne der Übungen

/// Fläche einer Übung: links der Inhalt, zum Rand hin Pfeile und ein Stück Bildschirmrand
/// mit dem schwarzen Streifen, damit klar ist, wohin es geht.
private struct PracticeStage<Content: View>: View {
    let edge: ScreenEdge
    @ViewBuilder let content: () -> Content

    var body: some View {
        HStack(spacing: 18) {
            if edge == .left {
                edgeHint
                arrows
            }
            content()
                .frame(maxWidth: .infinity)
            if edge == .right {
                arrows
                edgeHint
            }
        }
        .padding(.horizontal, 16)
        .frame(height: 196)
    }

    /// Bildschirmrand mit Streifen
    private var edgeHint: some View {
        ZStack(alignment: edge == .right ? .trailing : .leading) {
            Rectangle()
                .fill(SettingsTheme.separator)
                .frame(width: 2)
            UnevenRoundedRectangle(cornerRadii: edge == .right
                                   ? .init(topLeading: 5, bottomLeading: 5)
                                   : .init(bottomTrailing: 5, topTrailing: 5),
                                   style: .continuous)
                .fill(Color.black)
                .frame(width: 8, height: 64)
        }
        .frame(width: 10, height: 160)
    }

    /// Drei Pfeile, die nacheinander aufleuchten
    private var arrows: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: AnimationStyle.reduceMotion)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            HStack(spacing: 2) {
                ForEach(0..<3, id: \.self) { i in
                    let order = edge == .right ? Double(i) : Double(2 - i)
                    let wave = 0.5 + 0.5 * sin((t * 3.2) - order * 0.9)
                    Image(systemName: edge == .right ? "chevron.right" : "chevron.left")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(Color.secondary.opacity(AnimationStyle.reduceMotion ? 0.6 : 0.25 + 0.6 * wave))
                }
            }
        }
    }
}

/// Das Beispielbild als Kachel wie im Finder, zum Herausziehen
private struct SampleTile: View {
    let url: URL?
    let done: Bool
    var onDragStarted: () -> Void = {}

    var body: some View {
        VStack(spacing: 6) {
            preview
                .frame(width: 84, height: 84)
                .shadow(color: .black.opacity(0.25), radius: 4, y: 2)
            Text(url?.lastPathComponent ?? L("Image", "Bild"))
                .font(.system(size: 11, weight: .medium))
                .lineLimit(2)
                .truncationMode(.middle)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 140)
        }
        .padding(10)
        .opacity(done ? 0.35 : 1)
        .overlay(
            Group {
                if let url, !done { SampleDragArea(url: url, onDragStarted: onDragStarted) }
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
            RoundedRectangle(cornerRadius: 18, style: .continuous)
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
    let url: URL?
    let done: Bool
    let onDrop: () -> Void
    @State private var targeted = false

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.primary.opacity(targeted ? 0.1 : 0.04))
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.secondary.opacity(targeted ? 0.8 : 0.45),
                              style: StrokeStyle(lineWidth: 1.5, dash: [6, 5]))
                .opacity(done ? 0 : 1)

            if done {
                ZStack(alignment: .bottomTrailing) {
                    preview
                        .frame(width: 84, height: 84)
                        .shadow(color: .black.opacity(0.25), radius: 4, y: 2)
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 30))
                        .foregroundStyle(.white, .green)
                        .offset(x: 10, y: 10)
                        .transition(.scale.combined(with: .opacity))
                }
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "tray.and.arrow.down")
                        .font(.system(size: 28, weight: .regular))
                        .foregroundStyle(Color.secondary.opacity(targeted ? 1 : 0.7))
                    Text(L("Drag the image back here", "Zieh das Bild hierher zurück"))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: 260, maxHeight: 160)
        .scaleEffect(targeted ? 1.02 : 1)
        .animation(.spring(response: 0.3, dampingFraction: 0.75), value: targeted)
        .overlay(ReturnDropTarget(enabled: !done, targeted: $targeted, onDrop: onDrop))
    }

    @ViewBuilder
    private var preview: some View {
        if let url, let image = NSImage(contentsOf: url) {
            Image(nsImage: image).resizable().interpolation(.high)
        } else {
            RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color.secondary.opacity(0.15))
        }
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

