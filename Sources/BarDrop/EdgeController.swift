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
        // Neuer Inhalt, der erst später fertig wird (Bilder aus dem Web, große Dateien,
        // iCloud): Ohne Fokus zeichnet macOS das Fenster teils erst beim nächsten Öffnen
        // neu. Deshalb hier selbst neu zeichnen, sobald sich der Inhalt ändert.
        contentObserver = store.$entries.map { _ in () }
            .merge(with: store.$pendingImports.map { _ in () })
            .merge(with: actions.plugins.$jobs.map { _ in () })
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.refreshContent() }
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
            self?.handle(event, global: false)
            return event
        }) {
            monitors.append(local)
        }
        // Übersicht offen und BarDrop verliert den Fokus (andere App, ⌘⇥): Übersicht und
        // Ablage schließen, wie im Finder
        resignObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.closeQuickLookAndShelf() }
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
        guard actions.isQuickLookVisible else { return }
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
    private func bodyRect(_ level: ShelfUIModel.Level, on screen: NSScreen) -> NSRect {
        let m = ShelfMetrics.for(level, settings: settings)
        let h = m.height + 2 * m.fillet
        let x = settings.edge == .right ? screen.frame.maxX - m.width : screen.frame.minX
        return NSRect(x: x, y: shapeCenterY(level, on: screen) - h / 2, width: m.width, height: h)
    }

    private func layoutPanel() {
        guard let screen = screen ?? allowedScreens().first else { return }
        let margin = ShelfMetrics.panelMargin
        let w = CGFloat(settings.shelfWidth) + margin
        let h = CGFloat(settings.shelfHeight) + 2 * ShelfMetrics.maxFillet + 2 * margin
        let x = settings.edge == .right ? screen.frame.maxX - w : screen.frame.minX
        let center = panelCenterY(on: screen)
        let frame = NSRect(x: x, y: center - h / 2, width: w, height: h)
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
        focusBefore = (NSApp.isActive, key === panel ? nil : key)
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
        if layoutDirty, settings.layoutSignature != lastLayoutSignature, settings.edge != lastEdge {
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
            // Erst umziehen, wenn die Ablage am alten Rand wirklich weg ist
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) { [weak self] in
                guard let self else { return }
                if let s = self.screen, !self.allowedScreens().contains(where: { Self.same($0, s) }) {
                    self.screen = self.screenUnderMouse() ?? self.allowedScreens().first
                }
                self.layoutPanel()
                self.previewLevel = .peek
                self.previewUntil = Date().addingTimeInterval(1.2)
                self.wake()
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
        if settings.adaptivePosition, onScreen, fullyHidden, !logic.manualOpen {
            let y = dragging && !ui.ownDragActive ? screen.visibleFrame.midY : loc.y
            if abs((adaptiveY ?? -1) - y) > 0.5 {
                adaptiveY = y
                layoutPanel()
            }
        }

        let dx = settings.edge == .right ? screen.frame.maxX - loc.x : loc.x - screen.frame.minX
        let expandedBody = bodyRect(.expanded, on: screen)
        ui.expandedBody = expandedBody
        let locked = ui.isLocked || actions.isQuickLookVisible

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
        let catchesThrow = dragging && !ui.ownDragActive && settings.dragReveal != .off
            && !config.exactPointer
            && onScreen && !innerEdge && dx < config.dragExpand.distance
            && expandedBody.insetBy(dx: 0, dy: -12).contains(loc)
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
