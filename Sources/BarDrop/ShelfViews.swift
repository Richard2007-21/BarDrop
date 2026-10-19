import SwiftUI
import UniformTypeIdentifiers
import AppKit

// MARK: Übergang: weich einblenden mit Unschärfe (Stärke je nach Einstellung)

struct BlurFade: ViewModifier {
    var radius: CGFloat
    var opacity: Double
    var scale: CGFloat
    func body(content: Content) -> some View {
        content.blur(radius: radius).opacity(opacity).scaleEffect(scale)
    }
}

extension AnyTransition {
    static func blurFade(_ radius: CGFloat) -> AnyTransition {
        // „Bewegung reduzieren“: nur überblenden
        if radius == 0 { return .opacity.animation(.easeOut(duration: 0.15)) }
        return .asymmetric(
            insertion: .modifier(active: BlurFade(radius: radius, opacity: 0, scale: 0.94),
                                 identity: BlurFade(radius: 0, opacity: 1, scale: 1))
                .animation(.easeOut(duration: 0.28).delay(0.07)),
            removal: .modifier(active: BlurFade(radius: radius * 0.7, opacity: 0, scale: 0.96),
                               identity: BlurFade(radius: 0, opacity: 1, scale: 1))
                .animation(.easeIn(duration: 0.12))
        )
    }
}

// MARK: Wurzelansicht: die schwarze Form und ihr Inhalt

struct ShelfRootView: View {
    @ObservedObject var ui: ShelfUIModel
    @ObservedObject var store: ShelfStore
    @ObservedObject var settings: AppSettings
    let actions: ShelfActions

    private var edgeAlignment: Alignment { settings.edge == .right ? .trailing : .leading }

    var body: some View {
        let m = ShelfMetrics.for(ui.level, settings: settings)
        let full = ShelfMetrics.for(.expanded, settings: settings)
        let shape = EdgeBlobShape(edge: settings.edge, cornerRadius: m.cornerRadius, fillet: m.fillet,
                                  filletStretch: m.filletStretch, cornerStretch: m.cornerStretch)

        ZStack(alignment: edgeAlignment) {
            Color.clear

            ZStack(alignment: edgeAlignment) {
                // Weicher Schatten, der innerhalb des Fensterrands ganz ausläuft
                // (Platz dafür: ShelfMetrics.panelMargin). Nur eine Ebene: Jeder Schatten
                // wird in jedem Bild der Animation neu berechnet.
                shape
                    .fill(Color.black)
                    .shadow(color: .black.opacity(ui.level == .expanded ? 0.45 : 0),
                            radius: 18, x: 0, y: 8)

                // Feiner heller Rahmen: auf dunklem Hintergrund sichtbar, auf hellem
                // verschwindet er fast. Ohne Linie am Bildschirmrand selbst.
                EdgeBlobShape(edge: settings.edge, cornerRadius: m.cornerRadius, fillet: m.fillet,
                              filletStretch: m.filletStretch, cornerStretch: m.cornerStretch, closed: false)
                    .stroke(Color.white.opacity(settings.showOutline || ui.forcesOutline ? 0.2 : 0), lineWidth: 1)
                    .allowsHitTesting(false)

                content(m: m, full: full)
                    .clipShape(shape)
            }
            .frame(width: m.width, height: m.height + 2 * m.fillet, alignment: edgeAlignment)
            // Kleine Stufen sitzen auf der Wunschhöhe (adaptiv: am Zeiger), die offene Ablage mittig im Fenster
            .offset(y: ui.level == .expanded ? 0 : ui.anchorOffset)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .environment(\.colorScheme, .dark)
    }

    /// Inhalt innerhalb der Form: Pfeil in der mittleren Stufe, Ablage im offenen Zustand.
    private func content(m: ShelfMetrics, full: ShelfMetrics) -> some View {
        ZStack(alignment: edgeAlignment) {
            Color.clear

            if ui.level == .hint {
                Color.clear
                    .frame(width: m.width, height: m.height)
                    .contentShape(Rectangle())
                    .onTapGesture { ui.expandRequested = true }   // Modus „Per Klick“
                    .transition(.opacity)
            }

            if ui.level == .expanded {
                ShelfContent(ui: ui, store: store, settings: settings, actions: actions, runner: actions.plugins)
                    .frame(width: full.width, height: full.height)
                    .padding(.vertical, full.fillet)
                    // Während etwas aus der Ablage gezogen wird, nur überblenden: Die Unschärfe
                    // wird in jedem Bild neu berechnet und bremst die App, die das gezogene Bild
                    // bewegt (Ruckeln beim Herausziehen, wenn die Ablage zu- und aufgeht)
                    .transition(.blurFade(ui.ownDragActive ? 0 : settings.animationStyle.blur))
            }
        }
        .frame(width: m.width, height: m.height + 2 * m.fillet, alignment: edgeAlignment)
    }
}

// MARK: Inhalt der offenen Ablage

/// Scrollstand der Ablage. `offset` ändert sich bei jedem Bild des Scrollens und löst
/// darum nichts aus; nur ob überhaupt gescrollt ist, zeichnet neu (weicher Übergang oben).
final class ScrollTracker: ObservableObject {
    /// Oberkante des Rasters im sichtbaren Bereich (0 oben, negativ beim Scrollen)
    var offset: CGFloat = 0 {
        didSet {
            let now = offset < -0.5
            if now != scrolled { scrolled = now }
        }
    }
    @Published private(set) var scrolled = false
}

private struct ScrollOffsetKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

private struct BarHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

struct ShelfContent: View {
    @ObservedObject var ui: ShelfUIModel
    /// Vorführung in der Einführung: ohne Klick-, Zieh- und Drop-Flächen
    @Environment(\.shelfDemo) private var shelfDemo
    @ObservedObject var store: ShelfStore
    @ObservedObject var settings: AppSettings
    let actions: ShelfActions
    /// Laufende Plugins: ihre Platzhalter stehen direkt neben dem Original
    @ObservedObject var runner: PluginRunner

    @State private var tileFrames: [UUID: CGRect] = [:]
    /// Höhe des sichtbaren Bereichs der Kacheln (bis unter die Aktionsleiste)
    @State private var viewportHeight: CGFloat = 0
    /// Wie weit gescrollt ist; ändert die Ansicht nur, wenn sich `scrolled` ändert
    @StateObject private var scroll = ScrollTracker()
    @State private var band: CGRect?
    @State private var selectionBeforeBand: Set<UUID> = []
    /// Höhe der Aktionsleiste: so viel Platz bleibt unter den Kacheln frei
    @State private var barHeight: CGFloat = 0
    /// Platzhalter erst nach einem Augenblick zeigen: Dateien aus dem Finder sind sofort
    /// da, für sie soll nichts aufblitzen
    @State private var showPending = false
    /// Hinter der Aktionsleiste ganz deckend, mit einer klaren Kante statt eines Nebels:
    /// Kacheln laufen sichtbar unter einer feinen Linie hindurch, wie unter einer Leiste
    /// in macOS.
    private var barBackdrop: some View {
        Rectangle()
            .fill(Color.black)
            .overlay(alignment: .top) {
                Rectangle()
                    .fill(Color.white.opacity(0.1))
                    .frame(height: 1)
            }
            .frame(height: barHeight)
            .allowsHitTesting(false)
    }

    /// Übergang unter dem Kopf: dieselbe S-Kurve wie über der Leiste, gespiegelt
    private var topFade: some View {
        let stops: [Gradient.Stop] = Self.fadeCurve.reversed().map { point in
            Gradient.Stop(color: Color.black.opacity(point.1), location: 1 - point.0)
        }
        return LinearGradient(stops: stops, startPoint: .top, endPoint: .bottom)
            .frame(height: Self.headerFade)
            .allowsHitTesting(false)
    }

    /// Länge des Verlaufs unter dem Kopf
    private static let headerFade: CGFloat = 24
    /// Deckkraft entlang des Verlaufs (S-Kurve, smoothstep)
    private static let fadeCurve: [(CGFloat, Double)] = {
        var points: [(CGFloat, Double)] = []
        for i in 0...8 {
            let t: Double = Double(i) / 8
            let alpha: Double = t * t * (3.0 - 2.0 * t)
            points.append((CGFloat(t), alpha))
        }
        return points
    }()

    /// Spalten passend zur Symbolgröße
    private var columns: [GridItem] {
        let icon = CGFloat(settings.tileIconSize)
        return [GridItem(.adaptive(minimum: icon + 22, maximum: icon + 40), spacing: 8)]
    }

    /// Geöffneter Stapel, solange er noch ein Stapel ist.
    private var stack: ShelfEntry? {
        guard let entry = actions.openStackEntry, entry.isStack else { return nil }
        return entry
    }

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, 18)
                .frame(height: 30)
                .padding(.top, 12)
                .padding(.bottom, 4)

            // Die Kacheln laufen unter der Aktionsleiste weiter, statt über ihr abgeschnitten
            // zu werden; hinter der Leiste liegt ein weicher Verlauf ins Schwarz
            ZStack(alignment: .bottom) {
                GeometryReader { geo in
                    ScrollViewReader { proxy in
                    ScrollView(.vertical, showsIndicators: false) {
                        Group {
                            if let stack {
                                stackGrid(stack)
                                    .transition(.opacity)
                            } else {
                                mainGrid
                                    .transition(.opacity)
                            }
                        }
                        // Platz unter der letzten Reihe: Sie lässt sich ganz über die Leiste scrollen
                        .padding(.bottom, barHeight)
                        .frame(maxWidth: .infinity, minHeight: geo.size.height, alignment: .top)
                        // Ohne Fokus laufen Einblend-Animationen nicht zuverlässig weiter: neue
                        // Kacheln dann sofort zeigen statt unsichtbar am Anfang der Animation
                        .transaction { if !ui.isKey { $0.animation = nil } }
                        .coordinateSpace(name: "grid")
                        // Wie weit gescrollt ist (Oberkante des Rasters im sichtbaren Bereich)
                        .background(GeometryReader { g in
                            Color.clear.preference(key: ScrollOffsetKey.self,
                                                   value: g.frame(in: .named("viewport")).minY)
                        })
                        .background(Group { if !shelfDemo {
                            SelectionBackground(
                                ui: ui,
                                onBandChanged: updateBand,
                                onClick: { actions.clearCurrentSelection() },
                                menu: { actions.backgroundMenu() },
                                // Der Rahmen endet über der Aktionsleiste und ihrem Übergang
                                bottomInset: barHeight
                            )
                        } })
                        .overlay(alignment: .topLeading) { bandOverlay }
                        .onPreferenceChange(TileFramesKey.self) { tileFrames = $0 }
                    }
                    // Oben derselbe weiche Übergang wie über der Aktionsleiste: Was unter den
                    // Kopf scrollt, läuft ins Schwarz aus statt hart abgeschnitten zu werden
                    .overlay(alignment: .top) {
                        topFade
                            .opacity(scroll.scrolled ? 1 : 0)
                            .animation(.easeOut(duration: 0.15), value: scroll.scrolled)
                    }
                    .coordinateSpace(name: "viewport")
                    .onAppear {
                        viewportHeight = geo.size.height
                        restoreScroll(proxy: proxy, viewport: geo.size.height)
                    }
                    .onDisappear { saveScroll() }
                    .onChange(of: geo.size.height) { _, height in viewportHeight = height }
                    .onPreferenceChange(ScrollOffsetKey.self) { scroll.offset = $0 }
                    // Pfeiltasten: Die ausgewählte Kachel bleibt ganz zu sehen, wie im Finder
                    .onChange(of: ui.scrollRequest) { _, request in
                        reveal(request, proxy: proxy, viewport: geo.size.height)
                    }
                    }
                }

                // Flach gehalten: so viel Schwarz wie nötig unter den Symbolen, nicht mehr
                QuickActionBar(settings: settings, ui: ui, store: store, actions: actions)
                    .padding(.horizontal, 10)
                    .padding(.bottom, 8)
                    .padding(.top, 2)
                    .background(alignment: .bottom) { barBackdrop }
                    .background(
                        GeometryReader { g in
                            Color.clear.preference(key: BarHeightKey.self, value: g.size.height)
                        }
                    )
            }
            .onPreferenceChange(BarHeightKey.self) { barHeight = $0 }
        }
        .background(Group { if !shelfDemo {
            // Leere Stellen außerhalb des Rasters (Kopfbereich, Ränder): Klick und Rechtsklick
            SelectionBackground(
                ui: ui,
                onBandChanged: { _, _ in },
                onClick: { actions.clearCurrentSelection() },
                menu: { actions.backgroundMenu() },
                allowsBand: false
            )
        } })
        .overlay(dropHighlight)
        .onChange(of: store.pendingImports) { _, count in
            if count == 0 {
                showPending = false
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                    guard store.pendingImports > 0, !showPending else { return }
                    showPending = true
                    // Platzhalter erscheinen später als die Änderung, die neu zeichnen ließ
                    NotificationCenter.default.post(name: Thumbnails.didChange, object: nil)
                }
            }
        }
        .onChange(of: store.entries) { _, _ in
            // Stapel aufgelöst oder entfernt: zurück zur Ablage
            if ui.openStack != nil && stack == nil { ui.openStack = nil }
        }
    }

    // MARK: Kopfbereich

    /// Titel oben: „BarDrop“, „Ablage“ oder keiner (Aussehen → Titel)
    private var title: String? {
        settings.titleStyle.text
    }

    @ViewBuilder
    private var header: some View {
        HStack(alignment: .center, spacing: 8) {
            if let stack {
                Button {
                    actions.closeStack()
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 11, weight: .semibold))
                        if let title {
                            Text(title)
                                .font(.system(size: 13, weight: .semibold))
                        }
                    }
                    .foregroundStyle(.white.opacity(0.92))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(L("Back to the shelf (esc)", "Zurück zur Ablage (esc)"))
                Spacer(minLength: 8)
                let selected = ui.memberSelection.intersection(stack.files.map(\.id)).count
                status(selected > 0 ? L("\(selected) of \(stack.files.count) selected", "\(selected) von \(stack.files.count) ausgewählt")
                                    : L("\(stack.files.count) items in stack", "\(stack.files.count) Objekte im Stapel"))
            } else {
                if let title {
                    Text(title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.92))
                        .allowsHitTesting(false)
                }
                Spacer(minLength: 8)
                let count = store.entries.reduce(0) { $0 + $1.files.count }
                let selected = actions.selectedEntries.reduce(0) { $0 + $1.files.count }
                if store.pendingImports > 0 && ui.notice == nil {
                    // Große Dateien, Downloads und iCloud brauchen einen Moment
                    HStack(spacing: 5) {
                        ProgressView().controlSize(.mini)
                        countLabel(L("Importing", "Wird übernommen"))
                    }
                } else {
                    status(count == 0 ? nil
                           : selected > 0 ? L("\(selected) of \(count) selected", "\(selected) von \(count) ausgewählt")
                           : (count == 1 ? L("1 item", "1 Objekt") : L("\(count) items", "\(count) Objekte")))
                }
            }
        }
    }

    /// Rechts im Kopf: kurz eine Rückmeldung, sonst die Anzahl.
    @ViewBuilder
    private func status(_ fallback: String?) -> some View {
        if let notice = ui.notice {
            countLabel(notice.text)
                .id(notice.id)
            .transition(.opacity)
        } else if let fallback {
            countLabel(fallback)
        }
    }

    private func countLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .medium))
            .monospacedDigit()
            .foregroundStyle(.white.opacity(0.5))
            .lineLimit(1)
            .transaction { $0.animation = nil }   // Zahl ändert sich ohne Animation
            .allowsHitTesting(false)
    }

    // MARK: Raster

    /// Neue Kacheln erscheinen sofort in voller Deckkraft, nur beim Entfernen wird
    /// ausgeblendet. Eine Einblendung kann hängen bleiben, wenn die Ablage gerade
    /// nicht gezeichnet wird; die Kachel stünde dann unsichtbar da, bis sich die
    /// Ablage neu öffnet.
    private static let tileTransition = AnyTransition.asymmetric(insertion: .identity, removal: .opacity)

    @ViewBuilder
    private var mainGrid: some View {
        if store.entries.isEmpty && !showPending && !ui.showSampleTile {
            // Mittig in der Fläche zwischen Kopf und Aktionsleiste
            emptyState
                .frame(maxWidth: .infinity)
                .frame(height: max(0, viewportHeight - barHeight))
                .allowsHitTesting(false)
                .transition(Self.tileTransition)
        } else {
            LazyVGrid(columns: columns, spacing: 6) {
                // Was gerade noch geladen wird (Bilder aus dem Web, große Dateien),
                // steht sofort als Kachel da, an der Stelle, an der es landen wird
                if showPending && settings.sortOrder == .newestFirst { pendingTiles }
                ForEach(actions.orderedEntries) { entry in
                    TileView(entry: entry, ui: ui, actions: actions,
                             isSelected: ui.selection.contains(entry.id),
                             iconSize: CGFloat(settings.tileIconSize))
                        .background(
                            GeometryReader { g in
                                Color.clear.preference(key: TileFramesKey.self,
                                                       value: [entry.id: g.frame(in: .named("grid"))])
                            }
                        )
                        .transition(Self.tileTransition)
                    if !runner.jobs.isEmpty {
                        ForEach(runner.jobs(nextTo: entry.files.map(\.id))) { job in
                            PluginJobTile(job: job, ui: ui, actions: actions, iconSize: CGFloat(settings.tileIconSize))
                        }
                    }
                }
                if showPending && settings.sortOrder == .oldestFirst { pendingTiles }
                if ui.showSampleTile { sizeGuides }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .transition(Self.tileTransition)
        }
    }

    /// Beim Verstellen der Symbolgröße: leere Plätze in der neuen Größe, bis zwei Reihen
    /// gefüllt sind. So sieht man Größe und Anzahl pro Reihe, auch in einer leeren Ablage.
    /// Erscheinen ohne Einblendung, damit sie dem Regler sofort folgen.
    @ViewBuilder
    private var sizeGuides: some View {
        let icon = CGFloat(settings.tileIconSize)
        let width = max(ui.expandedBody.width - 24, icon + 22)
        let perRow = max(1, Int((width + 8) / (icon + 22 + 8)))
        let count = max(0, perRow * 2 - store.entries.count)
        ForEach(0..<count, id: \.self) { i in
            SizeGuideTile(index: i, iconSize: icon)
        }
    }

    /// Platzhalter für laufende Übernahmen, je eine Kachel
    @ViewBuilder
    private var pendingTiles: some View {
        ForEach(0..<max(store.pendingImports, 0), id: \.self) { _ in
            TileLabel(title: L("Loading", "Wird geladen"), isSelected: false, isKey: false) {
                ProgressView()
                    .controlSize(.small)
            }
            .allowsHitTesting(false)
        }
    }

    private func stackGrid(_ stack: ShelfEntry) -> some View {
        LazyVGrid(columns: columns, spacing: 6) {
            ForEach(stack.files) { file in
                StackMemberTile(file: file, entry: stack, ui: ui, actions: actions,
                                isSelected: ui.memberSelection.contains(file.id),
                                iconSize: CGFloat(settings.tileIconSize))
                    .background(
                        GeometryReader { g in
                            Color.clear.preference(key: TileFramesKey.self,
                                                   value: [file.id: g.frame(in: .named("grid"))])
                        }
                    )
                    .transition(Self.tileTransition)
                if !runner.jobs.isEmpty {
                    ForEach(runner.jobs(nextTo: [file.id])) { job in
                        PluginJobTile(job: job, ui: ui, actions: actions, iconSize: CGFloat(settings.tileIconSize))
                    }
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    // MARK: An letzter Stelle öffnen

    /// Beim Schließen: oberste sichtbare Kachel und ihre Lage merken
    private func saveScroll() {
        guard !shelfDemo else { return }
        guard settings.reopenWhereLeft, scroll.scrolled else {
            ui.savedScroll = nil
            return
        }
        let offset = scroll.offset
        let visible = tileFrames.filter { $0.value.maxY + offset > 0 }
        guard let top = visible.min(by: { ($0.value.minY, $0.value.minX) < ($1.value.minY, $1.value.minX) }) else {
            ui.savedScroll = nil
            return
        }
        ui.savedScroll = (top.key, top.value.minY + offset, top.value.height)
    }

    /// Beim Öffnen: dieselbe Kachel wieder an dieselbe Stelle scrollen, ohne Bewegung
    private func restoreScroll(proxy: ScrollViewProxy, viewport: CGFloat) {
        guard !shelfDemo, settings.reopenWhereLeft, let saved = ui.savedScroll else { return }
        let ids = stack.map { $0.files.map(\.id) } ?? actions.orderedEntries.map(\.id)
        guard ids.contains(saved.id) else { return }
        let span = viewport - saved.height
        let anchor = UnitPoint(x: 0.5, y: span > 0 ? min(max(saved.top / span, 0), 1) : 0)
        DispatchQueue.main.async {
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) { proxy.scrollTo(saved.id, anchor: anchor) }
        }
    }

    // MARK: Mitscrollen

    /// Macht die Kachel `request.id` ganz sichtbar: oben unter dem Kopf, unten über der
    /// Aktionsleiste. Liegt sie schon ganz im sichtbaren Bereich, bleibt alles stehen.
    private func reveal(_ request: ShelfUIModel.ScrollRequest?, proxy: ScrollViewProxy, viewport: CGFloat) {
        guard let request else { return }
        let id = request.id
        let tileHeight = tileFrames[id]?.height ?? tileFrames.values.first?.height
            ?? CGFloat(settings.tileIconSize) + 60
        // Außerhalb der weichen Übergänge oben und über der Leiste (die Kachel hat selbst
        // 6 pt Rand oben und unten)
        let top = Self.headerFade - 6
        let bottom = viewport - barHeight - 4
        let span = viewport - tileHeight
        guard span > 0, bottom - top >= tileHeight else {
            proxy.scrollTo(id, anchor: .top)
            return
        }
        let alignTop = UnitPoint(x: 0.5, y: min(max(top / span, 0), 1))
        let alignBottom = UnitPoint(x: 0.5, y: min(max((bottom - tileHeight) / span, 0), 1))
        if let frame = tileFrames[id] {
            let y = frame.minY + scroll.offset
            if y < top {
                proxy.scrollTo(id, anchor: alignTop)
            } else if y + frame.height > bottom {
                proxy.scrollTo(id, anchor: alignBottom)
            }
        } else {
            // Noch nicht angelegt (weit außerhalb): vor oder hinter den sichtbaren Kacheln?
            let ids = stack.map { $0.files.map(\.id) } ?? actions.orderedEntries.map(\.id)
            let shown = ids.indices.filter { tileFrames[ids[$0]] != nil }
            let index = ids.firstIndex(of: id) ?? 0
            proxy.scrollTo(id, anchor: index < (shown.min() ?? 0) ? alignTop : alignBottom)
        }
    }

    // MARK: Auswahlrahmen

    @ViewBuilder
    private var bandOverlay: some View {
        if let band {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.white.opacity(0.08))
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.35), lineWidth: 1)
                )
                .frame(width: band.width, height: band.height)
                .offset(x: band.minX, y: band.minY)
                .allowsHitTesting(false)
        }
    }

    private func updateBand(_ rect: CGRect?, modifiers: NSEvent.ModifierFlags) {
        guard let rect else {
            band = nil
            return
        }
        let additive = modifiers.contains(.command) || modifiers.contains(.shift)
        let inStack = stack != nil
        if band == nil {
            selectionBeforeBand = additive ? (inStack ? ui.memberSelection : ui.selection) : []
        }
        band = rect
        let hit = Set(tileFrames.filter { $0.value.intersects(rect) }.map(\.key))
        if let stack {
            ui.memberSelection = selectionBeforeBand.union(hit)
            if let first = stack.files.first(where: { hit.contains($0.id) }) { ui.memberAnchor = first.id }
        } else {
            ui.selection = selectionBeforeBand.union(hit)
            if let first = actions.orderedEntries.first(where: { hit.contains($0.id) }) { ui.selectionAnchor = first.id }
        }
    }

    // MARK: Leerer Zustand, Drop-Hervorhebung

    /// Leere Ablage: Symbol und „Hier ablegen“, zurückgenommen grau; erst wenn etwas
    /// darübergezogen wird, weiß
    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "tray.and.arrow.down")
                .font(.system(size: 30, weight: .light))
                .scaleEffect(ui.isDropTargeted ? 1.12 : 1)
            Text(L("Drop here", "Hier ablegen"))
                .font(.system(size: 14, weight: .semibold))
        }
        .foregroundStyle(.white.opacity(ui.isDropTargeted ? 1 : 0.45))
    }

    private var dropHighlight: some View {
        RoundedRectangle(cornerRadius: 22, style: .continuous)
            .strokeBorder(Color.white.opacity(ui.isDropTargeted ? 0.28 : 0), lineWidth: 1.5)
            .background(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(Color.white.opacity(ui.isDropTargeted ? 0.05 : 0))
            )
            .padding(8)
            .allowsHitTesting(false)
    }
}

// MARK: Kachel (Darstellung wie im Finder)

/// Gemeinsame Darstellung: Vorschau mit grauer Fläche und Name in Akzentfarbe, wenn ausgewählt.
/// Leerer Platz in Kachelgröße (Vorschau der Symbolgröße)
/// Beispiel beim Verstellen der Symbolgröße: sieht aus wie eine Datei in der Ablage (echtes
/// Symbol des Dateityps und Name), damit man Größe, Namen und Abstände wirklich beurteilen
/// kann. Etwas zurückgenommen, damit es nicht mit eigenen Objekten verwechselt wird.
private struct SizeGuideTile: View {
    let index: Int
    let iconSize: CGFloat

    /// Typische Dateien, reihum
    private static let examples: [(name: () -> String, type: UTType)] = [
        ({ L("Document.pdf", "Dokument.pdf") }, .pdf),
        ({ L("Photo.jpg", "Foto.jpg") }, .jpeg),
        ({ L("Notes.txt", "Notizen.txt") }, .plainText),
        ({ L("Project", "Projekt") }, .folder),
        ({ L("Video.mov", "Video.mov") }, .quickTimeMovie),
        ({ L("Archive.zip", "Archiv.zip") }, .zip)
    ]

    private static var icons: [String: NSImage] = [:]

    private static func icon(_ type: UTType) -> NSImage {
        if let cached = icons[type.identifier] { return cached }
        let image = NSWorkspace.shared.icon(for: type)
        icons[type.identifier] = image
        return image
    }

    var body: some View {
        let example = Self.examples[index % Self.examples.count]
        TileLabel(title: example.name(), isSelected: false, isKey: false, iconSize: iconSize) {
            Image(nsImage: Self.icon(example.type))
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .frame(width: iconSize, height: iconSize)
                .shadow(color: .black.opacity(0.35), radius: 3, x: 0, y: 1)
        }
        .opacity(0.75)
        .allowsHitTesting(false)
        .transaction { $0.animation = nil }
    }
}

/// Maße der Auswahl wie im Finder (Symbolansicht, abgenommen an macOS 26): Die graue
/// Fläche ist rund ein Viertel größer als das Symbol, mit leicht gerundeten Ecken; die
/// Markierung des Namens ist etwas breiter als die Fläche, mit knapp 5 pt Rundung.
enum TileMetrics {
    /// Seitenlänge der grauen Fläche um das Symbol
    static func box(_ iconSize: CGFloat) -> CGFloat {
        // Höchstens so breit wie die schmalste Spalte des Rasters (Symbol + 22 pt)
        iconSize + 2 * min(11, max(6, (iconSize * 0.12).rounded()))
    }

    static func boxRadius(_ iconSize: CGFloat) -> CGFloat {
        (box(iconSize) * 0.093).rounded()
    }

    /// Höchstbreite der Markierung des Namens: wie im Finder etwas breiter als die Fläche,
    /// aber nie schmaler als bisher, damit kurze Namen („Document.pdf“) nicht umbrechen
    /// (die Schrift ist kleiner als im Finder)
    static func labelWidth(_ iconSize: CGFloat) -> CGFloat {
        max((box(iconSize) * 1.083).rounded(), iconSize + 2 * labelPadding + 20)
    }

    static let labelPadding: CGFloat = 6
    static let labelRadius: CGFloat = 4.5
}

struct TileLabel<Preview: View>: View {
    let title: String
    let isSelected: Bool
    let isKey: Bool
    var isDropTarget = false
    /// Eingestellte Symbolgröße (Aussehen → Größe)
    var iconSize: CGFloat = TileLabel<EmptyView>.iconSize
    @ViewBuilder let preview: () -> Preview

    static var iconSize: CGFloat { CGFloat(AppSettings.shared.tileIconSize) }

    private var nameBackground: Color {
        guard isSelected else { return .clear }
        return Color(nsColor: isKey ? .selectedContentBackgroundColor : .unemphasizedSelectedContentBackgroundColor)
    }

    var body: some View {
        let box = TileMetrics.box(iconSize)
        VStack(spacing: 4) {
            preview()
                .frame(width: iconSize + 4, height: iconSize + 4)
                .padding((box - iconSize - 4) / 2)
                .background(
                    RoundedRectangle(cornerRadius: TileMetrics.boxRadius(iconSize), style: .continuous)
                        .fill(Color.white.opacity(isSelected || isDropTarget ? 0.14 : 0))
                )
                .scaleEffect(isDropTarget ? 1.06 : 1)
                .animation(.spring(response: 0.25, dampingFraction: 0.85), value: isDropTarget)
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(isSelected ? Color.white : Color.white.opacity(0.88))
                .lineLimit(2)
                .truncationMode(.middle)
                .multilineTextAlignment(.center)
                .padding(.horizontal, TileMetrics.labelPadding)
                .padding(.vertical, 1)
                .background(RoundedRectangle(cornerRadius: TileMetrics.labelRadius, style: .continuous).fill(nameBackground))
                .frame(maxWidth: TileMetrics.labelWidth(iconSize), minHeight: 30, alignment: .top)
        }
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity)
    }
}

struct TileView: View {
    let entry: ShelfEntry
    @ObservedObject var ui: ShelfUIModel
    /// Vorführung in der Einführung: ohne Klick-, Zieh- und Drop-Flächen
    @Environment(\.shelfDemo) private var shelfDemo
    let actions: ShelfActions
    let isSelected: Bool
    /// Als Wert übergeben, damit sich die Kachel beim Verstellen sofort neu zeichnet
    var iconSize: CGFloat = 64

    var body: some View {
        TileLabel(title: entry.title, isSelected: isSelected, isKey: ui.isKey || ui.level == .expanded, iconSize: iconSize) {
            if entry.isStack {
                StackPreview(files: Array(entry.files.prefix(3)), size: (iconSize * 0.82).rounded())
            } else if let file = entry.files.first {
                ThumbnailView(url: file.url, size: iconSize)
            }
        }
        .overlay(Group { if !shelfDemo {
            DragSource(
                ui: ui,
                files: { actions.dragFiles(for: entry) },
                onMouseDown: { mods in actions.select(entry, modifiers: mods) },
                onClick: { clicks, mods in
                    actions.clickedWithoutDrag(entry, modifiers: mods)
                    if clicks >= 2 && !entry.isStack { actions.activate(entry) }
                },
                onDragEnded: { operation in
                    actions.dragEnded(actions.targets(for: entry).flatMap(\.files), operation: operation)
                },
                menu: { anchor in actions.menu(for: entry, anchor: anchor) },
                draggedIDs: { Set(actions.targets(for: entry).map(\.id)) },
                onShelfDrop: { pb in actions.store.ingest(from: pb, byUser: true) },
                onShelfTargeted: { targeted in
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.8)) { ui.isDropTargeted = targeted }
                }
            )
        } })
        .opacity(offlineVolume != nil ? 0.4 : 1)
        .help(offlineVolume.map { L("Drive “\($0)” isn’t connected", "Laufwerk „\($0)“ ist nicht angeschlossen") }
              ?? (entry.isStack ? L("Open stack", "Stapel öffnen") : entry.urls.map(\.lastPathComponent).joined(separator: "\n")))
    }

    /// Alle Dateien liegen auf einem Laufwerk, das gerade nicht angeschlossen ist
    private var offlineVolume: String? {
        let names = entry.files.map(\.offlineVolumeNameForDisplay)
        guard let first = names.first, let name = first, names.allSatisfy({ $0 != nil }) else { return nil }
        return name
    }
}

/// Datei innerhalb eines geöffneten Stapels: auswählbar wie die Kacheln der Ablage.
struct StackMemberTile: View {
    let file: ShelfFile
    let entry: ShelfEntry
    @ObservedObject var ui: ShelfUIModel
    /// Vorführung in der Einführung: ohne Klick-, Zieh- und Drop-Flächen
    @Environment(\.shelfDemo) private var shelfDemo
    let actions: ShelfActions
    let isSelected: Bool
    var iconSize: CGFloat = 64

    var body: some View {
        TileLabel(title: ShelfEntry.displayName(for: file.url), isSelected: isSelected, isKey: ui.isKey || ui.level == .expanded,
                  iconSize: iconSize) {
            ThumbnailView(url: file.url, size: iconSize)
        }
        .overlay(Group { if !shelfDemo {
            DragSource(
                ui: ui,
                files: { actions.memberDragFiles(for: file) },
                onMouseDown: { mods in actions.selectMember(file, modifiers: mods) },
                onClick: { clicks, mods in
                    actions.clickedMemberWithoutDrag(file, modifiers: mods)
                    if clicks >= 2 { actions.memberTargets(for: file).forEach { NSWorkspace.shared.open($0.url) } }
                },
                onDragEnded: { operation in
                    actions.dragEnded(actions.memberTargets(for: file), operation: operation)
                },
                menu: { anchor in actions.menu(for: file, in: entry, anchor: anchor) }
            )
        } })
        .opacity(file.offlineVolumeNameForDisplay != nil ? 0.4 : 1)
        .help(file.offlineVolumeNameForDisplay.map { L("Drive “\($0)” isn’t connected", "Laufwerk „\($0)“ ist nicht angeschlossen") } ?? file.url.lastPathComponent)
    }
}

/// Aufgefächerte Vorschau eines Stapels (bis zu drei Dateien).
private struct StackPreview: View {
    let files: [ShelfFile]
    let size: CGFloat

    private func angle(_ index: Int) -> Angle {
        .degrees(Double(index) * 7.0 - 7.0)
    }

    private func offsetX(_ index: Int) -> CGFloat {
        CGFloat(index) * 4.0 - 4.0
    }

    var body: some View {
        ZStack {
            ForEach(Array(files.indices.reversed()), id: \.self) { index in
                ThumbnailView(url: files[index].url, size: size)
                    .rotationEffect(angle(index))
                    .offset(x: offsetX(index), y: CGFloat(-2 * index))
            }
        }
    }
}

// MARK: Vorführung

private struct ShelfDemoKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// Die Ablage wird nur vorgeführt (Einführung): Sie zeichnet sich wie immer, legt aber
    /// keine AppKit-Flächen für Klicks, Ziehen und Ablegen an. So kann sie nichts auslösen.
    var shelfDemo: Bool {
        get { self[ShelfDemoKey.self] }
        set { self[ShelfDemoKey.self] = newValue }
    }
}
