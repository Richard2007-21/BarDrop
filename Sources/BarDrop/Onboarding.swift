import AppKit
import SwiftUI
import Combine
import ServiceManagement
import Carbon

// MARK: Ablauf

/// Einführung beim ersten Start, aufgebaut wie eine Produktvorstellung: je Schritt eine
/// bewegte Szene mit der echten Ablage, eine Überschrift, ein Satz. Im Mittelpunkt steht
/// jeweils eine Übung (ablegen, herausziehen, Kurzbefehl), die von selbst erkennt, wann sie
/// geschafft ist. Farben, Schalter und Knöpfe wie in den Einstellungen.
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
    /// Abgedunkelter Hintergrund auf allen Bildschirmen: Klicks daneben öffnen keine andere
    /// App, die Einführung bleibt vorn, bis man sie beendet
    private var backdrops: [IntroBackdrop] = []
    /// Abdunkeln auch am Rand der Ablage, ohne dort Zeiger und Ziehen abzufangen
    private var bandShades: [IntroBandShade] = []
    private var screenObserver: NSObjectProtocol?
    private var edgeSubscription: AnyCancellable?
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
    /// Zeigt den Streifen am Rand, solange eine Übung ihn braucht.
    var showGuide: (Bool) -> Void = { _ in }

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
        showBackdrop()
        window?.center()
        window?.makeKeyAndOrderFront(nil)
    }

    // MARK: Hintergrund

    /// Über dem Dock, damit auch dort kein Klick eine App öffnet. Das Fenster der Einführung
    /// liegt darüber, die Ablage (Statusleistenebene) noch höher: Ablegen und Herausziehen
    /// am Bildschirmrand funktionieren wie immer.
    static let backdropLevel: NSWindow.Level = {
        let dock = Int(CGWindowLevelForKey(.dockWindow))
        // Nie über Menüs und nie so hoch, dass die Ablage nicht mehr darüber passt
        let level = min(dock + 1, NSWindow.Level.popUpMenu.rawValue - 3)
        Log.edge.info("Einführung: Dock-Ebene \(dock, privacy: .public), Hintergrund \(level, privacy: .public), Menüleiste \(NSWindow.Level.statusBar.rawValue, privacy: .public)")
        return NSWindow.Level(rawValue: level)
    }()

    private func showBackdrop() {
        let fresh = backdrops.isEmpty
        backdrops.forEach { $0.orderOut(nil) }
        bandShades.forEach { $0.orderOut(nil) }
        backdrops = NSScreen.screens.map { screen in
            let backdrop = IntroBackdrop(screen: screen, edge: settings.edge,
                                         shelfWidth: CGFloat(settings.shelfWidth))
            backdrop.onMove = { [weak self] in self?.wakeShelf() }
            backdrop.onClick = { [weak self] in self?.bringToFront() }
            backdrop.alphaValue = fresh ? 0 : 1
            backdrop.orderFrontRegardless()
            return backdrop
        }
        bandShades = NSScreen.screens.map { screen in
            let shade = IntroBandShade(screen: screen, edge: settings.edge,
                                       shelfWidth: CGFloat(settings.shelfWidth))
            shade.alphaValue = fresh ? 0 : 1
            shade.orderFrontRegardless()
            return shade
        }
        if fresh {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.25
                backdrops.forEach { $0.animator().alphaValue = 1 }
                bandShades.forEach { $0.animator().alphaValue = 1 }
            }
        }
        if edgeSubscription == nil {
            // Rand auf der ersten Seite gewechselt: der freie Bereich wandert mit
            edgeSubscription = settings.$edge.removeDuplicates().receive(on: RunLoop.main)
                .sink { [weak self] edge in
                    guard let self else { return }
                    let width = CGFloat(self.settings.shelfWidth)
                    self.backdrops.forEach { $0.update(edge: edge, shelfWidth: width) }
                    self.bandShades.forEach { $0.update(edge: edge, shelfWidth: width) }
                }
        }
        if screenObserver == nil {
            // Bildschirm angeschlossen oder umgestellt: Hintergrund neu verteilen
            screenObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
            ) { [weak self] _ in
                guard let self, !self.backdrops.isEmpty else { return }
                self.showBackdrop()
            }
        }
    }

    private func hideBackdrop() {
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        screenObserver = nil
        edgeSubscription = nil
        let leaving: [NSWindow] = backdrops + bandShades
        backdrops = []
        bandShades = []
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.2
            leaving.forEach { $0.animator().alphaValue = 0 }
        }, completionHandler: {
            leaving.forEach { $0.orderOut(nil) }
        })
    }

    /// Klick daneben: zurück zur Einführung
    private func bringToFront() {
        NSApp.activate(ignoringOtherApps: true)
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
        // Beim Ablegen und Herausziehen: zeigen, wo die Ablage wartet
        showGuide(step == .drop || step == .retrieve)
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
        switch model.step {
        case .drop:
            if entries.contains(where: { !baseline.contains($0.id) }) {
                model.complete(.drop)
            }
        default:
            break
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
        showGuide(false)
        hideBackdrop()
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
    /// feste Größe, mittig. Liegt über dem abgedunkelten Hintergrund (siehe `backdropLevel`), damit man beim Üben zum Rand ziehen kann.
    /// Ohne „private“ für den Test, der das echte Fenster abbildet
    func makeWindow() -> NSWindow {
        let window = IntroWindow(contentRect: NSRect(origin: .zero, size: Self.size),
                                 styleMask: [.titled, .closable, .fullSizeContentView],
                                 backing: .buffered, defer: false)
        // Ohne Minimieren: Der abgedunkelte Hintergrund bliebe sonst ohne Einführung stehen.
        // Der Knopf bleibt sichtbar, aber ausgegraut, wie Vergrößern bei fester Größe.
        window.standardWindowButton(.miniaturizeButton)?.isEnabled = false
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
        window.level = NSWindow.Level(rawValue: Self.backdropLevel.rawValue + 1)
        window.collectionBehavior = [.moveToActiveSpace]
        window.delegate = self
        let root = OnboardingView(model: model, openSettings: { [weak self] in
            self?.openSettings()
        })
        // Feste Größe: Die Ansicht darf das Fenster nicht verändern. Sonst übernimmt
        // NSHostingView Größenwünsche der Inhalte, und das Fenster kann wachsen.
        let host = NSHostingView(rootView: root.frame(width: Self.size.width, height: Self.size.height)
                                                  .ignoresSafeArea())
        host.sizingOptions = []
        window.contentView = host
        window.contentMinSize = Self.size
        window.contentMaxSize = Self.size
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
        // Das Symbol der App, ganz und ohne eigenen Rahmen: Es bringt seine Form selbst mit
        let side: CGFloat = 512
        let icon = NSWorkspace.shared.icon(forFile: Bundle.main.bundlePath)
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            icon.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
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

/// Abgedunkelte Fläche hinter der Einführung über einem Bildschirm, außer dem Streifen am
/// Rand der Ablage (den dunkelt `IntroBandShade` ab). Fängt Klicks ab,
/// nimmt nichts zum Ablegen an (Ziehen geht durch zur Ablage) und wird nie selbst aktiv.
final class IntroBackdrop: NSPanel {
    var onClick: () -> Void = {}

    var onMove: () -> Void = {}
    /// Gleichmäßig abgedunkelt, nahtlos an `IntroBandShade`
    private let shade = CALayer()
    private let screenFrame: CGRect
    /// Abdunkeln abseits des Rands
    static let dim: CGFloat = 0.42

    init(screen: NSScreen, edge: ScreenEdge, shelfWidth: CGFloat) {
        screenFrame = screen.frame
        super.init(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        level = OnboardingController.backdropLevel
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        let view = ClickCatcher()
        view.onClick = { [weak self] in self?.onClick() }
        view.onMove = { [weak self] in self?.onMove() }
        view.wantsLayer = true
        shade.frame = CGRect(origin: .zero, size: screen.frame.size)
        shade.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        view.layer?.addSublayer(shade)
        contentView = view
        update(edge: edge, shelfWidth: shelfWidth)
    }

    /// Der Streifen am Rand, an dem die Ablage erscheint, gehört nicht zu dieser Fläche:
    /// Dort verhalten sich Zeiger, Hinfahren und Ablegen genau wie sonst.
    func update(edge: ScreenEdge, shelfWidth: CGFloat) {
        setFrame(IntroBandShade.frames(screen: screenFrame, edge: edge, shelfWidth: shelfWidth).rest, display: true)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        shade.backgroundColor = NSColor.black.withAlphaComponent(Self.dim).cgColor
        CATransaction.commit()
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    private final class ClickCatcher: NSView {
        var onClick: () -> Void = {}
        var onMove: () -> Void = {}

        // Zeigerbewegungen über der Fläche gehen an BarDrop selbst, nicht an andere Apps:
        // Damit die Ablage trotzdem wach bleibt, hier melden
        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            trackingAreas.forEach(removeTrackingArea)
            addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeAlways, .inVisibleRect],
                                           owner: self, userInfo: nil))
        }

        override func mouseMoved(with event: NSEvent) { onMove() }
        override func mouseDown(with event: NSEvent) { onClick() }
        override func rightMouseDown(with event: NSEvent) { onClick() }
        override func otherMouseDown(with event: NSEvent) { onClick() }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    }
}

/// Abdunkeln des Streifens am Rand der Ablage, damit der ganze Bildschirm gleich dunkel
/// ist. Nimmt keine Maus- und Ziehereignisse an: Zeiger, Hinfahren und Ablegen gehen
/// durch zu dem, was darunter liegt, und die Ablage (darüber) bleibt hell.
final class IntroBandShade: NSPanel {
    private let screenFrame: CGRect

    init(screen: NSScreen, edge: ScreenEdge, shelfWidth: CGFloat) {
        screenFrame = screen.frame
        super.init(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        level = OnboardingController.backdropLevel
        isOpaque = false
        backgroundColor = NSColor.black.withAlphaComponent(IntroBackdrop.dim)
        hasShadow = false
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        ignoresMouseEvents = true
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        update(edge: edge, shelfWidth: shelfWidth)
    }

    func update(edge: ScreenEdge, shelfWidth: CGFloat) {
        setFrame(Self.frames(screen: screenFrame, edge: edge, shelfWidth: shelfWidth).band, display: true)
    }

    /// Aufteilung eines Bildschirms: Streifen am Rand (so breit wie das Fenster der Ablage)
    /// und der Rest
    static func frames(screen: CGRect, edge: ScreenEdge, shelfWidth: CGFloat) -> (band: CGRect, rest: CGRect) {
        let width = min(shelfWidth + ShelfMetrics.panelMargin, max(screen.width - 1, 1))
        var band = screen
        band.size.width = width
        var rest = screen
        rest.size.width = screen.width - width
        if edge == .right {
            band.origin.x = screen.maxX - width
        } else {
            rest.origin.x = screen.minX + width
        }
        return (band, rest)
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
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
                .padding(.top, 52)          // unter der Titelleiste mit den Fensterknöpfen

            footer
                .padding(.horizontal, 22)
                .frame(height: 64)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(SettingsTheme.contentBackdrop)
        .background(SettingsBackdrop().ignoresSafeArea())
        .ignoresSafeArea()
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

/// Eine Seite: Szene oben, Überschrift, ein Satz, darunter die Übung als eigene Karte.
private struct PresentationPage<Hero: View, Practice: View>: View {
    let title: String
    let text: String
    @ViewBuilder let hero: () -> Hero
    @ViewBuilder let practice: () -> Practice

    var body: some View {
        VStack(spacing: 0) {
            hero()
                .frame(height: DemoLayout.shown.height)
            Text(title)
                .font(.system(size: 22, weight: .semibold))
                .padding(.top, 16)
            Text(text)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 440)
                .padding(.top, 5)
            practice()
                .padding(.top, 18)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 30)
        .frame(maxWidth: .infinity)
    }
}

/// Die Übung einer Seite: hervorgehoben in der Akzentfarbe, damit klar ist, dass man hier
/// selbst etwas tut. Danach ein grüner Haken mit kurzer Bestätigung an derselben Stelle.
private struct TaskCard<Leading: View>: View {
    let done: Bool
    let instruction: String
    let confirmation: String
    /// Gestrichelt: die Karte selbst ist ein Ziel zum Ablegen
    var dashed = false
    /// Etwas wird gerade über die Karte gezogen
    var targeted = false
    @ViewBuilder let leading: () -> Leading

    static var size: CGSize { CGSize(width: 440, height: 112) }

    private var accent: Color { Color(nsColor: .controlAccentColor) }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(done ? Color.green.opacity(0.1) : accent.opacity(targeted ? 0.2 : 0.08))
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(done ? Color.green.opacity(0.5) : accent.opacity(targeted ? 0.95 : 0.55),
                              style: StrokeStyle(lineWidth: 1.5, dash: dashed && !done ? [6, 5] : []))
            if done {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 24))
                        .foregroundStyle(.white, .green)
                    Text(confirmation)
                        .font(.system(size: 14, weight: .medium))
                }
                .transition(.scale(scale: 0.8).combined(with: .opacity))
            } else {
                HStack(spacing: 16) {
                    leading()
                    VStack(alignment: .leading, spacing: 3) {
                        Text(L("Your turn", "Jetzt du"))
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(accent)
                        Text(instruction)
                            .font(.system(size: 13))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 20)
                .transition(.opacity)
            }
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .scaleEffect(targeted ? 1.02 : 1)
        .animation(.spring(response: 0.3, dampingFraction: 0.75), value: targeted)
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
            ShelfStage(scene: .overview)
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
            .frame(maxWidth: 440)
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
            ShelfStage(scene: .drop)
        } practice: {
            TaskCard(done: model.stepDone,
                     instruction: L("Drag this image to the \(edgeWord(settings)) edge of your screen and let go.",
                                    "Zieh dieses Bild an den \(edgeWord(settings)) Bildschirmrand und lass es dort los."),
                     confirmation: L("The image is in the shelf.", "Das Bild liegt in der Ablage.")) {
                SampleTile(url: model.sampleURL, edge: settings.edge, onDragStarted: model.onSampleDragStarted)
            }
        }
    }
}

// MARK: Herausziehen

private struct RetrievePage: View {
    @ObservedObject var model: OnboardingModel
    @ObservedObject var settings: AppSettings
    @State private var targeted = false

    /// Wie man die Ablage öffnet, passend zu den Einstellungen
    private var howToOpen: String {
        if settings.openMode == .click {
            return L("Move the pointer to the \(edgeWord(settings)) edge and click the strip. Then drag out what you need.",
                     "Fahr an den \(edgeWord(settings)) Rand und klick auf den Streifen. Dann ziehst du heraus, was du brauchst.")
        }
        return L("Move the pointer to the \(edgeWord(settings)) edge. The shelf opens, and you drag out what you need.",
                 "Fahr mit dem Zeiger an den \(edgeWord(settings)) Rand. Die Ablage öffnet sich, und du ziehst heraus, was du brauchst.")
    }

    var body: some View {
        PresentationPage(title: L("Drag Out", "Herausziehen"), text: howToOpen) {
            ShelfStage(scene: .dragOut)
        } practice: {
            TaskCard(done: model.stepDone,
                     instruction: L("Open the shelf and drag the image onto this box.",
                                    "Öffne die Ablage und zieh das Bild auf dieses Feld."),
                     confirmation: L("Works with any app.", "Klappt mit jeder App."),
                     dashed: true, targeted: targeted) {
                Image(systemName: "tray.and.arrow.down")
                    .font(.system(size: 30, weight: .regular))
                    .foregroundStyle(Color(nsColor: .controlAccentColor))
                    .frame(width: 72, height: 72)
            }
            .overlay(
                ReturnDropTarget(enabled: !model.stepDone, targeted: $targeted) {
                    model.complete(.retrieve)
                }
            )
        }
    }
}

// MARK: Kurzbefehl

private struct ShortcutPage: View {
    @ObservedObject var model: OnboardingModel
    @ObservedObject var settings: AppSettings

    var body: some View {
        PresentationPage(title: L("Open from Anywhere", "Von überall öffnen"),
                         text: L("The shortcut opens the shelf wherever you are. Press it again to close it. You can change it in Settings → Keyboard.",
                                 "Der Kurzbefehl öffnet die Ablage, egal wo du bist. Noch einmal, und sie geht wieder zu. Ändern kannst du ihn unter Einstellungen → Tastatur.")) {
            ShelfStage(scene: .shortcut)
        } practice: {
            TaskCard(done: model.stepDone,
                     instruction: L("Press \(settings.hotKeyDescription).", "Drück \(settings.hotKeyDescription)."),
                     confirmation: L("That’s it.", "Genau so.")) {
                KeyCaps(keys: ShortcutKeys.keys(settings), size: 46, pressed: false)
            }
        }
    }
}

/// Tasten als Kappen wie unter Einstellungen → Tastatur; nach dem Drücken in Akzentfarbe
struct KeyCaps: View {
    let keys: [(symbol: String, name: String)]
    let size: CGFloat
    let pressed: Bool
    @Environment(\.colorScheme) private var colorScheme

    /// Dunkel wie bisher, hell als weiße Tasten wie unter Einstellungen → Tastatur
    private var keyFill: Color {
        colorScheme == .dark ? Color.primary.opacity(0.1) : SettingsTheme.keyActive
    }
    private var keyBorder: Color {
        colorScheme == .dark ? Color.primary.opacity(0.1) : SettingsTheme.keyBorder
    }

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
                        .fill(pressed ? Color(nsColor: .controlAccentColor) : keyFill)
                        .shadow(color: .black.opacity(0.18), radius: 1.5, y: 1.5)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: size * 0.16, style: .continuous)
                        .strokeBorder(keyBorder, lineWidth: 1)
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

/// Das Beispielbild wie eine Datei im Finder: Bild und Name, zum Herausziehen. Es wippt
/// leicht in Richtung Bildschirmrand, daneben zeigen Pfeile dorthin.
private struct SampleTile: View {
    let url: URL?
    let edge: ScreenEdge
    var onDragStarted: () -> Void = {}
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            if edge == .left { EdgeArrows(edge: .left) }
            TimelineView(.animation(minimumInterval: 1.0 / 30, paused: AnimationStyle.reduceMotion || hovering)) { context in
                let t = context.date.timeIntervalSinceReferenceDate
                let nudge = AnimationStyle.reduceMotion || hovering ? 0 : CGFloat(max(0, sin(t * 2.6))) * 4
                tile
                    .offset(x: edge == .right ? nudge : -nudge)
            }
            if edge == .right { EdgeArrows(edge: .right) }
        }
    }

    private var tile: some View {
        VStack(spacing: 4) {
            preview
                .frame(width: 64, height: 64)
                .shadow(color: .black.opacity(0.25), radius: 4, y: 2)
            Text(url?.lastPathComponent ?? "")
                .font(.system(size: 11, weight: .medium))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 110)
        }
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
                .aspectRatio(contentMode: .fit)
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

