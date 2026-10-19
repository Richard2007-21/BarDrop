import AppKit
import SwiftUI

/// Platzhalter für ein laufendes Plugin, direkt neben dem Original: ein schlichter Ring
/// mit dem Symbol des Plugins. Mit Fortschritt füllt er sich, ohne dreht ein kurzer Bogen.
/// Angehalten steht der Ring still und zeigt ein Pausenzeichen. Rechtsklick: Fortschritt,
/// Anhalten, Fortsetzen, Abbrechen.
struct PluginJobTile: View {
    @ObservedObject var job: PluginJob
    @ObservedObject var ui: ShelfUIModel
    @Environment(\.shelfDemo) private var shelfDemo
    let actions: ShelfActions
    var iconSize: CGFloat = 64

    var body: some View {
        TileLabel(title: job.label ?? job.title, isSelected: false, isKey: false, iconSize: iconSize) {
            PluginProgressRing(job: job, size: (iconSize * 0.62).rounded())
                .frame(width: iconSize, height: iconSize)
        }
        .opacity(job.paused ? 0.7 : 1)
        .overlay(Group { if !shelfDemo {
            PluginJobMenuArea(ui: ui) { actions.menu(for: job) }
        } })
        .help(job.percent.map { "\(job.title): " + Format.percent($0) } ?? job.title)
        .transition(.opacity)
    }
}

private struct PluginProgressRing: View {
    @ObservedObject var job: PluginJob
    let size: CGFloat
    @State private var spinning = false

    var body: some View {
        let line = max(2.5, size * 0.07)
        ZStack {
            Circle()
                .stroke(Color.white.opacity(0.14), lineWidth: line)
            if let progress = job.progress {
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
            Image(systemName: job.paused ? "pause.fill" : (job.plugin.manifest.icon?.resolvedSymbol ?? PluginIconView.fallbackSymbol))
                .font(.system(size: size * 0.34, weight: .semibold))
                .foregroundStyle(.white.opacity(0.85))
                .contentTransition(.symbolEffect(.replace))
        }
        .frame(width: size, height: size)
        .onAppear { spinning = !job.paused }
        .onChange(of: job.paused) { _, paused in spinning = !paused }
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
