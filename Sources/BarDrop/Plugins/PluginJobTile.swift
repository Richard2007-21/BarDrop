import AppKit
import SwiftUI

/// Platzhalter für ein laufendes Plugin, direkt neben dem Original (bei „Original ersetzen“
/// an seiner Stelle): eine sichtbare, aber durchsichtige Vorschau, die mit dem Fortschritt
/// deckend wird. Gezeigt wird das Ergebnis, sobald das Plugin eine fertige Datei geschrieben
/// hat, bis dahin die Datei, an der es arbeitet. Meldet das Plugin keinen Fortschritt, wird
/// die Vorschau sanft deckender und wieder durchsichtiger („atmet“). Welches Plugin arbeitet,
/// zeigt sein Symbol oben rechts im Kopf der Ablage.
///
/// Auswählen wie eine Kachel (Klick, ⌘- bzw. ⇧-Klick, Lasso, Pfeiltasten); ⌫ bricht ab.
/// Wie bei Downloads im Finder und im App Store: Fährt der Zeiger darüber, wird das Zeichen
/// in der Mitte zum Knopf für Anhalten bzw. Fortsetzen, und oben rechts erscheint ein
/// kleines x zum Abbrechen. Der Rechtsklick bietet dasselbe zusätzlich an.
struct PluginJobTile: View {
    @ObservedObject var job: PluginJob
    @ObservedObject var ui: ShelfUIModel
    @Environment(\.shelfDemo) private var shelfDemo
    let actions: ShelfActions
    var iconSize: CGFloat = 64
    @State private var hovering = false

    private var showsControls: Bool { hovering && !shelfDemo }

    var body: some View {
        TileLabel(title: job.isStarted ? (job.label ?? job.title) : L("Waiting", "Wartet"),
                  isSelected: ui.jobSelection.contains(job.id), isKey: ui.isKey || ui.level == .expanded,
                  iconSize: iconSize) {
            PluginPreview(job: job, size: iconSize, hovering: showsControls)
        }
        .overlay(Group { if !shelfDemo {
            PluginJobMenuArea(ui: ui, menu: { actions.menu(for: job) },
                              onClick: { modifiers in actions.selectJob(job, modifiers: modifiers) })
        } })
        // Über der Fläche für den Rechtsklick, damit die Knöpfe Klicks bekommen
        .overlay(alignment: .top) { if showsControls { controls } }
        .onHover { inside in
            withAnimation(.easeOut(duration: 0.12)) { hovering = inside }
        }
        .help(job.percent.map { "\(job.title): " + Format.percent($0) } ?? job.title)
        .transition(.opacity)
    }

    /// Knöpfe genau über dem Vorschaubild (gleiche Lage wie das Symbol in TileLabel)
    private var controls: some View {
        let box = TileMetrics.box(iconSize)
        let cancelSize = max(16, (iconSize * 0.24).rounded())
        return ZStack {
            if job.isStarted {
                // Nur so groß wie das Zeichen in der Mitte: Ein Klick daneben wählt aus
                Button {
                    if job.paused { job.resume() } else { job.pause() }
                } label: {
                    Circle().fill(Color.clear)
                        .frame(width: iconSize * 0.38, height: iconSize * 0.38)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help(job.paused ? L("Resume", "Fortsetzen") : L("Pause", "Anhalten"))
                .accessibilityLabel(job.paused ? L("Resume", "Fortsetzen") : L("Pause", "Anhalten"))
            }
            Button {
                actions.plugins.cancel(job)
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: cancelSize))
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(Color.black.opacity(0.85), Color(white: 0.78))
                    .background(Circle().fill(Color.black).padding(1))
            }
            .buttonStyle(.plain)
            .help(L("Cancel", "Abbrechen"))
            .accessibilityLabel(L("Cancel", "Abbrechen"))
            .offset(x: iconSize * 0.46, y: -iconSize * 0.46)
            .transition(.scale(scale: 0.6).combined(with: .opacity))
        }
        .frame(width: box, height: box)
        .padding(.top, 6)
    }
}

/// Vorschau, durchsichtig je nach Fortschritt: das Ergebnis, sobald es da ist, sonst die
/// Datei, an der das Plugin arbeitet
private struct PluginPreview: View {
    @ObservedObject var job: PluginJob
    let size: CGFloat
    /// Zeiger darüber: In der Mitte steht, was ein Klick tut (Anhalten oder Fortsetzen)
    var hovering = false
    @State private var breathing = false

    /// Am Anfang gut zu sehen, aber deutlich durchsichtig
    private static let startOpacity = 0.3

    private var breathes: Bool {
        job.isStarted && !job.paused && job.progress == nil && !AnimationStyle.reduceMotion
    }

    private var opacity: Double {
        let base: Double
        if !job.isStarted {
            base = Self.startOpacity
        } else if let progress = job.progress {
            base = Self.startOpacity + (1 - Self.startOpacity) * progress
        } else {
            base = breathing ? 0.6 : Self.startOpacity
        }
        return job.paused ? base * 0.75 : base
    }

    private var shownURL: URL { job.resultPreview ?? job.item.url }

    var body: some View {
        ZStack {
            ThumbnailView(url: shownURL, size: size)
                .id(shownURL)
                .transition(.opacity)
                .opacity(opacity)
                .animation(.easeOut(duration: 0.3), value: job.progress)
                .animation(.easeOut(duration: 0.3), value: job.paused)
                .animation(breathes ? .easeInOut(duration: 1.6).repeatForever(autoreverses: true) : .easeOut(duration: 0.3),
                           value: breathing)
            centerGlyph
                .animation(.easeOut(duration: 0.12), value: hovering)
        }
        .frame(width: size, height: size)
        .onAppear { breathing = breathes }
        .onChange(of: breathes) { _, now in breathing = now }
    }

    /// Mitte: beim Darüberfahren Anhalten bzw. Fortsetzen, sonst nur, wenn es wartet
    /// oder angehalten ist
    @ViewBuilder
    private var centerGlyph: some View {
        let symbol: String? = hovering && job.isStarted ? (job.paused ? "play.fill" : "pause.fill")
            : !job.isStarted ? "clock"
            : job.paused ? "pause.fill" : nil
        if let symbol {
            Image(systemName: symbol)
                .font(.system(size: size * 0.17, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: size * 0.38, height: size * 0.38)
                .background(Circle().fill(Color.black.opacity(0.5)))
                .contentTransition(.symbolEffect(.replace))
                .transition(.opacity)
        }
    }
}

/// Fläche über dem Platzhalter: Klick wählt aus, Rechtsklick (und ⌃-Klick) öffnet sein Menü
private struct PluginJobMenuArea: NSViewRepresentable {
    let ui: ShelfUIModel
    let menu: () -> NSMenu
    var onClick: (NSEvent.ModifierFlags) -> Void = { _ in }

    func makeNSView(context: Context) -> MenuNSView {
        let view = MenuNSView()
        configure(view)
        return view
    }

    func updateNSView(_ view: MenuNSView, context: Context) { configure(view) }

    private func configure(_ view: MenuNSView) {
        view.ui = ui
        view.menuProvider = menu
        view.onClick = onClick
    }

    final class MenuNSView: NSView {
        weak var ui: ShelfUIModel?
        var menuProvider: () -> NSMenu = { NSMenu() }
        var onClick: (NSEvent.ModifierFlags) -> Void = { _ in }

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func rightMouseDown(with event: NSEvent) {
            onClick([])
            show(event)
        }

        override func mouseDown(with event: NSEvent) {
            if event.modifierFlags.contains(.control) {
                onClick([])
                show(event)
            } else {
                onClick(event.modifierFlags)
            }
        }

        private func show(_ event: NSEvent) {
            ui?.menuOpen = true
            ShelfMenu.popUp(menuProvider(), with: event, for: self)
            ui?.menuOpen = false
        }
    }
}
