import AppKit
import SwiftUI
import Combine
import Quartz

/// Steuert, wann und wo die Ablage am Rand auftaucht: beim Ziehen von Dateien,
/// beim Berühren des Rands mit dem Mauszeiger und per Kurzbefehl.
///
/// Es gibt genau ein Fenster. Es wandert zum Bildschirm, auf dem sich der Zeiger
/// befindet, aber erst, wenn die Ablage dort vollständig verschwunden ist. So ist
/// sie nie auf zwei Bildschirmen gleichzeitig zu sehen und springt nicht mitten
/// in einer Animation.
///
/// Energie: Solange etwas passiert, läuft ein Takt mit 60 Hz. Im Ruhezustand
/// (verborgen, Zeiger weit vom Rand) steht er still. Dann meldet macOS selbst,
/// wenn sich der Zeiger dem Rand nähert oder ein Ziehen beginnt (nach boring.notch,
/// DragDetector). Die Entscheidungen selbst trifft `EdgeLogic`.
final class EdgeController: NSObject {
    let ui: ShelfUIModel
    let store: ShelfStore
    let settings: AppSettings
    let actions: ShelfActions
    let panel: ShelfPanel

    /// true, solange z. B. das Einstellungsfenster die App aktiv halten soll.
    var keepAppActive: () -> Bool = { false }

    private var screen: NSScreen?
    /// Bildschirm, an dessen Rand die Ablage gerade erscheint (für die Einführung)
    var shelfScreen: NSScreen? { Self.fresh(screen) ?? allowedScreens().first }
    /// Bildschirm, an dem die Ablage gerade sitzt (dort öffnen auch die Einstellungen)
    var currentScreen: NSScreen? { Self.fresh(screen) }
    /// Zuletzt geprüft, ob das gemerkte Bildschirm-Objekt noch aktuell ist
    private var screenCheckedAt = Date.distantPast
    private var logic = EdgeLogic.State()
    private var previewUntil: Date?
    /// Welche Stufe die Vorschau beim Ändern der Einstellungen zeigt
    private var previewLevel: ShelfUIModel.Level = .hint
    /// Einführung: Der Streifen bleibt zu sehen, damit man weiß, wohin man ziehen soll
    private var guideActive = false
    /// Stufe, die die Einführung zeigen lässt: offen oder nur der Streifen
    private var guideLevel: ShelfUIModel.Level = .peek
    /// Die Vorschau nach dem Verstellen der Symbolgröße läuft noch (nicht `previewUntil`:
    /// In der Einführung folgt darauf gleich wieder der Streifen)
    private var samplePreviewRunning = false
    /// Neu anordnen, sobald die Ablage ganz verborgen ist
    private var relayoutWhenHidden = false
    private var lastPeekSignature = ""
    private var lastSizeSignature = ""
    /// Adaptive Höhe: Zeigerhöhe, an der die Ablage erscheinen soll.
    private var adaptiveY: CGFloat?
    private var lastLayoutSignature = ""
    /// Rand beim letzten Anordnen: Ein Wechsel wird anders gezeigt als andere Änderungen
    private var lastEdge: ScreenEdge?
    private var acceptsMouse = false

    // Takt: 60 Hz, solange etwas passiert; im Ruhezustand aus
    private var tickTimer: Timer?
    private static let interval: TimeInterval = 1.0 / 60.0
    private let dragPasteboard = NSPasteboard(name: .drag)
    /// Stand des Drag-Pasteboards beim letzten Drücken der Maustaste
    private var dragBaseline = NSPasteboard(name: .drag).changeCount
    private var monitors: [Any] = []
    private var layoutDirty = false
    private var edgeObserver: AnyCancellable?
    /// Die Ablage wird gerade an der Kopfzeile gezogen (siehe EdgeTear)
    var tearDrag: TearDrag?
    /// Begleitfenster mit dem Glas der losgelösten Ablage (erst bei Bedarf angelegt)
    var glassWindow: ShelfGlassWindow?
    /// Letzte Prüfung, ob ein fremdes Fenster über der schwebenden Ablage liegt
    var coverCheck: (time: Date, point: NSPoint, covered: Bool) = (.distantPast, .zero, false)
    var tearTimer: Timer?
    /// Der Rand wurde durch Andocken gewechselt: ohne Verschwinden und neu Erscheinen
    var dockingEdgeChange = false
    private var settingsObserver: AnyCancellable?
    private var contentObserver: AnyCancellable?
    private var tileObserver: AnyCancellable?
    private var appObserver: NSObjectProtocol?
    private var excludedObserver: AnyCancellable?
    /// Die App vorn ist ausgenommen: Der Rand öffnet die Ablage dann nicht
    private var frontmostExcluded = false
    /// Bildschirme, auf denen die App vorn gerade im Vollbild ist (nur wenn das
    /// Öffnen im Vollbild ausgeschaltet ist, sonst leer)
    private var fullScreenFrames: [CGRect] = []
    private var spaceObserver: NSObjectProtocol?
    private var resignObserver: NSObjectProtocol?
    private var terminateObserver: NSObjectProtocol?
    private var fullScreenObserver: AnyCancellable?

    /// Bildschirme, die gerade einen Vollbild-Schreibtisch zeigen. Gefragt wird macOS
    /// selbst, welche Art Schreibtisch aktiv ist, nicht die Fenstergröße: Ein Fenster, das
    /// nur den Bildschirm ausfüllt, ist kein Vollbild. Läuft nur beim App- oder
    /// Schreibtischwechsel, nicht im Takt.
    private func updateFullScreen(enabled: Bool? = nil) {
        let open = enabled ?? settings.openInFullScreen
        guard !open, let spaces = FullScreenSpaces.displays() else {
            fullScreenFrames = []
            return
        }
        fullScreenFrames = NSScreen.screens
            .filter { spaces.all || spaces.uuids.contains(FullScreenSpaces.uuid(of: $0) ?? "") }
            .map(\.frame)
    }

    private func updateFrontmostExcluded(_ excluded: [String]? = nil) {
        let list = excluded ?? settings.excludedApps
        let id = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        frontmostExcluded = id.map(list.contains) ?? false
    }
    /// Fokus zurückgeben, sobald ein eigener Drag beendet ist.
    private var pendingResignFocus = false
    /// Der Zeiger war im letzten Takt über der offenen Ablage
    private var pointerInside = false
    /// Die Übersicht war im letzten Takt offen
    private var quickLookWasVisible = false

    /// Objekte, deren Vorschaubild schon geladen wird oder beim Start da waren
    private var knownFileIDs: Set<UUID>?

    /// Dauer der Schließanimation; erst danach darf das Fenster den Bildschirm wechseln.
    private let collapseDuration: TimeInterval = 0.35

    init(store: ShelfStore, ui: ShelfUIModel, settings: AppSettings) {
        self.store = store
        self.ui = ui
        self.settings = settings
        self.actions = ShelfActions(store: store, ui: ui, settings: settings)
        self.panel = ShelfPanel()
        self.lastTileIconSize = settings.tileIconSize
        super.init()

        actions.panel = panel
        panel.actions = actions
        panel.onEscape = { [weak self] in self?.close() }
        actions.isFloating = { [weak self] in self?.isFloating ?? false }
        actions.returnToEdge = { [weak self] in self?.returnFloatingToEdge(close: false) }

        let host = ShelfHostingView(rootView: ShelfRootView(ui: ui, store: store, settings: settings, actions: actions))
        let dropHandler = ShelfDropHandler(store: store, ui: ui)
        dropHandler.actions = actions
        host.dropHandler = dropHandler
        panel.contentView = host

        panel.ignoresMouseEvents = true
        screen = screenUnderMouse() ?? allowedScreens().first
        lastLayoutSignature = settings.layoutSignature
        lastEdge = settings.edge
        lastPeekSignature = settings.peekSignature
        lastSizeSignature = settings.sizeSignature
        layoutPanel()
        panel.orderFrontRegardless()

        installMonitors()
        // Ausgenommene Apps: merken, ob gerade eine davon vorn ist (nicht in jedem Takt fragen)
        appObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.updateFrontmostExcluded()
            self?.updateFullScreen()
        }
        // Vollbild hat einen eigenen Schreibtisch: nach dem Wechsel (und der Animation) prüfen
        spaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.updateFullScreen()
            // Die Vollbild-Animation kann länger dauern: zweimal nachsehen
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { self?.updateFullScreen() }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { self?.updateFullScreen() }
        }
        // Eine Vollbild-App wird beendet: Ihr Schreibtisch verschwindet
        terminateObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.updateFullScreen() }
        fullScreenObserver = settings.$openInFullScreen
            .receive(on: DispatchQueue.main)
            .sink { [weak self] open in self?.updateFullScreen(enabled: open) }
        excludedObserver = settings.$excludedApps
            .receive(on: DispatchQueue.main)
            .sink { [weak self] list in self?.updateFrontmostExcluded(list) }
        wake()
        settingsObserver = settings.objectWillChange.sink { [weak self] _ in
            self?.layoutDirty = true
            DispatchQueue.main.async { self?.wake() }
        }
        // Rand gewechselt: sofort unsichtbar, noch bevor SwiftUI neu zeichnet. Sonst stand
        // der Inhalt für ein Bild schon am neuen Rand, das Fenster aber noch am alten, und
        // mitten auf dem Bildschirm blitzte ein Strich auf (Bildschirmaufnahme). Wieder
        // sichtbar macht es der Umzug im Takt; zur Sicherheit spätestens nach einer Sekunde.
        edgeObserver = settings.$edge.dropFirst().removeDuplicates().sink { [weak self] _ in
            guard let self, !self.dockingEdgeChange else { return }
            // Schwebt oder hängt die Ablage gerade, zurück an den Rand; dann wie sonst
            self.endTearImmediately()
            self.panel.alphaValue = 0
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                guard let self, self.panel.alphaValue == 0 else { return }
                self.panel.alphaValue = 1
            }
        }
        // Neuer Inhalt, der erst später fertig wird (Bilder aus dem Web, große Dateien,
        // iCloud): Ohne Fokus zeichnet macOS das Fenster teils erst beim nächsten Öffnen
        // neu. Deshalb hier selbst neu zeichnen, sobald sich der Inhalt ändert.
        contentObserver = store.$entries.map { _ in () }
            .merge(with: store.$pendingImports.map { _ in () })
            .merge(with: actions.plugins.$jobs.map { _ in () })
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in
                guard let self else { return }
                // Vorschaubilder neu dazugekommener Objekte gleich laden (siehe
                // Thumbnails.prefetch); was beim Start schon da war, lädt wie bisher beim Öffnen
                let files = self.store.entries.flatMap(\.files)
                if let known = self.knownFileIDs {
                    Thumbnails.prefetch(files.filter { !known.contains($0.id) }.map(\.url),
                                        size: CGFloat(self.settings.tileIconSize))
                }
                self.knownFileIDs = Set(files.map(\.id))
                self.refreshContent()
            }
        // Dasselbe für Änderungen innerhalb der Kacheln, die später kommen als der Eintrag
        // selbst: Eine neue Kachel zeigt ihr Bild erst, wenn das Vorschaubild da ist (bzw.
        // nach einem kurzen Moment). Ohne Neuzeichnen bliebe sie bis zum nächsten Öffnen leer.
        // Viele Kacheln auf einmal (Öffnen einer vollen Ablage): höchstens alle 30 ms
        tileObserver = NotificationCenter.default.publisher(for: Thumbnails.didChange)
            .throttle(for: .milliseconds(30), scheduler: DispatchQueue.main, latest: true)
            .sink { [weak self] _ in self?.redrawContent() }

        let cleanup = Timer(timeInterval: 60, target: self, selector: #selector(removeExpired), userInfo: nil, repeats: true)
        RunLoop.main.add(cleanup, forMode: .common)
        removeExpired()

        NotificationCenter.default.addObserver(self, selector: #selector(screensChanged),
                                               name: NSApplication.didChangeScreenParametersNotification,
                                               object: nil)
        // Nach dem Entsperren, Aufwachen oder Benutzerwechsel ordnet macOS die Bildschirme teils
        // neu an, ohne dass die Ablage es sonst mitbekommt
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification,
                     NSWorkspace.sessionDidBecomeActiveNotification] {
            NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(screensChanged),
                                                              name: name, object: nil)
        }
    }

    // MARK: Ereignisse des Systems

    private func installMonitors() {
        let mask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDown, .leftMouseDragged, .leftMouseUp,
                                           .rightMouseDown, .otherMouseDown]
        if let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] event in
            self?.handle(event, global: true)
        }) {
            monitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] event in
            guard let self else { return event }
            // Ziehen an der Kopfzeile behält BarDrop für sich (siehe tearEvent)
            guard let passed = self.tearEvent(event) else { return nil }
            self.handle(passed, global: false)
            return passed
        }) {
            monitors.append(local)
        }
        // Übersicht offen und BarDrop verliert den Fokus (andere App, ⌘⇥): Übersicht und
        // Ablage schließen, wie im Finder
        resignObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            // Erst nachdem macOS den neuen Fokus vergeben hat. Ist BarDrop danach noch die
            // vorderste App, war es nur ein Übergang (etwa während BarDrop für die Übersicht
            // aktiv wird) und kein Wechsel zu einer anderen App
            DispatchQueue.main.async {
                guard !AppActivation.isFrontmost else { return }
                self?.closeQuickLookAndShelf()
            }
        }
    }

    /// Klick neben Übersicht und Ablage: beide schließen. Klicks in anderen Apps kommen
    /// über den globalen Beobachter, Klicks in eigene Fenster (Einstellungen) über den lokalen.
    private func clickedWhileQuickLook(_ event: NSEvent, global: Bool) {
        guard actions.isQuickLookVisible, !ui.isLocked, NSApp.modalWindow == nil else { return }
        if !global {
            // Eigene Ablage, Übersicht und Menüs (liegen über den normalen Fenstern)
            if event.window === panel || event.window is QLPreviewPanel { return }
            if let level = event.window?.level, level.rawValue >= NSWindow.Level.popUpMenu.rawValue { return }
        }
        closeQuickLookAndShelf()
    }

    private func closeQuickLookAndShelf() {
        // Nach dem eigenen Stand: Wechselt man die App, blendet macOS die Übersicht schon
        // selbst aus, sie ist dann nicht mehr zu sehen
        guard actions.quickLookRequested else { return }
        actions.closeQuickLook()
        if ui.level == .expanded { close() }
    }

    private func handle(_ event: NSEvent, global: Bool) {
        switch event.type {
        case .rightMouseDown, .otherMouseDown:
            clickedWhileQuickLook(event, global: global)
        case .leftMouseDown:
            clickedWhileQuickLook(event, global: global)
            // Neuer Ausgangsstand: Ändert sich das Drag-Pasteboard danach, wird etwas gezogen
            dragBaseline = dragPasteboard.changeCount
        case .leftMouseDragged:
            // Nur wecken; ausgewertet wird im Takt. Zieh-Ereignisse anderer Apps werden
            // nur beobachtet, nie verzögert oder verändert.
            guard tickTimer == nil, dragPasteboard.changeCount != dragBaseline, hasDroppableContent() else { return }
            wake()
        case .mouseMoved:
            guard tickTimer == nil, isNearEdge(NSEvent.mouseLocation) else { return }
            wake()
        default:
            break
        }
    }

    /// Wird etwas gezogen, das die Ablage annehmen kann? Fenster und markierter Text
    /// ändern das Drag-Pasteboard nicht oder enthalten nichts davon.
    private func hasDroppableContent() -> Bool {
        let count = dragPasteboard.changeCount
        if let cached = droppableCache, cached.count == count { return cached.value }
        let accepted = Set(ShelfStore.acceptedTypes)
        let value = dragPasteboard.types?.contains(where: accepted.contains) ?? false
        droppableCache = (count, value)
        return value
    }
    /// Ergebnis der letzten Prüfung je Stand des Drag-Pasteboards (spart Abfragen im Takt)
    private var droppableCache: (count: Int, value: Bool)?

    private func isNearEdge(_ loc: NSPoint) -> Bool {
        guard let s = Self.screen(containing: loc, in: allowedScreens()) else { return false }
        let dx = settings.edge == .right ? s.frame.maxX - loc.x : loc.x - s.frame.minX
        return dx <= EdgeLogic.wakeDistance
    }

    /// Startet den Takt (falls er ruht).
    func wake() {
        guard tickTimer == nil else { return }
        let timer = Timer(timeInterval: Self.interval, target: self, selector: #selector(tick), userInfo: nil, repeats: true)
        timer.tolerance = 0.004
        RunLoop.main.add(timer, forMode: .common)
        tickTimer = timer
        tick()
    }

    private func pauseTicking() {
        tickTimer?.invalidate()
        tickTimer = nil
    }

    // MARK: Bildschirme

    private func allowedScreens() -> [NSScreen] {
        let all = NSScreen.screens
        let filtered = all.filter { settings.displayMode.allows($0) }
        return filtered.isEmpty ? all : filtered
    }

    /// Bildschirm unter dem Zeiger, sofern BarDrop dort verfügbar ist.
    private func screenUnderMouse() -> NSScreen? {
        Self.screen(containing: NSEvent.mouseLocation, in: allowedScreens())
    }

    /// Bildschirm an einem Punkt. Am äußersten Rand meldet macOS den Zeiger teils einen
    /// Punkt außerhalb des Bildschirms; dann zählt der nächstgelegene (höchstens 2 pt entfernt).
    static func screen(containing point: NSPoint, in screens: [NSScreen]) -> NSScreen? {
        if let exact = screens.first(where: { NSMouseInRect(point, $0.frame, false) }) { return exact }
        return screens
            .map { ($0, distance(point, $0.frame)) }
            .filter { $0.1 <= 2 }
            .min { $0.1 < $1.1 }?.0
    }

    private static func distance(_ p: NSPoint, _ r: NSRect) -> CGFloat {
        let dx = max(r.minX - p.x, 0, p.x - r.maxX)
        let dy = max(r.minY - p.y, 0, p.y - r.maxY)
        return hypot(dx, dy)
    }

    /// Derselbe Bildschirm? Nach Ruhezustand oder Änderungen liefert macOS teils neue
    /// NSScreen-Objekte für denselben Bildschirm; verglichen wird deshalb die Kennung.
    private static func same(_ a: NSScreen?, _ b: NSScreen?) -> Bool {
        guard let a, let b else { return a == nil && b == nil }
        return a.displayID == b.displayID
    }

    /// Das aktuelle Objekt desselben Bildschirms. Ändert sich die Anordnung (Monitor ab- oder
    /// angesteckt, Mac entsperrt, Auflösung geändert), legt macOS neue NSScreen-Objekte an; ein
    /// gemerktes altes kann dann noch die frühere Lage melden. Dann lag die Ablage außerhalb,
    /// der Rand reagierte nicht mehr und die Einstellungen öffneten halb neben dem Bildschirm.
    static func fresh(_ screen: NSScreen?) -> NSScreen? {
        guard let screen else { return nil }
        return NSScreen.screens.first { same($0, screen) }
    }

    /// Zuletzt verarbeitete Anordnung der Bildschirme (Kennung, Rahmen, sichtbarer Bereich)
    private var lastScreenSignature: String?
    private var screenChangeWork: DispatchWorkItem?
    /// Meldungen ohne Änderung seit dem letzten Eintrag im Diagnoseprotokoll
    private var unchangedScreenNotices = 0
    private var lastUnchangedReport = Date.distantPast

    static func screenSignature(_ screens: [NSScreen]) -> String {
        screens.map { s in
            let f = s.frame, v = s.visibleFrame
            return "\(s.displayID ?? 0):\(Int(f.minX)),\(Int(f.minY)),\(Int(f.width)),\(Int(f.height))/\(Int(v.minX)),\(Int(v.minY)),\(Int(v.width)),\(Int(v.height))"
        }.joined(separator: "|")
    }

    /// macOS meldet geänderte Bildschirme teils viele Male pro Sekunde, ohne dass sich etwas
    /// ändert (im Diagnoseprotokoll über 200 Meldungen in 30 Sekunden). Deshalb gesammelt
    /// nach einem kurzen Moment und nur dann neu ausrichten, wenn sich wirklich etwas
    /// geändert hat oder der gemerkte Bildschirm nicht mehr gültig ist.
    @objc private func screensChanged() {
        screenChangeWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.applyScreenChange() }
        screenChangeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }

    private func applyScreenChange() {
        let signature = Self.screenSignature(NSScreen.screens)
        let stillValid = screen.map { s in NSScreen.screens.contains { $0 === s } } ?? false
        if signature == lastScreenSignature && stillValid {
            unchangedScreenNotices += 1
            if Date().timeIntervalSince(lastUnchangedReport) > 30 {
                Diagnostics.shared.record("screen", "unchanged notices=\(unchangedScreenNotices) (ignored)")
                unchangedScreenNotices = 0
                lastUnchangedReport = Date()
            }
            return
        }
        lastScreenSignature = signature
        // Bildschirm abgesteckt, Mac entsperrt oder Auflösung geändert: neu ausrichten
        let before = screen
        if let s = screen, let current = Self.fresh(s), allowedScreens().contains(where: { Self.same($0, current) }) {
            screen = current
        } else {
            screen = screenUnderMouse() ?? allowedScreens().first
            Log.edge.info("Bildschirme geändert, Ablage neu ausgerichtet")
        }
        Diagnostics.shared.record("screen", "changed screens=[\(NSScreen.screens.map { "\($0.displayID ?? 0):\(Int($0.frame.minX)),\(Int($0.frame.minY)) \(Int($0.frame.width))×\(Int($0.frame.height)) visible \(Int($0.visibleFrame.minY))+\(Int($0.visibleFrame.height))" }.joined(separator: " | "))] ignoredBefore=\(unchangedScreenNotices) shelf \(before?.displayID ?? 0)@\(before.map { "\(Int($0.frame.minX)),\(Int($0.frame.minY))" } ?? "–") → \(screen?.displayID ?? 0)@\(screen.map { "\(Int($0.frame.minX)),\(Int($0.frame.minY))" } ?? "–")")
        unchangedScreenNotices = 0
        adaptiveY = nil
        updateFullScreen()
        layoutPanel()
        wake()
    }

    // MARK: Geometrie

    /// Mitte des Fensters: so gewählt, dass die offene Ablage ganz auf den Bildschirm passt.
    private func panelCenterY(on screen: NSScreen) -> CGFloat {
        let vf = screen.visibleFrame
        let half = CGFloat(settings.shelfHeight) / 2 + ShelfMetrics.maxFillet + 8
        return min(max(desiredY(on: screen), vf.minY + half), vf.maxY - half)
    }

    /// Wunschhöhe: feste Position oder (adaptiv) die Zeigerhöhe.
    private func desiredY(on screen: NSScreen) -> CGFloat {
        let vf = screen.visibleFrame
        // Einführung: Streifen und Ablage genau in der Mitte des Rands, unabhängig von
        // fester Höhe oder Zeigerhöhe, damit man sie neben dem Fenster sofort findet
        if guideActive { return vf.midY }
        let fixed = vf.minY + vf.height * CGFloat(settings.verticalPosition)
        guard settings.adaptivePosition, let y = adaptiveY else { return fixed }
        if let zone = settings.adaptiveZoneFraction {
            // Nur im mittleren Bereich: außerhalb bleibt die Ablage am Rand dieses Bereichs
            // stehen, der Zeiger ist dann zu weit entfernt, um sie auszulösen.
            let margin = vf.height * (1 - zone) / 2
            return min(max(y, vf.minY + margin), vf.maxY - margin)
        }
        let margin: CGFloat = 70
        return min(max(y, vf.minY + margin), vf.maxY - margin)
    }

    /// Darf die Ablage an dieser Zeigerhöhe erscheinen? Bei „nur mittleres Drittel“ nur
    /// innerhalb des Drittels, damit der Streifen nie versetzt am Rand des Bereichs auftaucht.
    private func inRevealZone(_ y: CGFloat, on screen: NSScreen) -> Bool {
        guard let zone = settings.adaptiveZoneFraction else { return true }
        let vf = screen.visibleFrame
        let margin = vf.height * (1 - zone) / 2
        return y >= vf.minY + margin && y <= vf.maxY - margin
    }

    /// Mitte der schwarzen Form je Zustand. Die kleinen Stufen sitzen genau auf der
    /// Wunschhöhe, die offene Ablage auf der Fenstermitte.
    private func shapeCenterY(_ level: ShelfUIModel.Level, on screen: NSScreen) -> CGFloat {
        level == .expanded ? panelCenterY(on: screen) : desiredY(on: screen)
    }

    /// Fläche der schwarzen Form (inklusive Rundungen) in Bildschirmkoordinaten.
    /// Auf ganze Bildpunkte des Bildschirms gerundet (Retina: halbe Punkte)
    private func pixelAligned(_ value: CGFloat, on screen: NSScreen) -> CGFloat {
        let scale = max(1, screen.backingScaleFactor)
        return (value * scale).rounded() / scale
    }

    private func bodyRect(_ level: ShelfUIModel.Level, on screen: NSScreen) -> NSRect {
        let m = ShelfMetrics.for(level, settings: settings)
        let h = m.height + 2 * m.fillet
        let x = settings.edge == .right ? screen.frame.maxX - m.width : screen.frame.minX
        return NSRect(x: x, y: shapeCenterY(level, on: screen) - h / 2, width: m.width, height: h)
    }

    private func layoutPanel() {
        // Während des Ziehens bestimmt das Ziehen, wo das Fenster steht
        guard tearDrag == nil, let screen = screen ?? allowedScreens().first else { return }
        let margin = ShelfMetrics.panelMargin
        let w = CGFloat(settings.shelfWidth) + margin
        let h = CGFloat(settings.shelfHeight) + 2 * ShelfMetrics.maxFillet + 2 * margin
        let x = settings.edge == .right ? screen.frame.maxX - w : screen.frame.minX
        let center = panelCenterY(on: screen)
        // Auf ganze Bildpunkte des Bildschirms, genau wie beim Ziehen (applyTearFrame): Nach
        // dem Andocken sprang die Ablage sonst um einen Punkt
        let frame = NSRect(x: x, y: pixelAligned(center - h / 2, on: screen), width: w, height: h)
        if panel.frame != frame { panel.setFrame(frame, display: true) }

        // Versatz der kleinen Stufen gegenüber der Fenstermitte (SwiftUI: y nach unten)
        let offset = center - desiredY(on: screen)
        if ui.anchorOffset != offset { ui.anchorOffset = offset }
    }

    // MARK: Zustände

    /// Symbolgröße beim letzten Prüfen. Gleich beim Start gesetzt: Ein erst beim ersten
    /// Lesen übernommener Wert wäre schon der verstellte, und das erste Verschieben des
    /// Reglers zeigte keine Beispieldateien.
    private var lastTileIconSize: Double

    /// Zuletzt sichtbar oder benutzt (für stille Updates)
    private(set) var lastActivity = Date()

    /// Ruht die Ablage seit `interval` Sekunden (zu und nichts in Arbeit)?
    func isIdle(for interval: TimeInterval) -> Bool {
        ui.level == .hidden && !ui.ownDragActive && store.pendingImports == 0
            && Date().timeIntervalSince(lastActivity) >= interval
    }

    private func setLevel(_ new: ShelfUIModel.Level) {
        let old = ui.level
        guard new != old else { return }
        Diagnostics.shared.record("edge", "level \(old) → \(new) dragging=\(self.dragPasteboard.changeCount != self.dragBaseline) ownDrag=\(self.ui.ownDragActive) manual=\(self.logic.manualOpen) preview=\(self.previewUntil != nil ? String(describing: self.previewLevel) : "–") guide=\(self.guideActive ? String(describing: self.guideLevel) : "–") locked=\(self.ui.isLocked)")
        lastActivity = Date()
        if new == .expanded { FramePacer.shared.start(on: panel, label: "open", duration: 0.6) }
        let style = settings.animationStyle
        // Kleine Stufen haben ihre eigene, elastische Bewegung; die Ablage selbst die gewählte
        let animation: Animation
        if new == .expanded { animation = style.open }
        else if old == .expanded { animation = style.close }
        else { animation = new > old ? style.peekIn : style.peekOut }
        withAnimation(animation) { ui.level = new }
        // Nächstes Öffnen zeigt wieder die ganze Ablage, außer „An letzter Stelle öffnen“ ist
        // an. Erst wenn sie ganz zu ist: Sonst sah man beim Schließen, wie der Stapel oder
        // Ordner zur Ablage zurückwechselt.
        if new == .hidden && !settings.reopenWhereLeft && ui.openStack != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + collapseDuration) { [weak self] in
                guard let self, self.ui.level == .hidden else { return }
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) {
                    self.ui.openStack = nil
                    self.ui.memberSelection = []
                }
            }
        }
        logic.level = new
        logic.levelSince = Date()
        logic.outsideSince = nil

        if new == .expanded {
            Thumbnails.forgetIcons()
            TrashState.shared.refresh()
            store.pruneMissingFiles()
            // Vorschau beim Verstellen in den Einstellungen: den Fokus dort lassen
            if previewUntil == nil { takeFocus() }
        }
        if new < .expanded && old == .expanded {
            // Während eines eigenen Drags darf das Fenster nicht vom Bildschirm,
            // sonst bricht macOS den Drag ab.
            if ui.ownDragActive {
                pendingResignFocus = true
            } else {
                resignFocus()
            }
        }
        if new == .hidden {
            logic.manualOpen = false
            logic.manualHovered = false
        }
    }

    /// Offene Ablage bekommt den Tastaturfokus, damit ⌘A, Pfeiltasten & Co. hier
    /// wirken und nicht in der App dahinter. Das Fenster aktiviert BarDrop dabei
    /// nicht (nonactivatingPanel): Die andere App bleibt vorn und bekommt den Fokus
    /// beim Schließen zurück. Während etwas gezogen wird, bleibt alles, wie es ist.
    private func takeFocus() {
        guard (NSEvent.pressedMouseButtons & 1) == 0 else { return }
        rememberFocus()
        if !panel.isKeyWindow { panel.makeKey() }
        // Gleich nach dem Öffnen nimmt das Fenster noch keine Mausereignisse an;
        // das regelt erst der nächste Takt. Danach noch einmal sicherstellen.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            guard let self, self.ui.level == .expanded, !self.panel.isKeyWindow,
                  (NSEvent.pressedMouseButtons & 1) == 0 else { return }
            self.rememberFocus()
            self.panel.makeKey()
        }
    }

    /// Wie es vor dem Öffnen der Ablage war: War BarDrop aktiv, und welches eigene Fenster
    /// (Einstellungen, Einführung) hatte den Fokus? Nur beim ersten Mal je Öffnen gemerkt.
    private var focusBefore: (appActive: Bool, window: NSWindow?)?

    private func rememberFocus() {
        guard focusBefore == nil, !panel.isKeyWindow else { return }
        let key = NSApp.keyWindow
        // Vorn war BarDrop nur, wenn es die vorderste App war (siehe AppActivation.isFrontmost)
        focusBefore = (AppActivation.isFrontmost, key === panel ? nil : key)
    }

    /// Zeichnet die offene Ablage sofort neu und kurz danach noch einmal (die Änderung
    /// erreicht die Ansicht teils erst im nächsten Durchlauf). Ohne Fokus täte macOS das
    /// teils erst beim nächsten Öffnen.
    private func redrawContent() {
        guard ui.level == .expanded, let host = panel.contentView else { return }
        host.needsLayout = true
        host.needsDisplay = true
        panel.displayIfNeeded()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            guard let self, self.ui.level == .expanded else { return }
            self.panel.contentView?.needsDisplay = true
            self.panel.displayIfNeeded()
        }
    }

    /// Zeichnet die offene Ablage sofort neu und holt den Fokus zurück, wenn der Zeiger
    /// darüber ist (so wie direkt nach dem Ablegen).
    private func refreshContent() {
        guard ui.level == .expanded else { return }
        redrawContent()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            guard let self, self.ui.level == .expanded else { return }
            if !self.panel.isKeyWindow, (NSEvent.pressedMouseButtons & 1) == 0,
               let screen = self.screen,
               self.bodyRect(.expanded, on: screen).contains(NSEvent.mouseLocation) {
                self.panel.makeKey()
            }
        }
    }

    /// Gibt Tastaturfokus und Aktivierung an die vorherige App zurück.
    ///
    /// Hatte vorher ein eigenes Fenster den Fokus (Einstellungen, Einführung), bekommt es
    /// ihn zurück. Sonst gibt das Fenster den Fokus ab, ohne ein anderes eigenes Fenster
    /// nach vorn zu holen. War BarDrop vorher nicht aktiv (es wurde erst aus der Ablage
    /// heraus aktiv, etwa durch einen Rechtsklick), geht es zurück an die App davor, auch
    /// wenn die Einstellungen offen sind: Sonst blieben sie danach vorn.
    private func resignFocus() {
        pendingResignFocus = false
        let before = focusBefore
        focusBefore = nil
        if panel.isKeyWindow {
            if let window = before?.window, before?.appActive == true, window.isVisible, window.canBecomeKey {
                window.makeKey()
            } else {
                panel.orderOut(nil)
                panel.orderFrontRegardless()
            }
        }
        let keep = keepAppActive() && (before?.appActive ?? true)
        if NSApp.isActive && !keep && !actions.isQuickLookVisible {
            NSApp.deactivate()
        }
    }

    /// Einführung: den ersten Streifen in der eingestellten Größe dauerhaft zeigen, bis die
    /// Übung vorbei ist. Hinfahren, Hineinziehen und Öffnen funktionieren wie immer.
    func showGuide(_ level: ShelfUIModel.Level?) {
        Diagnostics.shared.record("edge", "guide \(level.map { String(describing: $0) } ?? "off")")
        endTearImmediately()
        let on = level != nil
        if let level { guideLevel = level }
        guard on != guideActive else {
            // Nur die Stufe wechselt (offen ↔ Streifen): Die Ablage schließt dann wie sonst
            // und lässt den Streifen stehen
            if on {
                previewLevel = guideLevel
                previewUntil = .distantFuture
                wake()
            }
            return
        }
        guideActive = on
        // Die Höhe am Rand ändert sich (Mitte bzw. wieder wie eingestellt). Ist die Ablage
        // offen, erst umziehen, wenn sie ganz verborgen ist, damit nichts sichtbar springt.
        // Sonst gleich: Ein kleiner Streifen verschwindet ohne Animation und erscheint an
        // der neuen Stelle (in der Einführung bleibt er stehen und würde nie verborgen).
        if ui.level == .expanded {
            relayoutWhenHidden = true
        } else {
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) { ui.level = .hidden }
            logic.level = .hidden
            logic.levelSince = .distantPast
            logic.outsideSince = nil
            layoutPanel()
        }
        if on {
            previewLevel = guideLevel
            previewUntil = .distantFuture
        } else if previewUntil == .distantFuture {
            previewUntil = Date()
        }
        wake()
    }

    /// Beim Start kurz den Streifen am Rand zeigen, damit man sieht, dass BarDrop läuft
    /// und wo die Ablage wartet.
    func greet() {
        previewLevel = .hint
        previewUntil = Date().addingTimeInterval(1.6)
        wake()
    }

    func toggle() {
        // Schwebend: zurück an den Rand und zu; während des Ziehens nichts
        if isFloating {
            returnFloatingToEdge(close: true)
            return
        }
        if tearDrag != nil { return }
        if ui.level == .expanded {
            close()
            return
        }
        if let s = screenUnderMouse() { screen = s }
        if settings.adaptivePosition { adaptiveY = NSEvent.mouseLocation.y }
        layoutPanel()
        logic.manualOpen = true
        logic.manualHovered = false
        setLevel(.expanded)
        wake()
    }

    func close() {
        if isFloating {
            returnFloatingToEdge(close: true)
            return
        }
        if tearDrag != nil { return }
        logic.manualOpen = false
        setLevel(.hidden)
        wake()
    }

    @objc private func removeExpired() {
        store.removeExpired(olderThan: settings.autoRemoveAfter)
        Outbox.shared.cleanUp()
    }

    // MARK: Takt

    @objc private func tick() {
        // Solange ein Menü der Ablage offen ist, ruht der Takt: Er läuft auch während der
        // Menüverfolgung und könnte sie stören (die Markierung springt dann verspätet).
        // Die Ablage bleibt dabei ohnehin offen.
        if ui.menuOpen { return }
        // Während die Ablage gezogen wird, steuert das Ziehen (tearTick) alles; schwebt sie,
        // gibt es keinen Rand, nur Maus und Fokus über ihr
        if let drag = tearDrag {
            if drag.phase == .floating { floatTick(drag) }
            return
        }
        let now = Date()
        let loc = NSEvent.mouseLocation
        let mouseDown = (NSEvent.pressedMouseButtons & 1) == 1
        let dragCount = dragPasteboard.changeCount
        if !mouseDown { dragBaseline = dragCount }
        let dragging = mouseDown && dragCount != dragBaseline && (ui.ownDragActive || hasDroppableContent())

        // Auswahlrahmen: Ist die Maustaste los, ohne dass die Ablage das gemerkt hat
        // (z. B. außerhalb losgelassen), ist er vorbei
        if ui.bandActive && !mouseDown { ui.bandActive = false }

        if pendingResignFocus && !ui.ownDragActive {
            resignFocus()
        }

        // Einstellungen nur prüfen, wenn sich etwas geändert hat
        if layoutDirty, dockingEdgeChange {
            // Durch Andocken an den anderen Rand: Die Ablage steht schon offen dort
            dockingEdgeChange = false
            lastLayoutSignature = settings.layoutSignature
            lastEdge = settings.edge
            lastSizeSignature = settings.sizeSignature
            layoutPanel()
        } else if layoutDirty, settings.layoutSignature != lastLayoutSignature, settings.edge != lastEdge {
            // Rand gewechselt: Am alten Rand sofort verschwinden statt hinüberzuspringen, dann
            // am neuen Rand den Streifen wie beim Hineinziehen einer Datei herauswölben lassen.
            // So sieht man, wo die Ablage jetzt ist.
            lastLayoutSignature = settings.layoutSignature
            lastEdge = settings.edge
            lastSizeSignature = settings.sizeSignature
            let wasExpanded = ui.level == .expanded
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                ui.level = .hidden
                if !settings.reopenWhereLeft { ui.openStack = nil }
            }
            if wasExpanded && !ui.ownDragActive { resignFocus() }
            logic.level = .hidden
            logic.levelSince = now
            logic.outsideSince = nil
            logic.manualOpen = false
            previewUntil = nil
            // Unsichtbar umziehen: Das Fenster sprang sonst an den neuen Rand, während es noch
            // den alten Inhalt zeigte, und für einen Augenblick stand die Ablage mitten auf
            // dem Bildschirm. Erst wenn sie am neuen Rand neu gezeichnet ist, wieder zeigen.
            panel.alphaValue = 0
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) { [weak self] in
                guard let self else { return }
                if let s = self.screen, !self.allowedScreens().contains(where: { Self.same($0, s) }) {
                    self.screen = self.screenUnderMouse() ?? self.allowedScreens().first
                }
                self.layoutPanel()
                self.panel.contentView?.layoutSubtreeIfNeeded()
                self.panel.displayIfNeeded()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) { [weak self] in
                    guard let self else { return }
                    self.panel.alphaValue = 1
                    self.previewLevel = .peek
                    self.previewUntil = Date().addingTimeInterval(1.2)
                    self.wake()
                }
            }
        } else if layoutDirty, settings.layoutSignature != lastLayoutSignature {
            lastLayoutSignature = settings.layoutSignature
            if let s = screen, !allowedScreens().contains(where: { Self.same($0, s) }) {
                screen = screenUnderMouse() ?? allowedScreens().first
            }
            layoutPanel()
            // Breite oder Länge geändert: die offene Ablage zeigen, damit man die neue
            // Größe sieht. Sonst (Rand, Höhe, Lage) den Griff an der neuen Stelle.
            if settings.sizeSignature != lastSizeSignature {
                lastSizeSignature = settings.sizeSignature
                // Symbolgröße der Dateien verstellt: eine Beispieldatei zeigen, damit man
                // die Wirkung sieht, auch wenn die Ablage leer ist
                if settings.tileIconSize != lastTileIconSize {
                    lastTileIconSize = settings.tileIconSize
                    if !ui.showSampleTile { ui.showSampleTile = true }
                    samplePreviewRunning = true
                }
                previewUntil = now.addingTimeInterval(1.5)
                previewLevel = .expanded
                // Ohne Fokus zeichnet macOS die Ablage sonst erst beim nächsten Öffnen neu:
                // Symbolgröße und Namen der Aktionen ändern die Fenstergröße nicht
                DispatchQueue.main.async { [weak self] in self?.redrawContent() }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [weak self] in self?.redrawContent() }
            } else {
                previewUntil = now.addingTimeInterval(1.2)
                previewLevel = .hint
            }
        }
        // Form des ersten Streifens geändert: genau diesen kurz zeigen
        if layoutDirty, settings.peekSignature != lastPeekSignature {
            lastPeekSignature = settings.peekSignature
            previewUntil = now.addingTimeInterval(1.5)
            previewLevel = .peek
        }
        layoutDirty = false

        // Zeiger auf einem anderen Bildschirm, während dort nur Streifen oder Griff zu sehen
        // ist: sofort ohne Animation verschwinden, damit die Ablage gleich am neuen
        // Bildschirm bereitsteht (nie auf zwei Bildschirmen gleichzeitig).
        let mouseScreen = screenUnderMouse()
        if ui.level == .peek || ui.level == .hint, !logic.manualOpen, !ui.ownDragActive,
           let s = mouseScreen, !Self.same(s, screen) {
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) { ui.level = .hidden }
            logic.level = .hidden
            logic.levelSince = .distantPast
            logic.outsideSince = nil
        }

        // Bildschirm wechseln: nur wenn die Ablage verborgen und fertig animiert ist
        let fullyHidden = ui.level == .hidden && now.timeIntervalSince(logic.levelSince) > collapseDuration
        if fullyHidden && relayoutWhenHidden {
            relayoutWhenHidden = false
            layoutPanel()
        }
        if fullyHidden, !logic.manualOpen, let s = mouseScreen, !Self.same(s, screen) {
            screen = s
            layoutPanel()
            Log.edge.info("Ablage wechselt den Bildschirm")
        }
        // Sicherheitsnetz, falls eine Änderung der Bildschirme ohne Mitteilung kam: höchstens
        // einmal pro Sekunde prüfen, ob das gemerkte Bildschirm-Objekt noch die aktuelle Lage hat
        if now.timeIntervalSince(screenCheckedAt) > 1 {
            screenCheckedAt = now
            if let s = screen, Self.fresh(s).map({ $0 !== s && $0.frame != s.frame }) ?? true {
                Diagnostics.shared.record("screen", "stale screen object \(s.displayID ?? 0)@\(Int(s.frame.minX)),\(Int(s.frame.minY)), refreshing")
                screensChanged()
            }
        }
        guard let screen else { pauseTicking(); return }

        let onScreen = Self.same(mouseScreen, screen) || NSMouseInRect(loc, screen.frame, false)

        // Adaptive Höhe: Beim Ziehen einer Datei erscheint die Ablage mittig an der
        // Bildschirmseite und folgt der Datei nicht. Sonst folgt sie dem Zeiger, solange
        // sie verborgen ist (erst nach der Schließanimation, damit nichts „mitzieht“).
        // Auch solange der Streifen zu sehen ist (bis die Ablage aufgeht), folgt er dem Zeiger
        // am Rand: Wischte man schnell am Rand entlang, blieb er dort stehen, wo der Zeiger
        // den Rand zuerst erreicht hatte. Der Zeiger war schon weiter, verließ den Streifen,
        // und die Ablage ging nicht auf. Beim Ziehen von Dateien bleibt er mittig wie bisher.
        let dxNow = settings.edge == .right ? screen.frame.maxX - loc.x : loc.x - screen.frame.minX
        let stripVisible = (ui.level == .peek || ui.level == .hint) && !dragging && dxNow < 40
        if settings.adaptivePosition, onScreen, fullyHidden || stripVisible, !logic.manualOpen {
            let y = dragging && !ui.ownDragActive ? screen.visibleFrame.midY : loc.y
            if abs((adaptiveY ?? -1) - y) > 0.5 {
                adaptiveY = y
                layoutPanel()
            }
        }

        let dx = settings.edge == .right ? screen.frame.maxX - loc.x : loc.x - screen.frame.minX
        let expandedBody = bodyRect(.expanded, on: screen)
        ui.expandedBody = expandedBody
        let quickLookVisible = actions.isQuickLookVisible
        let locked = ui.isLocked || quickLookVisible
        // Übersicht geschlossen: Steht der Zeiger außerhalb der Ablage, schließt sie wie sonst
        // nach kurzer Zeit. Die Frist beginnt erst jetzt, so trifft eine schnell folgende
        // Leertaste noch die Ablage und öffnet die Übersicht wieder.
        if quickLookWasVisible && !quickLookVisible && ui.level == .expanded {
            logic.outsideSince = nil
        }
        quickLookWasVisible = quickLookVisible

        if ui.expandRequested {
            ui.expandRequested = false
            if ui.level == .hint { setLevel(.expanded) }
        }

        if let until = previewUntil, until <= now {
            previewUntil = nil
            samplePreviewRunning = false
            // Nach einer kurzen Vorschau zurück zum Streifen der Einführung
            if guideActive {
                previewLevel = guideLevel
                previewUntil = .distantFuture
            }
        }

        // Beispieldateien der Symbolgröße erst ausblenden, wenn die Vorschau vorbei und
        // die Ablage ganz zu ist: Beim Zuklappen sieht man sie noch, wie beim Verstellen
        if ui.showSampleTile && !samplePreviewRunning && fullyHidden { ui.showSampleTile = false }

        // Rand zu einem Bildschirm daneben, der selbst eine Ablage hat: Dort gehört sie nicht hin.
        // Darf nur dieser Bildschirm eine Ablage haben, bleibt sie wie bisher an diesem Rand.
        let innerEdge = EdgeLogic.edgeContinues(screen.frame, edge: settings.edge, at: loc.y,
                                                into: allowedScreens().map(\.frame))
        let m = ShelfMetrics.for(ui.level, settings: settings)
        let sample = EdgeLogic.Sample(
            now: now,
            dx: dx,
            dy: abs(loc.y - shapeCenterY(ui.level, on: screen)),
            onScreen: onScreen,
            onOtherScreen: mouseScreen != nil && !Self.same(mouseScreen, screen),
            inRevealZone: inRevealZone(loc.y, on: screen) && !innerEdge,
            innerEdge: innerEdge,
            overExpanded: ui.level == .expanded && expandedBody.insetBy(dx: -18, dy: -18).contains(loc),
            dragging: dragging,
            ownDrag: ui.ownDragActive,
            locked: locked,
            preview: previewUntil != nil ? previewLevel : nil,
            width: m.width, height: m.height, fillet: m.fillet
        )
        let config = EdgeLogic.Config(dragReveal: settings.dragReveal,
                                      // In ausgenommenen Apps und (auf Wunsch) im Vollbild öffnet nur das Hinfahren nicht;
                                      // Dateien hineinziehen und der Kurzbefehl gehen weiter
                                      revealOnHover: !frontmostExcluded
                                          && !fullScreenFrames.contains(screen.frame),
                                      openMode: settings.openMode,
                                      openDelay: settings.openDelay,
                                      generousHitArea: settings.generousHitArea,
                                      exactPointer: settings.exactPointer)
        logic.level = ui.level
        let result = EdgeLogic.decide(&logic, sample, config)
        if result.haptic { Haptics.tap() }   // erster Streifen oder Datei erreicht die Ablage
        if result.target != ui.level {
            setLevel(result.target)
        }

        // Mausereignisse nur annehmen, wenn der Zeiger über der offenen Ablage ist
        // Modus „Per Klick“ oder lange Verzögerung mit „Klick öffnet sofort“:
        // die mittlere Stufe nimmt einen Klick an
        let slack = config.hitSlack
        let hintBody = bodyRect(.hint, on: screen).insetBy(dx: -slack.x, dy: -slack.y)
        // Mit Schwung an den Rand geworfene Dateien: Das Fenster nimmt den Drop schon an,
        // bevor die Ablage ganz offen ist, auch knapp neben der Form. Sonst landet die
        // Datei beim Loslassen in der App dahinter.
        // Nur im Bereich der Ablage selbst, damit Drops in Fenster daneben ungestört bleiben
        let catchesThrow = dragging && !ui.ownDragActive
            && !config.exactPointer
            && onScreen && !innerEdge && dx < config.dragExpand.distance
            && expandedBody.insetBy(dx: 0, dy: -12).contains(loc)
        // Fährt der Zeiger in die offene Ablage, bekommt sie den Tastaturfokus, auch wenn sie
        // ihn zwischendurch verloren hat (Übersicht, Dialog, Klick in die Einstellungen).
        // Nicht während einer Vorschau oder der Einführung, nicht bei gedrückter Taste und
        // nicht, solange Übersicht, Menü oder ein Dialog offen sind.
        let inside = ui.level == .expanded && expandedBody.contains(loc)
        // Griff oben, solange der Zeiger in der Kopfzeile ist; nicht, während etwas gezogen
        // wird (Dateien über der Ablage) oder die Taste gedrückt ist
        let hover = inside && !mouseDown && headerZone(expandedBody).contains(loc)
        if ui.grabberHover != hover {
            withAnimation(.easeOut(duration: 0.15)) { ui.grabberHover = hover }
        }
        if inside && !pointerInside && !mouseDown && !panel.isKeyWindow && !locked
            && previewUntil == nil && NSApp.modalWindow == nil {
            takeFocus()
        }
        pointerInside = inside

        let accept = (ui.level == .expanded && (expandedBody.contains(loc) || locked))
            || (ui.level == .hint && settings.hintAcceptsClick && !dragging && hintBody.contains(loc))
            || catchesThrow
        if accept != acceptsMouse {
            acceptsMouse = accept
            panel.ignoresMouseEvents = !accept
        }

        // Ruhezustand: Takt anhalten, Ereignisse des Systems wecken ihn wieder
        if EdgeLogic.isCalm(fullyHidden: fullyHidden && ui.level == .hidden, mouseDown: mouseDown,
                            manualOpen: logic.manualOpen, previewActive: previewUntil != nil,
                            locked: ui.isLocked, onScreen: onScreen, dx: dx) {
            pauseTicking()
        }
    }
}

// MARK: Vom Rand ziehen und schweben

/// Die Ablage vom Rand gezogen oder frei schwebend (siehe EdgeTear)
final class TearDrag {
    enum Phase {
        /// Gedrückt auf dem Griff, noch nicht gezogen
        case pending
        /// Am Rand gedehnt, noch nicht gelöst
        case stretching
        /// Gelöst und gezogen
        case free
        /// Gleitet an einen Rand
        case docking
        /// Liegt frei auf dem Bildschirm
        case floating
    }
    var phase: Phase = .pending
    /// Woraus das Drücken kam: vom Rand (dann dehnen) oder aus dem Schweben (gleich frei)
    var pendingFromFloating = false
    /// Das Drücken selbst: Bleibt es ein Klick, wird es nachgereicht
    var down: NSEvent?
    /// Zeiger beim Drücken
    var start: NSPoint
    /// Rand und Bildschirm, an die die Ablage zurückkehrt (esc, Kurzbefehl, loslassen ohne Rand)
    var origin: ScreenEdge
    var originScreen: NSScreen
    /// Ablage (schwarze Form samt Platz für die Übergänge) beim Start und jetzt
    var bodyStart: NSRect = .zero
    var body: NSRect = .zero
    /// Zeiger relativ zur Ablage: So hängt sie am Zeiger
    var grab: NSPoint = .zero
    /// Nach dem Lösen: Feder, die die Ablage zum Zeiger bringt, bis sie ihm direkt folgt
    var velocity = CGVector.zero
    var springDone = false
    var detachStarted = Date()
    var detachAttach: CGFloat = 0
    /// Einmal weit genug vom Rand weg gewesen: erst dann zieht ein Rand an
    var leftZone = false
    /// Gerade in der Nähe eines Rands, der sie anzieht (für den Impuls beim Hineinkommen)
    var inZone = false
    /// Andocken: von wo nach wo, an welchem Rand, danach schließen (esc, Kurzbefehl)
    var dockFrom: NSRect = .zero
    var dockTo: NSRect = .zero
    var dockSide: ScreenEdge = .left
    var dockScreen: NSScreen?
    var dockAttach: CGFloat = 0
    var dockStarted = Date()
    var closeAfterDock = false
    /// Nur für die Diagnose (Befehl „tear“): Zeiger vorgegeben statt der echten Maus
    var pointer: NSPoint?
    /// macOS selbst schiebt das Fenster mit dem Zeiger (performDrag): so flüssig wie beim
    /// Ziehen eines Fensters an der Titelleiste
    var systemDragging = false
    /// Meldet die Bewegungen des Fensters, solange macOS es schiebt
    var moveObserver: NSObjectProtocol?
    /// Abstand zum Zeiger beim Lösen, der in kurzer Zeit auf null ausläuft
    var catchUp: CGVector?

    init(down: NSEvent?, start: NSPoint, origin: ScreenEdge, originScreen: NSScreen) {
        self.down = down
        self.start = start
        self.origin = origin
        self.originScreen = originScreen
    }
}

extension EdgeController {
    /// Höhe des Platzes für die Übergänge über und unter der offenen Ablage
    private var expandedFillet: CGFloat { ShelfMetrics.for(.expanded, settings: settings).fillet }

    /// Oberkante der schwarzen Form (ohne den Platz für die Übergänge)
    private func bodyTop(_ body: NSRect) -> CGFloat { body.maxY - expandedFillet }

    /// Kopfzeile: Fährt der Zeiger hinein, erscheint der Griff
    func headerZone(_ body: NSRect) -> NSRect {
        NSRect(x: body.minX, y: bodyTop(body) - EdgeTear.headerHeight, width: body.width, height: EdgeTear.headerHeight)
    }

    /// Nur in der Umgebung des Griffs lässt sich ziehen, nicht an den Ecken
    private func grabZone(_ body: NSRect) -> NSRect {
        NSRect(x: body.midX - EdgeTear.grabWidth / 2, y: bodyTop(body) - EdgeTear.grabHeight,
               width: EdgeTear.grabWidth, height: EdgeTear.grabHeight)
    }

    /// Unter dem Zeiger liegt die freie Fläche der Ablage (kein Knopf)
    private func hitsBackground(_ event: NSEvent) -> Bool {
        guard let content = panel.contentView else { return false }
        let local = content.superview?.convert(event.locationInWindow, from: nil) ?? event.locationInWindow
        return content.hitTest(local) is SelectionBackgroundNSView
    }

    /// Schwebt die Ablage gerade frei?
    var isFloating: Bool { tearDrag?.phase == .floating }

    /// Ereignisse der eigenen Fenster, bevor sie ankommen. Ein Drücken auf den Griff behält
    /// BarDrop zunächst für sich: Wird daraus ein Ziehen, löst sich die Ablage vom Rand (oder
    /// wandert, wenn sie schwebt); bleibt es ein Klick, wird er unverändert nachgereicht.
    /// nil: Das Ereignis ist verbraucht.
    func tearEvent(_ event: NSEvent) -> NSEvent? {
        switch event.type {
        case .leftMouseDown:
            // Ein liegengebliebenes Drücken (Loslassen nicht gesehen) zählt nicht mehr
            if let drag = tearDrag, drag.phase == .pending {
                if drag.pendingFromFloating { drag.phase = .floating } else { tearDrag = nil }
                setGrabbing(false)
            }
            let p = NSEvent.mouseLocation
            if let drag = tearDrag {
                guard drag.phase == .floating, event.window === panel, grabZone(drag.body).contains(p),
                      !ui.isLocked, !ui.ownDragActive, !actions.isQuickLookVisible,
                      hitsBackground(event) else { return event }
                drag.phase = .pending
                drag.pendingFromFloating = true
                drag.down = event
                drag.start = p
                drag.grab = NSPoint(x: p.x - drag.body.minX, y: p.y - drag.body.minY)
                // Der Griff wird schon beim Drücken hell
                setGrabbing(true)
                return nil
            }
            guard event.window === panel, let screen, canTear(at: p, event: event) else { return event }
            tearDrag = TearDrag(down: event, start: p, origin: settings.edge, originScreen: screen)
            setGrabbing(true)
            return nil
        case .leftMouseDragged:
            guard let drag = tearDrag else { return event }
            switch drag.phase {
            case .pending:
                let p = NSEvent.mouseLocation
                guard hypot(p.x - drag.start.x, p.y - drag.start.y) >= 4 else { return nil }
                if drag.pendingFromFloating { beginMoveFloating(drag) } else { beginTear(drag) }
                updateTear(drag, fromTimer: false)
                return nil
            case .stretching:
                updateTear(drag, fromTimer: false)
                return nil
            case .free:
                // BarDrop schiebt das Fenster selbst, mit jeder Bewegung. (Schob macOS es
                // per performDrag, kam die Zeichnung immer erst danach: Der Rand, der sich der
                // Ablage entgegenwölbt, wanderte dann kurz mit dem Fenster mit, statt fest am
                // Bildschirmrand zu bleiben.)
                if !drag.systemDragging {
                    updateTear(drag, fromTimer: false)
                }
                return nil
            case .docking, .floating:
                return event
            }
        case .leftMouseUp:
            guard let drag = tearDrag else { return event }
            switch drag.phase {
            case .pending:
                // Nur geklickt: Drücken und Loslassen wie sonst ausliefern
                if drag.pendingFromFloating { drag.phase = .floating } else { tearDrag = nil }
                setGrabbing(false)
                if let down = drag.down {
                    DispatchQueue.main.async { [weak self] in
                        self?.panel.sendEvent(down)
                        self?.panel.sendEvent(event)
                    }
                }
                drag.down = nil
                return nil
            case .stretching, .free:
                if drag.systemDragging { finishSystemDrag(drag) } else { releaseTear(drag) }
                return nil
            case .docking, .floating:
                return event
            }
        default:
            return event
        }
    }

    /// Nur am Griff der offenen Ablage am Rand, und nicht, solange etwas anderes läuft
    /// (Übersicht, Menü, Ziehen, Einführung, Vorschau)
    private func canTear(at point: NSPoint, event: NSEvent) -> Bool {
        guard ui.level == .expanded, ui.tear == nil, !ui.isLocked, !ui.ownDragActive,
              !actions.isQuickLookVisible, !IntroGate.active, !guideActive, previewUntil == nil,
              NSApp.modalWindow == nil else { return false }
        return grabZone(ui.expandedBody).contains(point) && hitsBackground(event)
    }

    /// Fenster für die gezogene Ablage: so breit, dass links und rechts Platz für Schatten und
    /// Verbindung ist, die Ablage in der Mitte genau an `body`. Bleibt die Größe gleich, wird
    /// das Fenster nur verschoben, ohne neu zu zeichnen.
    private func applyTearFrame(_ body: NSRect) {
        let height = panel.frame.height
        let scale = panel.screen?.backingScaleFactor ?? 2
        let frame = NSRect(x: ((body.minX - EdgeTear.reach) * scale).rounded() / scale,
                           y: ((body.midY - height / 2) * scale).rounded() / scale,
                           width: body.width + 2 * EdgeTear.reach, height: height)
        if panel.frame.size == frame.size {
            if panel.frame.origin != frame.origin { panel.setFrameOrigin(frame.origin) }
        } else {
            panel.setFrame(frame, display: true)
            syncGlassWindow()
        }
        ui.expandedBody = body
    }

    private func setTear(gap: CGFloat, attach: CGFloat? = nil, side: ScreenEdge, dock: CGFloat? = nil) {
        guard var tear = ui.tear else { return }
        if let dock { tear.dock = (max(0, min(1, dock)) * 50).rounded() / 50 }
        // Auf halbe Punkte gerundet: Kleinste Änderungen zeichnen sonst unnötig neu
        tear.gap = (max(0, gap) * 2).rounded() / 2
        if let attach { tear.attach = (max(0, min(1, attach)) * 100).rounded() / 100 }
        tear.side = side
        // Ohne Verbindung zum Rand spielt der Abstand keine Rolle: nicht bei jeder Bewegung
        // neu zeichnen
        if let old = ui.tear, tear.attach <= 0.01, old.attach <= 0.01 { tear.gap = old.gap }
        guard tear != ui.tear else { return }
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) { ui.tear = tear }
    }

    private func setGrabbing(_ on: Bool) {
        guard ui.grabbing != on else { return }
        withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) { ui.grabbing = on }
    }

    private func beginTear(_ drag: TearDrag) {
        drag.phase = .stretching
        drag.body = ui.expandedBody
        drag.bodyStart = drag.body
        drag.grab = NSPoint(x: drag.start.x - drag.body.minX, y: drag.start.y - drag.body.minY)
        Diagnostics.shared.record("tear", "start edge=\(drag.origin)")
        setGrabbing(true)
        // Fenster und Ansicht in einem Zug umstellen: Die Ablage bleibt genau, wo sie war
        panel.disableScreenUpdatesUntilFlush()
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) { ui.tear = ShelfUIModel.Tear(gap: 0, attach: 1, side: drag.origin, dock: 1) }
        applyTearFrame(drag.body)
        panel.contentView?.layoutSubtreeIfNeeded()
        panel.displayIfNeeded()
        startTearTimer()
    }

    /// Aus dem Schweben heraus gegriffen: sie folgt gleich dem Zeiger
    private func beginMoveFloating(_ drag: TearDrag) {
        drag.phase = .free
        drag.springDone = true
        drag.leftZone = true
        drag.inZone = false
        drag.velocity = .zero
        setGrabbing(true)
        startTearTimer()
    }

    private func startTearTimer() {
        tearTimer?.invalidate()
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in self?.tearTick() }
        RunLoop.main.add(timer, forMode: .common)
        tearTimer = timer
    }

    private func stopTearTimer() {
        tearTimer?.invalidate()
        tearTimer = nil
    }

    private func tearTick() {
        guard let drag = tearDrag else {
            stopTearTimer()
            return
        }
        switch drag.phase {
        case .stretching, .free:
            // Schiebt macOS gerade selbst, nichts dazwischen tun, bis die Taste los ist
            if drag.systemDragging {
                if (NSEvent.pressedMouseButtons & 1) == 0 { finishSystemDrag(drag) }
                return
            }
            // Sicherheitsnetz: Taste los, ohne dass das Loslassen ankam
            if drag.pointer == nil, (NSEvent.pressedMouseButtons & 1) == 0 {
                releaseTear(drag)
            } else {
                updateTear(drag, fromTimer: true)
            }
        case .docking:
            stepDock(drag)
        case .pending, .floating:
            stopTearTimer()
        }
    }

    /// Bildschirm, auf dem ein Punkt liegt (oder der nächste erlaubte)
    private func tearScreen(at point: NSPoint) -> NSScreen? {
        Self.screen(containing: point, in: allowedScreens())
            ?? allowedScreens().min { Self.distanceTo(point, $0.frame) < Self.distanceTo(point, $1.frame) }
    }

    private static func distanceTo(_ p: NSPoint, _ r: NSRect) -> CGFloat {
        hypot(max(r.minX - p.x, 0, p.x - r.maxX), max(r.minY - p.y, 0, p.y - r.maxY))
    }

    /// Nächster Rand (links oder rechts), an den die Ablage andocken darf, und ihr Abstand dazu.
    /// Nur äußere Ränder: Geht der Bildschirm dort in einen anderen über, gehört sie nicht hin.
    private func nearestDock(for body: NSRect) -> (side: ScreenEdge, distance: CGFloat, screen: NSScreen)? {
        guard let screen = tearScreen(at: NSPoint(x: body.midX, y: body.midY)) else { return nil }
        let frames = allowedScreens().map(\.frame)
        var options: [(ScreenEdge, CGFloat)] = []
        if !EdgeLogic.edgeContinues(screen.frame, edge: .left, at: body.midY, into: frames) {
            options.append((.left, body.minX - screen.frame.minX))
        }
        if !EdgeLogic.edgeContinues(screen.frame, edge: .right, at: body.midY, into: frames) {
            options.append((.right, screen.frame.maxX - body.maxX))
        }
        guard let best = options.min(by: { $0.1 < $1.1 }) else { return nil }
        return (best.0, max(0, best.1), screen)
    }

    private func updateTear(_ drag: TearDrag, fromTimer: Bool) {
        let p = drag.pointer ?? NSEvent.mouseLocation
        switch drag.phase {
        case .stretching:
            // Erst dehnt sich die Ablage am Rand wie ein Tropfen, der noch hängt: anfangs
            // folgt sie gut, je weiter, desto zäher, dann reißt sie
            let away = drag.origin == .right ? drag.start.x - p.x : p.x - drag.start.x
            if away >= EdgeTear.tearDistance {
                detachTear(drag)
                updateTear(drag, fromTimer: fromTimer)
                return
            }
            let pull = max(0, away)
            let gap = EdgeTear.stretchMax * (1 - exp(-pull / EdgeTear.stretchSoftness))
            var body = drag.bodyStart
            body.origin.x += drag.origin == .right ? -gap : gap
            body.origin.y += (p.y - drag.start.y) * 0.12
            drag.body = body
            // Auf den ersten Punkten geht die Form der angedockten Ablage in die verschmelzende über
            setTear(gap: gap, attach: 1 - 0.8 * pow(pull / EdgeTear.tearDistance, 1.4), side: drag.origin,
                    dock: 1 - pull / 14)
            applyTearFrame(body)
        case .free:
            var target = NSRect(x: p.x - drag.grab.x, y: p.y - drag.grab.y,
                                width: drag.body.width, height: drag.body.height)
            if let screen = tearScreen(at: p) {
                let frame = screen.frame, visible = screen.visibleFrame
                target.origin.x = min(max(target.minX, frame.minX), frame.maxX - target.width)
                target.origin.y = min(max(target.minY, visible.minY), visible.maxY - target.height)
            }
            var body = drag.body
            if drag.springDone {
                // Folgt dem Zeiger direkt, bei jeder Bewegung sofort
                body.origin = target.origin
            } else {
                // Gleich nach dem Lösen schnellt sie zum Zeiger: Sie folgt ihm sofort mit
                // jeder Bewegung, nur der Abstand vom Lösen läuft in kurzer Zeit weich aus.
                // (Eine Feder hinter dem Zeiger her kam bei laufender Bewegung nie an und
                // zog ruckelnd nach.)
                let offset = drag.catchUp ?? CGVector(dx: body.minX - target.minX, dy: body.minY - target.minY)
                drag.catchUp = offset
                let t = min(1, Date().timeIntervalSince(drag.detachStarted) / 0.14)
                let k = CGFloat(pow(1 - t, 3))
                body.origin = NSPoint(x: target.minX + offset.dx * k, y: target.minY + offset.dy * k)
                if t >= 1 {
                    body.origin = target.origin
                    drag.springDone = true
                }
            }
            drag.body = body
            updateAttraction(drag)
            applyTearFrame(body)
        default:
            break
        }
    }

    /// Ränder in der Nähe der gezogenen Ablage: Der nächste wölbt sich ihr entgegen; gleich nach
    /// dem Lösen zieht sich die Verbindung zum alten Rand zurück
    private func updateAttraction(_ drag: TearDrag) {
        let body = drag.body
        guard let near = nearestDock(for: body) else {
            setTear(gap: 0, attach: drag.leftZone ? 0 : nil, side: ui.tear?.side ?? drag.origin)
            return
        }
        if near.distance >= EdgeTear.attachZone { drag.leftZone = true }
        if drag.leftZone {
            // Nah an einem Rand: Er wölbt sich ihr entgegen, mit derselben Bewegung wie
            // beim Lösen, nur rückwärts
            let inZone = near.distance < EdgeTear.attachZone
            // Dezenter Impuls, wenn der Rand sie zu fassen bekommt (nicht beim Verlassen)
            if inZone && !drag.inZone { Haptics.tap() }
            drag.inZone = inZone
            let attach = inZone ? 1 - near.distance / EdgeTear.attachZone : 0
            setTear(gap: near.distance, attach: attach * 0.85, side: near.side)
        } else {
            // Gleich nach dem Lösen: Die Verbindung zum alten Rand zieht sich schnell zurück
            let screen = drag.originScreen.frame
            let gap = drag.origin == .right ? screen.maxX - body.maxX : body.minX - screen.minX
            let t = min(1, Date().timeIntervalSince(drag.detachStarted) / 0.14)
            let fade = CGFloat(1 - (1 - t) * (1 - t))
            setTear(gap: gap, attach: drag.detachAttach * (1 - fade), side: drag.origin)
        }
    }

    /// Das Fenster folgt dem Zeiger über macOS selbst (wie beim Ziehen an der Titelleiste).
    /// Kehrt erst nach dem Loslassen zurück; währenddessen meldet das Fenster jede Bewegung.
    private func systemDrag(_ drag: TearDrag, with event: NSEvent) {
        drag.systemDragging = true
        drag.moveObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification, object: panel, queue: nil
        ) { [weak self, weak drag] _ in
            guard let self, let drag, drag.systemDragging else { return }
            let frame = self.panel.frame
            drag.body = NSRect(x: frame.minX + EdgeTear.reach, y: frame.midY - drag.body.height / 2,
                               width: drag.body.width, height: drag.body.height)
            self.ui.expandedBody = drag.body
            self.updateAttraction(drag)
        }
        FramePacer.shared.start(on: panel, label: "drag", duration: 30)
        panel.performDrag(with: event)
        // performDrag kehrt je nach System sofort zurück und macOS schiebt das Fenster danach
        // weiter, bis die Taste losgelassen wird. Erst dann ist das Ziehen vorbei (sonst fiel
        // die Entscheidung Einrasten oder Schweben schon beim Anfassen).
        if (NSEvent.pressedMouseButtons & 1) == 0 {
            finishSystemDrag(drag)
        } else {
            startTearTimer()
        }
    }

    /// Taste los nach dem Schieben durch macOS: Lage übernehmen, dann einrasten oder schweben
    private func finishSystemDrag(_ drag: TearDrag) {
        guard drag.systemDragging else { return }
        FramePacer.shared.stop()
        if let observer = drag.moveObserver { NotificationCenter.default.removeObserver(observer) }
        drag.moveObserver = nil
        drag.systemDragging = false
        let frame = panel.frame
        drag.body = NSRect(x: frame.minX + EdgeTear.reach, y: frame.midY - drag.body.height / 2,
                           width: drag.body.width, height: drag.body.height)
        ui.expandedBody = drag.body
        if drag.phase == .free { releaseTear(drag) }
    }

    /// Losgelöst wird sie zu Glas, beim Andocken wieder schwarz, jeweils weich
    /// Glas direkt aus der Bewegung (beim Dehnen), ohne eigene Animation
    private func setGlassAmount(_ value: Double) {
        let rounded = settings.detachedGlass ? (value * 50).rounded() / 50 : 0
        guard ui.tearGlass != rounded else { return }
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) { ui.tearGlass = rounded }
        syncGlassWindow()
    }

    /// Begleitfenster mit dem Glas an Lage und Stärke der losgelösten Ablage anpassen
    private func syncGlassWindow(duration: TimeInterval = 0) {
        guard tearDrag != nil, ui.tearGlass > 0 || glassWindow != nil else { return }
        let window = glassWindow ?? ShelfGlassWindow()
        glassWindow = window
        let m = ShelfMetrics.for(.expanded, settings: settings)
        let size = panel.frame.size
        let body = NSRect(x: ((size.width - m.width) / 2).rounded(), y: ((size.height - m.height) / 2).rounded(),
                          width: m.width, height: m.height)
        window.follow(panel, body: body)
        window.show(CGFloat(ui.tearGlass), duration: duration)
    }

    /// Glas ganz weg (angedockt, abgebrochen)
    private func removeGlassWindow() {
        glassWindow?.detach()
    }

    private func setGlass(_ on: Bool, animated: Bool = true) {
        let value: Double = on && settings.detachedGlass ? 1 : 0
        guard ui.tearGlass != value else { return }
        if animated {
            withAnimation(.easeOut(duration: 0.3)) { ui.tearGlass = value }
        } else {
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) { ui.tearGlass = value }
        }
        syncGlassWindow(duration: animated ? 0.3 : 0)
    }

    private func detachTear(_ drag: TearDrag) {
        setGlass(true)
        drag.phase = .free
        drag.detachStarted = Date()
        drag.detachAttach = ui.tear?.attach ?? 0
        drag.velocity = .zero
        drag.springDone = false
        drag.catchUp = nil
        // Spürbar wie ein Einrasten, wenn sich die Ablage vom Rand löst
        Haptics.tap()
        Diagnostics.shared.record("tear", "detach")
    }

    private func releaseTear(_ drag: TearDrag) {
        setGrabbing(false)
        switch drag.phase {
        case .stretching:
            dock(drag, side: drag.origin, screen: drag.originScreen)
        case .free:
            // In Randnähe losgelassen rastet sie immer ein, auch wenn sie gleich nach dem Lösen
            // schwungvoll zurückgeschoben wurde (sonst bliebe sie halb am Rand schweben)
            if let near = nearestDock(for: drag.body), near.distance < EdgeTear.attachZone {
                dock(drag, side: drag.leftZone ? near.side : drag.origin, screen: drag.leftZone ? near.screen : drag.originScreen)
            } else {
                float(drag)
            }
        default:
            break
        }
    }

    /// Losgelassen fern der Ränder: Sie bleibt dort liegen, über allen Fenstern, bis man
    /// sie an einen Rand zieht, esc oder den Kurzbefehl drückt
    private func float(_ drag: TearDrag) {
        stopTearTimer()
        drag.phase = .floating
        drag.inZone = false
        setTear(gap: 0, attach: 0, side: ui.tear?.side ?? drag.origin)
        applyTearFrame(drag.body)
        logic.outsideSince = nil
        lastActivity = Date()
        Diagnostics.shared.record("tear", "float")
        wake()
    }

    /// Schwebend: zurück an ihren Rand (esc, Kurzbefehl), danach zu
    func returnFloatingToEdge(close: Bool) {
        guard let drag = tearDrag, drag.phase == .floating else { return }
        drag.closeAfterDock = close
        dock(drag, side: settings.edge, screen: Self.fresh(drag.originScreen) ?? drag.originScreen)
    }

    private func dock(_ drag: TearDrag, side: ScreenEdge, screen: NSScreen) {
        setGlass(false)
        drag.phase = .docking
        drag.dockSide = side
        drag.dockScreen = screen
        drag.dockFrom = drag.body
        drag.dockAttach = ui.tear?.attach ?? 0
        // Wo die Ablage dort sitzt: an der Wunschhöhe wie sonst (adaptiv: wo man losließ)
        if settings.adaptivePosition { adaptiveY = drag.body.midY }
        let centerY = panelCenterY(on: screen)
        drag.dockTo = NSRect(x: side == .right ? screen.frame.maxX - drag.body.width : screen.frame.minX,
                             y: centerY - drag.body.height / 2,
                             width: drag.body.width, height: drag.body.height)
        drag.dockStarted = Date()
        Diagnostics.shared.record("tear", "dock \(side) sameEdge=\(side == drag.origin) close=\(drag.closeAfterDock)")
        startTearTimer()
    }

    private func stepDock(_ drag: TearDrag) {
        // Weich wie eine gedämpfte Feder ohne Überschwingen: zügig los, sanft ankommen
        let duration: TimeInterval = 0.34
        let t = min(1, Date().timeIntervalSince(drag.dockStarted) / duration)
        let w = 7.0
        let spring = { (x: Double) in 1 - (1 + w * x) * exp(-w * x) }
        let e = CGFloat(t >= 1 ? 1 : spring(t) / spring(1))
        let from = drag.dockFrom, to = drag.dockTo
        let body = NSRect(x: from.minX + (to.minX - from.minX) * e, y: from.minY + (to.minY - from.minY) * e,
                          width: to.width, height: to.height)
        drag.body = body
        if let screen = drag.dockScreen {
            let gap = drag.dockSide == .right ? screen.frame.maxX - body.maxX : body.minX - screen.frame.minX
            // Der Rand greift etwas früher nach ihr, als sie ankommt
            let reach = min(1, e * 1.35)
            // Noch in der Bewegung in die Form der angedockten Ablage überblenden; das letzte Viertel ist schon sie, am Ende springt nichts mehr
            setTear(gap: gap, attach: drag.dockAttach + (1 - drag.dockAttach) * reach, side: drag.dockSide,
                    dock: CGFloat((t - 0.35) / 0.4))
        }
        applyTearFrame(body)
        // Diagnose (nur mit Ordner „Bilder“): jedes Bild des Andockens festhalten
        if ShelfSnapshots.isActive { ShelfSnapshots.capture(panel, "dock\(Int(t * 100))", after: [0]) }
        if t >= 1 { finishDock(drag) }
    }

    /// Angedockt: zurück zur gewohnten Ablage am Rand, in einem Zug mit dem Fenster
    private func finishDock(_ drag: TearDrag) {
        let before = panel.frame
        defer {
            Diagnostics.shared.record("tear", "angedockt Fenster \(Int(before.minX)),\(before.minY) \(Int(before.width))x\(before.height) → \(Int(panel.frame.minX)),\(panel.frame.minY) \(Int(panel.frame.width))x\(panel.frame.height)")
            if ShelfSnapshots.isActive {
                ShelfSnapshots.capture(panel, "angedockt", after: [0, 0.017, 0.034, 0.05, 0.1, 0.3])
            }
        }
        stopTearTimer()
        tearDrag = nil
        if let s = drag.dockScreen { screen = s }
        panel.disableScreenUpdatesUntilFlush()
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            if settings.edge != drag.dockSide {
                // Der Rand in den Einstellungen stellt sich mit um, ohne dass die Ablage
                // dafür wie sonst verschwindet und neu erscheint (siehe tick)
                dockingEdgeChange = true
                settings.edge = drag.dockSide
            }
            ui.tear = nil
            ui.grabbing = false
            ui.tearGlass = 0
            removeGlassWindow()
            // Rahmen samt Bögen zum Bildschirm sind schon da (Überblendung in TearGoo)
            ui.dockOutline = 1
        }
        layoutPanel()
        panel.contentView?.layoutSubtreeIfNeeded()
        panel.displayIfNeeded()
        if let screen { ui.expandedBody = bodyRect(.expanded, on: screen) }
        logic.outsideSince = nil
        lastActivity = Date()
        if drag.closeAfterDock { close() }
        wake()
    }

    /// Sofort zurück an den Rand, ohne Bewegung (Rand in den Einstellungen geändert,
    /// Einführung startet). Die Ablage bleibt dabei offen; was danach geschieht, regelt der Aufrufer.
    func endTearImmediately() {
        guard let drag = tearDrag else { return }
        stopTearTimer()
        if let observer = drag.moveObserver { NotificationCenter.default.removeObserver(observer) }
        if drag.systemDragging { FramePacer.shared.stop() }
        tearDrag = nil
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            ui.tear = nil
            ui.grabbing = false
            ui.tearGlass = 0
        }
        removeGlassWindow()
        layoutPanel()
        Diagnostics.shared.record("tear", "ended")
    }

    /// Liegt an dieser Stelle das Kontrollzentrum (oder ein Menü) über der Ablage? Nur diese
    /// zählen: Eine allgemeinere Prüfung erfasste auch Fenster anderer Apps, die man nicht
    /// sieht, und die Ablage war dann nicht mehr bedienbar. Kurz zwischengespeichert.
    private func coveredByOtherWindow(at point: NSPoint) -> Bool {
        let now = Date()
        if now.timeIntervalSince(coverCheck.time) < 0.15, hypot(point.x - coverCheck.point.x, point.y - coverCheck.point.y) < 4 {
            return coverCheck.covered
        }
        var covered = false
        let mainHeight = NSScreen.screens.first?.frame.maxY ?? 0
        let cgPoint = CGPoint(x: point.x, y: mainHeight - point.y)
        let own = ProcessInfo.processInfo.processIdentifier
        let systemPanels = ["ControlCenter", "Control Center", "NotificationCenter", "Notification Center"]
        if let list = CGWindowListCopyWindowInfo([.optionOnScreenAboveWindow, .excludeDesktopElements],
                                                 CGWindowID(panel.windowNumber)) as? [[String: Any]] {
            for info in list {
                guard (info[kCGWindowOwnerPID as String] as? Int32) != own,
                      (info[kCGWindowAlpha as String] as? Double ?? 0) > 0.05,
                      let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
                      let bounds = CGRect(dictionaryRepresentation: boundsDict),
                      bounds.contains(cgPoint) else { continue }
                let owner = info[kCGWindowOwnerName as String] as? String ?? ""
                let layer = info[kCGWindowLayer as String] as? Int ?? 0
                if systemPanels.contains(owner) || layer == Int(CGWindowLevelForKey(.popUpMenuWindow)) {
                    covered = true
                    break
                }
            }
        }
        if covered != coverCheck.covered {
            Diagnostics.shared.record("tear", "float verdeckt=\(covered)")
        }
        coverCheck = (now, point, covered)
        return covered
    }

    /// Schwebend: statt Rand und Takt nur Maus und Fokus über der Ablage
    func floatTick(_ drag: TearDrag) {
        let loc = NSEvent.mouseLocation
        let mouseDown = (NSEvent.pressedMouseButtons & 1) == 1
        if !mouseDown { dragBaseline = dragPasteboard.changeCount }
        // Wo die Ablage wirklich liegt, aus dem Fenster selbst: Hat macOS oder SwiftUI das
        // Fenster verschoben oder in der Größe geändert, stimmten Griff und Klickfläche sonst
        // nicht mehr mit der sichtbaren Ablage überein (Klicks gingen durch, kein Griff)
        let frame = panel.frame
        let actual = NSRect(x: frame.minX + EdgeTear.reach, y: frame.midY - drag.body.height / 2,
                            width: max(0, frame.width - 2 * EdgeTear.reach), height: drag.body.height)
        if actual.integral != drag.body.integral {
            Diagnostics.shared.record("tear", "float Lage korrigiert \(Int(drag.body.minX)),\(Int(drag.body.minY)) \(Int(drag.body.width))x\(Int(drag.body.height)) → \(Int(actual.minX)),\(Int(actual.minY)) \(Int(actual.width))x\(Int(actual.height))")
            drag.body = actual
        }
        let body = drag.body
        ui.expandedBody = body
        let locked = ui.isLocked || actions.isQuickLookVisible
        // Liegt etwas anderes darüber (Kontrollzentrum, Menüs anderer Apps), ist der Zeiger
        // nicht über der Ablage: sonst holte sie sich den Fokus und schloss das Kontrollzentrum
        let inside = body.contains(loc) && !coveredByOtherWindow(at: loc)
        // Klicks neben der Ablage gehen durch an die Fenster darunter
        let accept = inside || locked
        if accept != acceptsMouse {
            acceptsMouse = accept
            panel.ignoresMouseEvents = !accept
        }
        if inside != pointerInside {
            Diagnostics.shared.record("tear", "float Zeiger \(inside ? "über" : "neben") der Ablage kopf=\(headerZone(body).contains(loc))")
        }
        if inside && !pointerInside && !mouseDown && !panel.isKeyWindow && !locked && NSApp.modalWindow == nil {
            takeFocus()
        }
        pointerInside = inside
        let hover = inside && !mouseDown && headerZone(body).contains(loc)
        if ui.grabberHover != hover {
            withAnimation(.easeOut(duration: 0.15)) { ui.grabberHover = hover }
        }
    }
}

// MARK: Diagnose: Ziehen ohne Maus

extension EdgeController {
    /// Befehl „tear“ (nur Diagnose): Die offene Ablage wird wie mit der Maus am Griff
    /// gezogen, entlang `points` (Abstand vom Startpunkt in pt, je 1/60 s), dann losgelassen.
    /// Dazu Bilder des Fensters, um Form und Lage prüfen zu können.
    func simulateTear(path points: [NSPoint], shots: Set<Int>) {
        guard tearDrag == nil, ui.level == .expanded, let screen else { return }
        let body = ui.expandedBody
        let start = NSPoint(x: body.midX, y: body.maxY - expandedFillet - 8)
        let drag = TearDrag(down: nil, start: start, origin: settings.edge, originScreen: screen)
        drag.pointer = start
        tearDrag = drag
        for (index, offset) in points.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(index) / 60) { [weak self] in
                guard let self, self.tearDrag === drag else { return }
                drag.pointer = NSPoint(x: start.x + offset.x, y: start.y + offset.y)
                if drag.phase == .pending { self.beginTear(drag) }
                if drag.phase == .stretching || drag.phase == .free { self.updateTear(drag, fromTimer: false) }
                if shots.contains(index) { ShelfSnapshots.capture(self.panel, "tear\(index)", after: [0]) }
                if index == points.count - 1 {
                    self.releaseTear(drag)
                    ShelfSnapshots.capture(self.panel, "release", after: [0.1, 0.3, 0.6])
                }
            }
        }
    }
}
