import SwiftUI
import AppKit

// MARK: Einstellungen im Stil von Klack
//
// Eigene Bausteine statt des Systemformulars, damit das Fenster auf jeder
// macOS-Version gleich aussieht: graue Fläche, darauf Karten mit Zeilen und
// feinen Trennlinien, kurze Überschriften, längliche Schalter, schlichte
// Auswahlmenüs mit ⌃⌄. Maße und Farben sind von Klack abgenommen.

enum SettingsTheme {
    // Dunkel: Farben von Klack abgenommen. Hell: Systemfarben von macOS, damit Kontraste,
    // Flächen und Linien wie in Apples eigenen Fenstern wirken. Seitenleiste und Inhalt
    // liegen leicht durchscheinend über dem Schreibtisch, Karten sind deckend.
    /// Deckkraft von Seitenleiste und Inhalt über dem Schreibtisch (dunkel): etwas
    /// durchscheinender als früher (70 %), aber Text und Karten bleiben auf jedem Hintergrund ruhig
    static let backdropOpacity = 0.64
    /// Seitenleiste und Inhalt über dem Schreibtisch (Farben von Klack). Dunkel wie bisher zu 64 % deckend;
    /// hell wie bei Apple: Seitenleiste leicht durchscheinend, Inhalt fast deckend, damit
    /// ein dunkler Schreibtisch die helle Fläche nicht grau eintrübt
    /// Hell erst beim Zeichnen auflösen: `withAlphaComponent` auf einer Systemfarbe legt sie
    /// sonst auf das Aussehen beim Start fest, und im hellen Modus blieb der Hintergrund dunkel.
    static let sidebarBackdrop = dynamic(dark: rgb(0.161, 0.165, 0.169, backdropOpacity),
                                         light: systemColor(.windowBackgroundColor, alpha: 0.8))
    static let contentBackdrop = dynamic(dark: rgb(0.192, 0.196, 0.2, backdropOpacity),
                                         light: systemColor(.windowBackgroundColor, alpha: 0.96))
    /// Karten
    static let card = dynamic(dark: rgb(0.184, 0.188, 0.188), light: .controlBackgroundColor)
    /// Gewählter Eintrag der Seitenleiste
    static let selectedRow = dynamic(dark: rgb(0.212, 0.212, 0.216), light: .unemphasizedSelectedContentBackgroundColor)
    /// Rand der Karten
    static let cardBorder = dynamic(dark: rgb(0.255, 0.259, 0.263), light: .separatorColor)
    /// Trennlinien zwischen Zeilen, Leiste der Regler
    static let separator = dynamic(dark: rgb(0.267, 0.271, 0.271), light: .separatorColor)
    /// Senkrechte Linie zwischen Seitenleiste und Inhalt
    static let divider = dynamic(dark: rgb(0.247, 0.251, 0.255), light: .separatorColor)
    /// Ausgeschalteter Schalter, Mulde der Regler
    static let switchOff = dynamic(dark: rgb(0.255, 0.259, 0.259), light: .quaternaryLabelColor)
    /// Rasterpunkte unter den Reglern
    static let tick = dynamic(dark: rgb(0.388, 0.388, 0.392), light: .tertiaryLabelColor)

    // Bedienelemente (dunkel unverändert, hell mit Systemfarben)
    /// Knopf der Schalter und Regler: hell weiß wie bei macOS
    static let knob = dynamic(dark: rgb(0.9, 0.9, 0.9), light: .white)
    static let knobOn = dynamic(dark: rgb(0.86, 0.91, 0.99), light: .white)
    static let sliderKnob = dynamic(dark: rgb(0.92, 0.92, 0.92), light: .white)
    /// Mulde der Umschalter
    static let segmentTrough = dynamic(dark: NSColor.black.withAlphaComponent(0.18), light: .quaternaryLabelColor)
    /// Gewählte Möglichkeit eines Umschalters: hell weiß wie bei macOS
    static let segmentKnob = dynamic(dark: rgb(0.255, 0.259, 0.259), light: .controlColor)
    /// Graue Knöpfe hell: weiß mit feinem Rand wie macOS-Knöpfe (dunkel siehe KlackButtonStyle)
    static let buttonLight = Color(nsColor: .controlColor)
    static let buttonLightHover = Color(nsColor: rgb(0.96, 0.96, 0.96))
    static let buttonLightPressed = Color(nsColor: rgb(0.9, 0.9, 0.9))
    /// Rand der Knöpfe: nur hell (dunkel ohne Rand wie bisher)
    static let buttonBorder = dynamic(dark: .clear, light: .separatorColor)
    /// Tasten (Kurzbefehl, Tastenkürzel): dunkel eingelassen, hell als weiße Taste
    static let keyActive = dynamic(dark: NSColor.black.withAlphaComponent(0.42), light: .controlColor)
    static let keyInactive = dynamic(dark: NSColor.black.withAlphaComponent(0.24), light: .quaternaryLabelColor)
    static let keyHover = dynamic(dark: NSColor.black.withAlphaComponent(0.2),
                                  light: NSColor.black.withAlphaComponent(0.06))
    static let keyBorder = dynamic(dark: NSColor.white.withAlphaComponent(0.06), light: .separatorColor)
    static let keyBorderInactive = dynamic(dark: NSColor.white.withAlphaComponent(0.04), light: .clear)
    static let shortcutKey = dynamic(dark: NSColor.black.withAlphaComponent(0.22), light: NSColor.black.withAlphaComponent(0.05))
    /// Schatten der Knöpfe: nur hell, wie bei macOS
    static let controlShadow = dynamic(dark: .clear, light: NSColor.black.withAlphaComponent(0.12))

    static let rowHeight: CGFloat = 45
    static let cardRadius: CGFloat = 11
    static let rowPadding: CGFloat = 12

    private static func rgb(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) -> NSColor {
        NSColor(srgbRed: r, green: g, blue: b, alpha: a)
    }

    /// Systemfarbe mit eigener Deckkraft, im hellen Aussehen aufgelöst
    private static func systemColor(_ color: NSColor, alpha: CGFloat) -> NSColor {
        var resolved = color
        NSAppearance(named: .aqua)?.performAsCurrentDrawingAppearance {
            resolved = color.usingColorSpace(.sRGB) ?? color
        }
        return resolved.withAlphaComponent(alpha)
    }

    private static func dynamic(dark: NSColor, light: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        })
    }
}

/// Eine Seite der Einstellungen: senkrecht scrollend, Abschnitte untereinander.
struct SettingsPage<Content: View>: View {
    let content: Content
    init(@ViewBuilder content: () -> Content) { self.content = content() }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                content
            }
            .padding(.leading, 20)
            .padding(.trailing, 18)
            .padding(.top, 4)
            .padding(.bottom, 24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollIndicators(.automatic)
        // Nichts scrollt unter die Überschrift der Seite
        .modifier(HardTopEdge())
        .clipped()
    }
}

/// Ab macOS 26 blendet eine Bildlaufansicht ihren Inhalt oben weich aus und lässt ihn
/// unter die Titelleiste laufen. Hier gibt es eine eigene Überschrift: Kante ausblenden.
private struct HardTopEdge: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.scrollEdgeEffectHidden(true, for: .top)
        } else {
            content
        }
    }
}

/// Abschnitt: Überschrift (optional mit Info und Knöpfen), Karte, darunter ein Hinweis.
struct SettingsSection<Content: View, Trailing: View>: View {
    let title: String?
    var info: String?
    var note: String?
    var noteColor: Color = .secondary
    let trailing: () -> Trailing
    let content: Content

    init(_ title: String? = nil, info: String? = nil, note: String? = nil, noteColor: Color = .secondary,
         @ViewBuilder trailing: @escaping () -> Trailing,
         @ViewBuilder content: () -> Content) {
        self.title = title
        self.info = info
        self.note = note
        self.noteColor = noteColor
        self.trailing = trailing
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if title != nil || info != nil {
                SettingsHeader(title ?? "", info: info, trailing: trailing)
                    .padding(.horizontal, 8)
            }
            SettingsCard { content }
            if let note, !note.isEmpty {
                SectionNote(note, color: noteColor)
                    .padding(.horizontal, 8)
            }
        }
    }
}

extension SettingsSection where Trailing == EmptyView {
    init(_ title: String? = nil, info: String? = nil, note: String? = nil, noteColor: Color = .secondary,
         @ViewBuilder content: () -> Content) {
        self.init(title, info: info, note: note, noteColor: noteColor,
                  trailing: { EmptyView() }, content: content)
    }
}

/// Karte mit feinen Linien zwischen den Zeilen.
struct SettingsCard<Content: View>: View {
    let content: Content
    init(@ViewBuilder content: () -> Content) { self.content = content() }

    var body: some View {
        _VariadicView.Tree(DividedRows()) { content }
            .background(
                RoundedRectangle(cornerRadius: SettingsTheme.cardRadius, style: .continuous)
                    .fill(SettingsTheme.card)
            )
            .overlay(
                RoundedRectangle(cornerRadius: SettingsTheme.cardRadius, style: .continuous)
                    .strokeBorder(SettingsTheme.cardBorder, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: SettingsTheme.cardRadius, style: .continuous))
    }
}

/// Setzt zwischen die Zeilen einer Karte je eine feine Linie.
private struct DividedRows: _VariadicView_MultiViewRoot {
    func body(children: _VariadicView.Children) -> some View {
        let last = children.last?.id
        VStack(spacing: 0) {
            ForEach(children) { child in
                child
                if child.id != last {
                    Rectangle()
                        .fill(SettingsTheme.separator)
                        .frame(height: 1)
                }
            }
        }
    }
}

/// Zeile: Bezeichnung links (optional mit Info), Bedienelement rechts.
struct SettingsRow<Control: View>: View {
    let title: String
    var subtitle: String?
    var info: String?
    let control: Control

    init(_ title: String, subtitle: String? = nil, info: String? = nil, @ViewBuilder control: () -> Control) {
        self.title = title
        self.subtitle = subtitle
        self.info = info
        self.control = control()
    }

    var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: 6) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.system(size: 13.5))
                    if let subtitle {
                        Text(subtitle)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }
                if let info { InfoButton(info) }
            }
            Spacer(minLength: 8)
            control
        }
        .padding(.horizontal, SettingsTheme.rowPadding)
        .frame(minHeight: SettingsTheme.rowHeight)
    }
}

/// Zeile mit Schalter.
struct ToggleRow: View {
    let title: String
    var info: String?
    @Binding var isOn: Bool

    init(_ title: String, info: String? = nil, isOn: Binding<Bool>) {
        self.title = title
        self.info = info
        self._isOn = isOn
    }

    var body: some View {
        SettingsRow(title, info: info) {
            KlackSwitch(isOn: $isOn)
        }
        .contentShape(Rectangle())
    }
}

/// Länglicher Schalter wie bei Klack: 48 × 24, Knopf als Kapsel.
struct KlackSwitch: View {
    @Binding var isOn: Bool
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button {
            withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) { isOn.toggle() }
        } label: {
            ZStack(alignment: isOn ? .trailing : .leading) {
                Capsule()
                    .fill(isOn ? Color(nsColor: .controlAccentColor) : SettingsTheme.switchOff)
                Capsule()
                    .fill(isOn ? SettingsTheme.knobOn : SettingsTheme.knob)
                    .frame(width: 27, height: 18)
                    .shadow(color: .black.opacity(0.18), radius: 1, y: 0.5)
                    .padding(.horizontal, 3)
            }
            .frame(width: 48, height: 24)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .opacity(isEnabled ? 1 : 0.45)
        .accessibilityElement()
        .accessibilityAddTraits(.isButton)
        .accessibilityValue(isOn ? L("On", "Ein") : L("Off", "Aus"))
    }
}

/// Zeile mit Auswahl: aktueller Wert und ⌃⌄, ein Klick öffnet das Menü.
struct PickerRow<Value: Hashable>: View {
    let title: String
    var info: String?
    @Binding var selection: Value
    let options: [(Value, String)]
    /// Immer als Menü, auch bei zwei Möglichkeiten (lange Namen, die als Umschalter die
    /// Beschriftung der Zeile zusammendrücken würden)
    var menu = false

    init(_ title: String, info: String? = nil, selection: Binding<Value>, options: [(Value, String)],
         menu: Bool = false) {
        self.title = title
        self.info = info
        self._selection = selection
        self.options = options
        self.menu = menu
    }

    /// Wenige, kurze Möglichkeiten stehen direkt in der Zeile (wie ein Umschalter),
    /// längere Listen öffnen ein Menü. In beiden Sprachen gleich: Zwei Möglichkeiten sind
    /// immer ein Umschalter (vorher kippte z. B. „Reihenfolge“ nur auf Deutsch ins Menü,
    /// weil die deutschen Wörter länger sind); drei nur, wenn sie in beiden Sprachen kurz
    /// sind (Titel, Animation), sonst ein Menü.
    private var inline: Bool {
        if menu { return false }
        switch options.count {
        case 2: return true
        case 3: return options.reduce(0) { $0 + $1.1.count } <= 26
        default: return false
        }
    }

    var body: some View {
        SettingsRow(title, info: info) {
            if inline {
                SegmentedValue(selection: $selection, options: options)
            } else {
                PopupValue(selection: $selection, options: options)
            }
        }
    }
}

/// Umschalter mit wenigen Möglichkeiten: dunkle Mulde wie bei den Tasten, die gewählte
/// Möglichkeit als heller Knopf, der weich hinübergleitet; mit leichtem Impuls.
struct SegmentedValue<Value: Hashable>: View {
    @Binding var selection: Value
    let options: [(Value, String)]
    @Environment(\.isEnabled) private var isEnabled
    @Namespace private var knob

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Array(options.enumerated()), id: \.offset) { _, option in
                let selected = option.0 == selection
                Button {
                    guard !selected else { return }
                    // Kein eigener Impuls: Der Klick auf dem Trackpad ist schon einer,
                    // zusammen fühlte es sich doppelt an
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.82)) { selection = option.0 }
                } label: {
                    Text(option.1)
                        .font(.system(size: 12.5, weight: selected ? .semibold : .regular))
                        .foregroundStyle(selected ? Color.primary : Color.secondary)
                        .lineLimit(1)
                        .fixedSize()
                        .padding(.horizontal, 10)
                        .frame(height: 24)
                        .background {
                            if selected {
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .fill(SettingsTheme.segmentKnob)
                                    .shadow(color: .black.opacity(0.25), radius: 1.5, y: 1)
                                    .matchedGeometryEffect(id: "knob", in: knob)
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(SettingsTheme.segmentTrough)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(SettingsTheme.separator, lineWidth: 1)
        )
        .opacity(isEnabled ? 1 : 0.45)
    }
}

/// Auswahlmenü wie bei Klack: Wert und ⌃⌄ im Kreis. Das Menü öffnet sich immer
/// am Wert, der gewählte Eintrag liegt genau darüber (wie bei macOS üblich).
struct PopupValue<Value: Hashable>: View {
    @Binding var selection: Value
    let options: [(Value, String)]
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovering = false
    @State private var frame: CGRect = .zero

    private var current: String {
        options.first { $0.0 == selection }?.1 ?? ""
    }

    var body: some View {
        Button(action: showMenu) {
            HStack(spacing: 9) {
                Text(current)
                    .font(.system(size: 13.5))
                    .foregroundStyle(.primary)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 18, height: 18)
                    .background(Circle().fill(Color.primary.opacity(hovering && isEnabled ? 0.08 : 0.03)))
                    .overlay(Circle().strokeBorder(SettingsTheme.separator, lineWidth: 1))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(isEnabled ? 1 : 0.45)
        .onHover { hovering = $0 }
        .readFrame($frame)
    }

    private func showMenu() {
        let menu = NSMenu()
        var selectedItem: NSMenuItem?
        for (value, title) in options {
            let item = ClosureMenuItem(title) { selection = value }
            if value == selection {
                item.state = .on
                selectedItem = item
            }
            menu.addItem(item)
        }
        MenuPresenter.show(menu, over: frame, selected: selectedItem)
    }
}

/// Merkt sich die Lage einer Ansicht im Fenster (für Menüs, die daran ausgerichtet werden).
private struct FrameReader: ViewModifier {
    @Binding var frame: CGRect
    func body(content: Content) -> some View {
        content.background(
            GeometryReader { geo in
                Color.clear
                    .onAppear { frame = geo.frame(in: .global) }
                    .onChange(of: geo.frame(in: .global)) { _, new in frame = new }
            }
        )
    }
}

extension View {
    func readFrame(_ frame: Binding<CGRect>) -> some View { modifier(FrameReader(frame: frame)) }
}

/// Zeigt ein Menü an einer festen Stelle im Einstellungsfenster statt am Mauszeiger.
enum MenuPresenter {
    /// Auswahl unter dem Wert, rechtsbündig daran (die Werte stehen rechts in der Zeile)
    static func show(_ menu: NSMenu, over frame: CGRect, selected: NSMenuItem?) {
        ChoicePopup.present(menu, anchor: frame, align: .trailing)
    }

    /// Liste unter einem Knopf, linksbündig daran; bei zu wenig Platz nach oben
    static func show(_ menu: NSMenu, below frame: CGRect) {
        ChoicePopup.present(menu, anchor: frame, align: .leading)
    }
}

/// Regler wie bei Klack: Titel und Wert (in einer Kapsel) in einer Zeile,
/// darunter die Leiste mit Rasterpunkten.
struct SliderRow: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var step: Double = 0
    var format: (Double) -> String

    init(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, step: Double = 0,
         format: @escaping (Double) -> String) {
        self.title = title
        self._value = value
        self.range = range
        self.step = step
        self.format = format
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(title).font(.system(size: 13.5))
                Spacer()
                Text(format(value))
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.primary.opacity(0.03)))
                    .overlay(Capsule().strokeBorder(SettingsTheme.separator, lineWidth: 1))
            }
            KlackSlider(value: $value, range: range, step: step)
        }
        .padding(.horizontal, SettingsTheme.rowPadding)
        .padding(.top, 10)
        .padding(.bottom, 8)
    }

    static func percent(_ v: Double) -> String { Format.percent(Int((v * 100).rounded())) }
    static func points(_ v: Double) -> String { "\(Int(v.rounded())) pt" }
}

/// Leiste mit blauem Anteil, weißem Knopf und Rasterpunkten darunter. Rastet in
/// Schritten ein und gibt bei jedem Schritt einen leichten Impuls auf dem Trackpad.
struct KlackSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    var step: Double = 0
    @Environment(\.isEnabled) private var isEnabled

    private let knobWidth: CGFloat = 22
    private let knobHeight: CGFloat = 16
    private let track: CGFloat = 6
    /// Höchstens so viele Rasterpunkte, damit es nicht zu dicht wird
    private let maxTicks = 20

    /// Werte der Rasterpunkte: jeder Schritt, bei vielen Schritten jeder n-te
    private var tickFractions: [CGFloat] {
        let span = range.upperBound - range.lowerBound
        guard span > 0 else { return [] }
        let unit = step > 0 ? step : span / 10
        let count = Int((span / unit).rounded())
        guard count > 0 else { return [] }
        // Gleichmäßig verteilt wie bei macOS: bei vielen Schritten weniger Punkte, aber nie
        // ein zusätzlicher Punkt dicht am Ende (60 bis 200 in 4er-Schritten ergab zwei enge
        // Punkte rechts)
        let every = max(1, Int((Double(count) / Double(maxTicks)).rounded(.up)))
        let intervals = every == 1 ? count : max(1, Int((Double(count) / Double(every)).rounded()))
        return (0...intervals).map { CGFloat(Double($0) / Double(intervals)) }
    }

    var body: some View {
        GeometryReader { geo in
            let usable = max(1, geo.size.width - knobWidth)
            let fraction = CGFloat((value - range.lowerBound) / (range.upperBound - range.lowerBound))
            let x = usable * min(max(fraction, 0), 1)
            ZStack(alignment: .topLeading) {
                // Rasterpunkte
                ForEach(Array(tickFractions.enumerated()), id: \.offset) { _, f in
                    Circle()
                        .fill(SettingsTheme.tick)
                        .frame(width: 2.5, height: 2.5)
                        .offset(x: knobWidth / 2 + usable * f - 1.25, y: knobHeight + 5)
                }
                // Leiste und Anteil
                Capsule()
                    .fill(SettingsTheme.separator)
                    .frame(height: track)
                    .offset(y: (knobHeight - track) / 2)
                Capsule()
                    .fill(Color(nsColor: .controlAccentColor))
                    .frame(width: x + knobWidth / 2, height: track)
                    .offset(y: (knobHeight - track) / 2)
                // Knopf
                Capsule()
                    .fill(SettingsTheme.sliderKnob)
                    .frame(width: knobWidth, height: knobHeight)
                    .shadow(color: .black.opacity(0.35), radius: 1.5, y: 0.5)
                    .offset(x: x)
            }
            .frame(width: geo.size.width, height: knobHeight + 10, alignment: .topLeading)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { g in
                        let f = Double(min(max((g.location.x - knobWidth / 2) / usable, 0), 1))
                        set(range.lowerBound + f * (range.upperBound - range.lowerBound))
                    }
            )
        }
        .frame(height: knobHeight + 10)
        .opacity(isEnabled ? 1 : 0.45)
    }

    private func set(_ raw: Double) {
        // Mit Schritten: genau auf den sichtbaren Punkten einrasten, nie dazwischen
        let v: Double
        if step > 0 {
            let span = range.upperBound - range.lowerBound
            let stops = tickFractions.map { range.lowerBound + Double($0) * span }
            let nearest = stops.min(by: { abs($0 - raw) < abs($1 - raw) }) ?? raw
            v = (nearest / step).rounded() * step       // ohne Rundungsfehler speichern
        } else {
            v = raw
        }
        let clamped = min(max(v, range.lowerBound), range.upperBound)
        guard abs(clamped - value) > 1e-9 else { return }
        value = clamped
        // Jeder neue Schritt: ein leichter Impuls, wie beim Einrasten
        if step > 0 { Haptics.tap() }
    }
}

/// Grauer Knopf wie „Check Updates…“ bei Klack.
struct KlackButtonStyle: ButtonStyle {
    var prominent = false
    var destructive = false

    func makeBody(configuration: Configuration) -> some View {
        KlackButtonBody(configuration: configuration, prominent: prominent, destructive: destructive)
    }

    private struct KlackButtonBody: View {
        let configuration: ButtonStyleConfiguration
        let prominent: Bool
        let destructive: Bool
        @Environment(\.isEnabled) private var isEnabled
        @Environment(\.colorScheme) private var colorScheme
        @State private var hovering = false

        /// Dunkel wie bei Klack (unverändert), hell wie die Knöpfe von macOS
        private var background: Color {
            if colorScheme == .dark {
                return Color.primary.opacity(configuration.isPressed ? 0.2 : hovering ? 0.15 : 0.11)
            }
            return configuration.isPressed ? SettingsTheme.buttonLightPressed
                : hovering ? SettingsTheme.buttonLightHover : SettingsTheme.buttonLight
        }

        var body: some View {
            configuration.label
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(prominent ? Color.white : destructive ? Color.red : Color.primary)
                .padding(.horizontal, 12)
                .frame(height: 26)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(prominent ? Color(nsColor: .controlAccentColor) : background)
                        .shadow(color: prominent ? .clear : SettingsTheme.controlShadow, radius: 0.5, y: 0.5)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(prominent ? Color.clear : SettingsTheme.buttonBorder, lineWidth: 0.5)
                )
                .opacity(isEnabled ? (configuration.isPressed && prominent ? 0.85 : 1) : 0.45)
                .onHover { hovering = $0 }
        }
    }
}

/// Überschrift eines Abschnitts: Titel links, rechts optional Info und weitere Knöpfe.
struct SettingsHeader<Trailing: View>: View {
    let title: String
    var info: String?
    let trailing: () -> Trailing

    init(_ title: String, info: String? = nil, @ViewBuilder trailing: @escaping () -> Trailing) {
        self.title = title
        self.info = info
        self.trailing = trailing
    }

    var body: some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.system(size: 13.5, weight: .semibold))
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
            if let info { InfoButton(info) }
            trailing()
        }
    }
}

extension SettingsHeader where Trailing == EmptyView {
    init(_ title: String, info: String? = nil) {
        self.init(title, info: info) { EmptyView() }
    }
}

/// Kleines rundes Info-Symbol; ein Klick zeigt die Erklärung.
struct InfoButton: View {
    let text: String
    @State private var shown = false
    @State private var hovering = false

    init(_ text: String) { self.text = text }

    var body: some View {
        Button {
            shown.toggle()
        } label: {
            Image(systemName: "info.circle.fill")
                .font(.system(size: 13))
                .foregroundStyle(Color.secondary.opacity(hovering ? 0.95 : 0.6))
                .frame(width: 16, height: 16)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .popover(isPresented: $shown, arrowEdge: .bottom) {
            Text(text)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
                .frame(width: 280, alignment: .leading)
                .padding(12)
        }
        .accessibilityLabel("Info")
    }
}

/// Erklärtext unter einer Karte: immer linksbündig.
struct SectionNote: View {
    let text: String
    var color: Color = .secondary
    init(_ text: String, color: Color = .secondary) {
        self.text = text
        self.color = color
    }
    var body: some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundStyle(color)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Unschärfe des Schreibtischs hinter dem Fenster; darüber liegen die Farben
/// von Seitenleiste und Inhalt leicht durchscheinend.
struct SettingsBackdrop: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .underWindowBackground
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}
