import AppKit
import SwiftUI

/// Platzhalter für ein laufendes Plugin, direkt neben dem Original (bei „Original ersetzen“
/// an seiner Stelle): das Vorschaubild der Datei, an der das Plugin arbeitet. Es ist erst
/// unscharf und wird mit dem Fortschritt klar. Meldet das Plugin keinen Fortschritt, wird es
/// sanft klarer und wieder unscharf („atmet“). Welches Plugin arbeitet, zeigt sein Symbol
/// oben rechts im Kopf der Ablage.
///
/// Bedienung wie bei Downloads im Finder und im App Store: Fährt der Zeiger darüber, wird
/// die Mitte zum Knopf für Anhalten bzw. Fortsetzen, und oben rechts erscheint ein kleines
/// x zum Abbrechen. Der Rechtsklick bietet dasselbe zusätzlich an.
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
                  isSelected: false, isKey: false, iconSize: iconSize) {
            PluginPreview(job: job, size: iconSize, hovering: showsControls)
        }
        .overlay(Group { if !shelfDemo {
            PluginJobMenuArea(ui: ui) { actions.menu(for: job) }
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
                Button {
                    if job.paused { job.resume() } else { job.pause() }
                } label: {
                    Circle().fill(Color.clear)
                        .frame(width: iconSize * 0.6, height: iconSize * 0.6)
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

/// Vorschaubild der Datei, unscharf je nach Fortschritt
private struct PluginPreview: View {
    @ObservedObject var job: PluginJob
    let size: CGFloat
    /// Zeiger darüber: In der Mitte steht, was ein Klick tut (Anhalten oder Fortsetzen)
    var hovering = false
    @State private var breathing = false

    /// Ganz am Anfang so unscharf, dass man das Bild nur ahnt
    private var maxBlur: CGFloat { max(4, (size * 0.12).rounded()) }

    private var breathes: Bool {
        job.isStarted && !job.paused && job.progress == nil && !AnimationStyle.reduceMotion
    }

    private var blur: CGFloat {
        if !job.isStarted { return maxBlur }
        if let progress = job.progress { return maxBlur * CGFloat(1 - progress) }
        return breathing ? maxBlur * 0.45 : maxBlur
    }

    var body: some View {
        ZStack {
            ThumbnailView(url: job.item.url, size: size)
                .blur(radius: blur)
                .saturation(job.progress.map { 0.5 + 0.5 * $0 } ?? 0.6)
                .opacity(job.paused ? 0.75 : 1)
                .animation(.easeOut(duration: 0.3), value: job.progress)
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

/// Fläche über dem Platzhalter: Rechtsklick (und ⌃-Klick) öffnet sein Menü
private struct PluginJobMenuArea: NSViewRepresentable {
    let ui: ShelfUIModel
    let menu: () -> NSMenu

    func makeNSView(context: Context) -> MenuNSView {
        let view = MenuNSView()
        view.ui = ui
        view.menuProvider = menu
        return view
    }

    func updateNSView(_ view: MenuNSView, context: Context) {
        view.ui = ui
        view.menuProvider = menu
    }

    final class MenuNSView: NSView {
        weak var ui: ShelfUIModel?
        var menuProvider: () -> NSMenu = { NSMenu() }

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func rightMouseDown(with event: NSEvent) { show(event) }

        override func mouseDown(with event: NSEvent) {
            if event.modifierFlags.contains(.control) { show(event) }
        }

        private func show(_ event: NSEvent) {
            ui?.menuOpen = true
            ShelfMenu.popUp(menuProvider(), with: event, for: self)
            ui?.menuOpen = false
        }
    }
}
