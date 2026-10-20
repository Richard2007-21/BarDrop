import AppKit
import SwiftUI

/// Platzhalter für ein laufendes Plugin, direkt neben dem Original: ein schlichter Ring
/// mit dem Symbol des Plugins. Mit Fortschritt füllt er sich, ohne dreht ein kurzer Bogen.
/// Angehalten steht der Ring still und zeigt ein Pausenzeichen.
///
/// Bedienung wie bei Downloads im Finder und im App Store: Fährt der Zeiger darüber, wird
/// die Mitte des Rings zum Knopf für Anhalten bzw. Fortsetzen, und oben rechts erscheint
/// ein kleines x zum Abbrechen. Der Rechtsklick bietet dasselbe zusätzlich an.
struct PluginJobTile: View {
    @ObservedObject var job: PluginJob
    @ObservedObject var ui: ShelfUIModel
    @Environment(\.shelfDemo) private var shelfDemo
    let actions: ShelfActions
    var iconSize: CGFloat = 64
    @State private var hovering = false

    private var ringSize: CGFloat { (iconSize * 0.62).rounded() }
    private var showsControls: Bool { hovering && !shelfDemo }

    var body: some View {
        TileLabel(title: job.isStarted ? (job.label ?? job.title) : L("Waiting", "Wartet"),
                  isSelected: false, isKey: false, iconSize: iconSize) {
            PluginProgressRing(job: job, size: ringSize, hovering: showsControls)
                .frame(width: iconSize, height: iconSize)
        }
        .opacity(job.paused && !showsControls ? 0.7 : 1)
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

    /// Knöpfe genau über dem Ring (gleiche Lage wie das Symbol in TileLabel)
    private var controls: some View {
        let box = TileMetrics.box(iconSize)
        let cancelSize = max(16, (ringSize * 0.34).rounded())
        return ZStack {
            if job.isStarted {
                Button {
                    if job.paused { job.resume() } else { job.pause() }
                } label: {
                    Circle().fill(Color.clear)
                        .frame(width: ringSize, height: ringSize)
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
            .offset(x: ringSize * 0.42, y: -ringSize * 0.42)
            .transition(.scale(scale: 0.6).combined(with: .opacity))
        }
        .frame(width: box, height: box)
        .padding(.top, 6)
    }
}

private struct PluginProgressRing: View {
    @ObservedObject var job: PluginJob
    let size: CGFloat
    /// Zeiger darüber: In der Mitte steht, was ein Klick tut (Anhalten oder Fortsetzen)
    var hovering = false
    @State private var spinning = false

    var body: some View {
        let line = max(2.5, size * 0.07)
        ZStack {
            Circle()
                .stroke(Color.white.opacity(0.14), lineWidth: line)
            if !job.isStarted {
                // Wartet, bis ein anderes Plugin fertig ist: nur der stille Ring
            } else if let progress = job.progress {
                Circle()
                    .trim(from: 0, to: max(0.02, progress))
                    .stroke(Color.white.opacity(0.9), style: StrokeStyle(lineWidth: line, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.easeOut(duration: 0.25), value: progress)
            } else {
                Circle()
                    .trim(from: 0, to: 0.22)
                    .stroke(Color.white.opacity(0.9), style: StrokeStyle(lineWidth: line, lineCap: .round))
                    .rotationEffect(.degrees(spinning ? 270 : -90))
                    // Angehalten oder „Bewegung reduzieren“: steht still
                    .animation(job.paused || AnimationStyle.reduceMotion ? .default
                               : .linear(duration: 1.1).repeatForever(autoreverses: false), value: spinning)
            }
            Image(systemName: centerSymbol)
                .font(.system(size: size * 0.34, weight: .semibold))
                .foregroundStyle(.white.opacity(0.85))
                .contentTransition(.symbolEffect(.replace))
        }
        .frame(width: size, height: size)
        .animation(.easeOut(duration: 0.12), value: hovering)
        .onAppear { spinning = job.isStarted && !job.paused }
        .onChange(of: job.paused) { _, paused in spinning = job.isStarted && !paused }
        .onChange(of: job.isStarted) { _, started in spinning = started && !job.paused }
    }
}

private extension PluginProgressRing {
    var centerSymbol: String {
        if !job.isStarted { return "clock" }
        if hovering { return job.paused ? "play.fill" : "pause.fill" }
        if job.paused { return "pause.fill" }
        return job.plugin.manifest.icon?.resolvedSymbol ?? PluginIconView.fallbackSymbol
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
