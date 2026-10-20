import AppKit
import Carbon
import SwiftUI
import Combine

/// Bildschirmrand, an dem die Ablage sitzt.
enum ScreenEdge: String, CaseIterable, Identifiable {
    case left, right
    var id: String { rawValue }
    var title: String { self == .left ? L("Left", "Links") : L("Right", "Rechts") }
}

/// Wählbare Zeiträume für das automatische Entfernen (in Stunden).
enum AutoRemoveOption: Double, CaseIterable, Identifiable {
    case never = 0
    case h1 = 3_600
    case h2 = 7_200
    case h5 = 18_000
    case h10 = 36_000
    case h24 = 86_400

    var id: Double { rawValue }

    var title: String {
        switch self {
        case .never: return L("Never", "Nie")
        case .h1: return L("After 1 hour", "Nach 1 Stunde")
        default: return L("After \(Int(rawValue / 3_600)) hours", "Nach \(Int(rawValue / 3_600)) Stunden")
        }
    }
}

/// Stärke der Animationen beim Auf- und Zuklappen.
enum AnimationStyle: String, CaseIterable, Identifiable {
    case subtle, standard, lively
    var id: String { rawValue }

    var title: String {
        switch self {
        case .subtle: return L("Subtle", "Dezent")
        case .standard: return L("Standard", "Standard")
        case .lively: return L("Lively", "Lebhaft")
        }
    }

    /// Bedienungshilfen „Bewegung reduzieren“ (nach perch): dann ohne Federn,
    /// Unschärfe und Skalierung, nur kurzes Überblenden.
    static var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    /// Der Streifen wölbt sich elastisch aus dem Rand, mit einem kleinen Nachgeben
    /// (wie die Lautstärkeanzeige am iPhone), und sinkt ohne Nachschwingen zurück.
    var peekIn: Animation {
        if Self.reduceMotion { return .easeOut(duration: 0.15) }
        switch self {
        case .subtle: return .spring(response: 0.34, dampingFraction: 0.85)
        case .standard: return .spring(response: 0.38, dampingFraction: 0.72)
        case .lively: return .spring(response: 0.42, dampingFraction: 0.6)
        }
    }

    var peekOut: Animation {
        if Self.reduceMotion { return .easeIn(duration: 0.12) }
        return .spring(response: 0.28, dampingFraction: 1)
    }

    /// Feder beim Öffnen: je lebhafter, desto mehr Nachschwingen.
    var open: Animation {
        if Self.reduceMotion { return .easeOut(duration: 0.18) }
        switch self {
        case .subtle: return .spring(response: 0.34, dampingFraction: 0.95)
        case .standard: return .spring(response: 0.4, dampingFraction: 0.7)
        case .lively: return .spring(response: 0.46, dampingFraction: 0.55)
        }
    }

    var close: Animation {
        if Self.reduceMotion { return .easeIn(duration: 0.14) }
        switch self {
        case .subtle: return .spring(response: 0.26, dampingFraction: 1)
        case .standard: return .spring(response: 0.32, dampingFraction: 0.9)
        case .lively: return .spring(response: 0.36, dampingFraction: 0.82)
        }
    }

    /// Unschärfe beim Einblenden des Inhalts.
    var blur: CGFloat {
        if Self.reduceMotion { return 0 }
        switch self {
        case .subtle: return 6
        case .standard: return 14
        case .lively: return 18
        }
    }
}

/// Wie sich die Ablage öffnet, wenn man mit dem Zeiger an den Rand fährt.
enum OpenMode: String, CaseIterable, Identifiable {
    case automatic, click
    var id: String { rawValue }

    var title: String {
        switch self {
        case .automatic: return L("Automatically", "Automatisch")
        case .click: return L("On click", "Per Klick")
        }
    }
}

/// Eine Wahl unter „Öffnen“: nach einer Wartezeit oder nur per Klick.
enum OpenChoice: Hashable {
    case after(Double)
    case click

    static var all: [OpenChoice] { OpenDelay.choices.map { .after($0) } + [.click] }

    /// Ein Begriff und dahinter die Wartezeit, z. B. „Schnell (0,3 s)“
    var title: String {
        switch self {
        case .click: return L("Only on click", "Nur per Klick")
        case .after(let delay):
            if delay <= OpenDelay.immediate + 0.01 { return L("Instantly", "Sofort") }
            let seconds = OpenDelay.format(delay)
            switch delay {
            case ..<0.5: return L("Quick (\(seconds))", "Schnell (\(seconds))")
            case ..<1.5: return L("Short (\(seconds))", "Kurz (\(seconds))")
            case ..<2.5: return L("Medium (\(seconds))", "Mittel (\(seconds))")
            case ..<3.5: return L("Long (\(seconds))", "Lang (\(seconds))")
            case ..<4.5: return L("Longer (\(seconds))", "Länger (\(seconds))")
            default: return L("Very long (\(seconds))", "Sehr lang (\(seconds))")
            }
        }
    }
}

/// Verzögerung, bis die Ablage nach dem ersten Streifen ganz aufgeht.
enum OpenDelay {
    /// Ohne Wartezeit: Die Ablage geht auf, sobald der Zeiger den Rand erreicht, ohne
    /// erst den Streifen zu zeigen
    static let immediate = 0.0
    /// Standard: ein kurzer Moment am Streifen, damit sie nicht aus Versehen aufgeht
    static let quick = 0.3
    /// Alle bisherigen Wartezeiten bleiben wählbar: Eigene Einstellungen werden nie überschrieben
    static let choices: [Double] = [immediate, quick, 1, 2, 3, 4, 5]

    /// „0,3 s“ bzw. „0.3 s“, ganze Sekunden ohne Nachkomma
    static func format(_ delay: Double) -> String {
        let whole = abs(delay - delay.rounded()) < 0.01
        let number = whole ? "\(Int(delay.rounded()))" : String(format: "%.1f", delay)
        return L(number, number.replacingOccurrences(of: ".", with: ",")) + " s"
    }
}

/// Wann die Ablage beim Ziehen von Objekten erscheint.
enum DragReveal: String, CaseIterable, Identifiable {
    case immediately, nearEdge, off
    var id: String { rawValue }

    /// Wählbar: „Nie“ (`off`) nicht mehr, Ablegen ist die Hauptsache. Ältere gespeicherte
    /// Werte werden beim Start zu „Erst in Randnähe“.
    static var selectable: [DragReveal] { [.immediately, .nearEdge] }

    var title: String {
        switch self {
        case .immediately: return L("Show strip right away", "Streifen sofort zeigen")
        case .nearEdge: return L("Only near the edge", "Erst in Randnähe")
        case .off: return L("Never", "Nie")
        }
    }
}

/// Titel oben in der offenen Ablage. Nicht mehr wählbar (immer „BarDrop“); der gespeicherte
/// Wert bleibt lesbar, damit ältere Einstellungen nicht verloren gehen.
enum ShelfTitle: String, CaseIterable, Identifiable {
    case bardrop, shelf, hidden
    var id: String { rawValue }
}

/// Reihenfolge der Objekte in der Ablage.
enum SortOrder: String, CaseIterable, Identifiable {
    case newestFirst, oldestFirst
    var id: String { rawValue }

    var title: String {
        switch self {
        case .newestFirst: return L("Newest first", "Neueste zuerst")
        case .oldestFirst: return L("Oldest first", "Älteste zuerst")
        }
    }
}

/// Auf welchen Bildschirmen BarDrop verfügbar ist.
enum DisplayMode: String, CaseIterable, Identifiable {
    case all, builtIn, external
    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: return L("All displays", "Alle Bildschirme")
        case .builtIn: return L("Built-in display only", "Nur integrierter Bildschirm")
        case .external: return L("External displays only", "Nur externe Bildschirme")
        }
    }

    func allows(_ screen: NSScreen) -> Bool {
        switch self {
        case .all: return true
        case .builtIn: return screen.isBuiltIn
        case .external: return !screen.isBuiltIn
        }
    }
}

extension NSScreen {
    /// Feste Kennung des Bildschirms (bleibt gleich, auch wenn macOS das Objekt neu anlegt)
    var displayID: CGDirectDisplayID? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber).map { CGDirectDisplayID($0.uint32Value) }
    }

    var isBuiltIn: Bool {
        guard let number = deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return false }
        return CGDisplayIsBuiltin(CGDirectDisplayID(number.uint32Value)) != 0
    }
}

/// Form des ersten Streifens: flach, lang und dicht am Rand.
enum PeekDefaults {
    static let thickness = 7.0
    static let length = 80.0
    static let roundness = 0.65
}

/// Standardwerte für Lage und Größe der Ablage.
enum ShelfDefaults {
    static let edge = ScreenEdge.right
    static let verticalPosition = 0.5
    static let adaptivePosition = true
    static let adaptiveMiddleThird = true
    static let adaptiveZoneHalf = true
    static let displayMode = DisplayMode.all
    static let width = 240.0
    static let height = 340.0
    static let iconSize = 64.0
    static let actionIconSize = 34.0
}

/// Persistente Einstellungen der App (UserDefaults).
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    private let defaults = UserDefaults.standard

    private enum Key {
        static let edge = "edge"
        static let verticalPosition = "verticalPosition"
        static let adaptivePosition = "adaptivePosition"
        static let adaptiveMiddleThird = "adaptiveMiddleThird"
        static let displayMode = "displayMode"
        static let shelfWidth = "shelfWidth"
        static let shelfHeight = "shelfHeight"
        static let showOnDrag = "showOnDrag"
        static let dragReveal = "dragReveal"
        static let peekThickness = "peekThickness"
        static let peekLength = "peekLength"
        static let peekRoundness = "peekRoundness"
        static let removeAfterDragOut = "removeAfterDragOut"
        static let stackMultiple = "stackMultiple"
        static let stackThreshold = "stackThreshold"
        static let adaptiveZoneHalf = "adaptiveZoneHalf"
        /// Anteil des Rands, in dem die Ablage am Zeiger erscheint (0,1 bis 1 = ganzer Rand)
        static let adaptiveZone = "adaptiveZone"
        static let keepAfterAction = "keepAfterAction"
        static let animationStyle = "animationStyle"
        static let openMode = "openMode"
        static let autoRemoveAfter = "autoRemoveAfter"
        static let convertWebImages = "convertWebImages"
        static let copyAllFiles = "copyAllFiles"
        static let dragOutCopyOnly = "dragOutCopyOnly"
        static let hapticsEnabled = "hapticsEnabled"
        static let quickActions = "quickActions"
        static let sortOrder = "sortOrder"
        static let showOutline = "showOutline"
        static let showTitle = "showTitle"
        static let titleStyle = "titleStyle"
        static let openDelay = "openDelay"
        static let language = "language"
        static let generousHitArea = "generousHitArea"
        static let reopenWhereLeft = "reopenWhereLeft"
        static let exactPointer = "exactPointer"
        static let diagnosticsEnabled = "diagnosticsEnabled"
        static let twoActionRows = "twoActionRows"
        static let actionRowSplit = "actionRowSplit"
        static let pinFromShelf = "pinFromShelf"
        static let addScreenshots = "addScreenshots"
        static let excludedApps = "excludedApps"
        static let openInFullScreen = "openInFullScreen"
        static let showActionLabels = "showActionLabels"
        static let labelsOnlyFolders = "labelsOnlyFolders"
        static let betaUpdates = "betaUpdates"
        static let tileIconSize = "tileIconSize"
        static let actionIconSize = "actionIconSize"
        static let autoUpdateCheck = "autoUpdateCheck"
        static let hotKeyCode = "hotKeyCode"
        static let hotKeyModifiers = "hotKeyModifiers"
        static let hotKeyLabel = "hotKeyLabel"
        static let didLaunchBefore = "didLaunchBefore"
        static let pluginsEnabled = "pluginsEnabled"
        static let pluginLogEnabled = "pluginLogEnabled"
    }

    // Lage und Größe
    @Published var edge: ScreenEdge { didSet { defaults.set(edge.rawValue, forKey: Key.edge) } }
    /// 0 = unten, 1 = oben
    @Published var verticalPosition: Double { didSet { defaults.set(verticalPosition, forKey: Key.verticalPosition) } }
    /// Ablage erscheint dort, wo der Zeiger den Rand erreicht, statt an fester Höhe.
    @Published var adaptivePosition: Bool { didSet { defaults.set(adaptivePosition, forKey: Key.adaptivePosition) } }
    /// Adaptive Höhe nur im mittleren Drittel des Bildschirmrands.
    @Published var adaptiveMiddleThird: Bool { didSet { defaults.set(adaptiveMiddleThird, forKey: Key.adaptiveMiddleThird) } }
    /// Eingeschränkter Bereich: mittlere Hälfte statt mittleres Drittel.
    @Published var adaptiveZoneHalf: Bool { didSet { defaults.set(adaptiveZoneHalf, forKey: Key.adaptiveZoneHalf) } }

    /// „Am Zeiger“: Wie viel vom Rand reagiert, mittig, von 10 % bis zum ganzen Rand (1).
    /// Ersetzt „nur mittlere Hälfte“ (früher `adaptiveMiddleThird` und `adaptiveZoneHalf`).
    @Published var adaptiveZone: Double { didSet { defaults.set(adaptiveZone, forKey: Key.adaptiveZone) } }
    static let adaptiveZoneRange: ClosedRange<Double> = 0.1...1
    /// Standard für alle, die den Bereich nie eingestellt haben: die mittlere Hälfte
    static let defaultAdaptiveZone = 0.5

    /// Anteil der Randhöhe, in dem die adaptive Ablage reagiert (mittig); nil = ganzer Rand.
    var adaptiveZoneFraction: CGFloat? {
        guard adaptivePosition, adaptiveZone < 0.999 else { return nil }
        return CGFloat(adaptiveZone)
    }
    @Published var displayMode: DisplayMode { didSet { defaults.set(displayMode.rawValue, forKey: Key.displayMode) } }
    @Published var shelfWidth: Double { didSet { defaults.set(shelfWidth, forKey: Key.shelfWidth) } }
    @Published var shelfHeight: Double { didSet { defaults.set(shelfHeight, forKey: Key.shelfHeight) } }

    // Verhalten
    /// Beim Ziehen: sofort einen Streifen zeigen, erst in Randnähe oder gar nicht.
    @Published var dragReveal: DragReveal { didSet { defaults.set(dragReveal.rawValue, forKey: Key.dragReveal) } }
    /// Form des ersten Streifens am Rand
    @Published var peekThickness: Double { didSet { defaults.set(peekThickness, forKey: Key.peekThickness) } }
    @Published var peekLength: Double { didSet { defaults.set(peekLength, forKey: Key.peekLength) } }
    /// 0 = eckig, 1 = ganz rund
    @Published var peekRoundness: Double { didSet { defaults.set(peekRoundness, forKey: Key.peekRoundness) } }
    @Published var hapticsEnabled: Bool { didSet { defaults.set(hapticsEnabled, forKey: Key.hapticsEnabled) } }
    @Published var animationStyle: AnimationStyle { didSet { defaults.set(animationStyle.rawValue, forKey: Key.animationStyle) } }
    /// Automatisch ganz öffnen oder erst nach einem Klick auf die mittlere Stufe.
    @Published var openMode: OpenMode { didSet { defaults.set(openMode.rawValue, forKey: Key.openMode) } }

    // Objekte
    @Published var removeAfterDragOut: Bool { didSet { defaults.set(removeAfterDragOut, forKey: Key.removeAfterDragOut) } }
    /// Mehrere gleichzeitig abgelegte Objekte zu einem Stapel zusammenfassen.
    @Published var stackMultiple: Bool { didSet { defaults.set(stackMultiple, forKey: Key.stackMultiple) } }
    /// Ab so vielen gleichzeitig abgelegten Objekten entsteht ein Stapel.
    @Published var stackThreshold: Int { didSet { defaults.set(stackThreshold, forKey: Key.stackThreshold) } }
    /// Objekte nach einer Schnellaktion (AirDrop, Mail, Ordner …) in der Ablage behalten.
    @Published var keepAfterAction: Bool { didSet { defaults.set(keepAfterAction, forKey: Key.keepAfterAction) } }
    /// Objekte nach dieser Zeit (Sekunden) automatisch entfernen; 0 = nie.
    @Published var autoRemoveAfter: Double { didSet { defaults.set(autoRemoveAfter, forKey: Key.autoRemoveAfter) } }
    /// Auch eigene Dateien als Kopie ablegen, unabhängig vom Original.
    @Published var copyAllFiles: Bool { didSet { defaults.set(copyAllFiles, forKey: Key.copyAllFiles) } }
    /// Bilder aus dem Web (WebP, AVIF, HEIC …) in PNG/JPEG umwandeln.
    @Published var convertWebImages: Bool { didSet { defaults.set(convertWebImages, forKey: Key.convertWebImages) } }
    /// Beim Herausziehen nur Kopieren anbieten (sonst dürfen Ziele wie der Finder auch verschieben).
    @Published var dragOutCopyOnly: Bool { didSet { defaults.set(dragOutCopyOnly, forKey: Key.dragOutCopyOnly) } }
    /// Globaler Kurzbefehl (virtueller Tastencode und Carbon-Sondertasten).
    @Published var hotKeyCode: Int { didSet { defaults.set(hotKeyCode, forKey: Key.hotKeyCode) } }
    @Published var hotKeyModifiers: Int { didSet { defaults.set(hotKeyModifiers, forKey: Key.hotKeyModifiers) } }
    @Published var hotKeyLabel: String { didSet { defaults.set(hotKeyLabel, forKey: Key.hotKeyLabel) } }

    static let defaultHotKey = (code: kVK_ANSI_B, modifiers: controlKey | optionKey, label: "B")

    func resetHotKey() {
        hotKeyCode = Self.defaultHotKey.code
        hotKeyModifiers = Self.defaultHotKey.modifiers
        hotKeyLabel = Self.defaultHotKey.label
    }

    /// Kurzbefehl als Text, z. B. „⌃⌥B“.
    var hotKeyDescription: String {
        var s = ""
        if hotKeyModifiers & controlKey != 0 { s += "⌃" }
        if hotKeyModifiers & optionKey != 0 { s += "⌥" }
        if hotKeyModifiers & shiftKey != 0 { s += "⇧" }
        if hotKeyModifiers & cmdKey != 0 { s += "⌘" }
        return s + hotKeyLabel
    }

    /// Neue Versionen still im Hintergrund installieren (sucht dafür regelmäßig auf GitHub).
    @Published var autoUpdateCheck: Bool { didSet { defaults.set(autoUpdateCheck, forKey: Key.autoUpdateCheck) } }
    /// Feiner heller Rahmen um die schwarze Form (sichtbar auf dunklem Hintergrund).
    @Published var showOutline: Bool { didSet { defaults.set(showOutline, forKey: Key.showOutline) } }
    /// Titel oben in der offenen Ablage: „BarDrop“, „Ablage“ oder keiner
    @Published var titleStyle: ShelfTitle { didSet { defaults.set(titleStyle.rawValue, forKey: Key.titleStyle) } }
    /// So lange (Sekunden) muss der Zeiger am Streifen bleiben, bis die Ablage aufgeht.
    @Published var openDelay: Double { didSet { defaults.set(openDelay, forKey: Key.openDelay) } }

    /// Sprache der Oberfläche
    @Published var language: AppLanguage {
        didSet {
            AppLanguage.current = language.resolved
            defaults.set(language.rawValue, forKey: Key.language)
        }
    }
    /// Etwas größerer Bereich um Streifen und Griff, in dem der Zeiger noch zählt.
    /// Seit 1.30.0 Beta 15 immer an, nicht mehr einstellbar.
    var generousHitArea: Bool { true }
    /// Mit dem Zeiger allein öffnet nur der Streifen selbst (beim Ziehen von Dateien bleibt
    /// der Bereich großzügig)
    @Published var exactPointer: Bool { didSet { defaults.set(exactPointer, forKey: Key.exactPointer) } }
    /// Ausführliches, anonymes Diagnoseprotokoll (nur Beta-Versionen, standardmäßig aus)
    @Published var diagnosticsEnabled: Bool { didSet { defaults.set(diagnosticsEnabled, forKey: Key.diagnosticsEnabled) } }
    /// Beim Öffnen dort weitermachen, wo man aufgehört hat: offener Stapel und Scrollstand bleiben
    @Published var reopenWhereLeft: Bool { didSet { defaults.set(reopenWhereLeft, forKey: Key.reopenWhereLeft) } }
    /// Aktionsleiste in zwei Reihen mit je bis zu fünf Aktionen
    @Published var twoActionRows: Bool { didSet { defaults.set(twoActionRows, forKey: Key.twoActionRows) } }
    /// Zwei Reihen: so viele Aktionen (vorne in `quickActions`) stehen in der oberen Reihe
    @Published var actionRowSplit: Int { didSet { defaults.set(actionRowSplit, forKey: Key.actionRowSplit) } }
    /// Ordner und Apps auf die Aktionsleiste der Ablage ziehen heftet sie an,
    /// eine Aktion aus der Ablage herausziehen entfernt sie
    @Published var pinFromShelf: Bool { didSet { defaults.set(pinFromShelf, forKey: Key.pinFromShelf) } }
    /// Neue Bildschirmfotos landen automatisch in der Ablage
    @Published var addScreenshots: Bool { didSet { defaults.set(addScreenshots, forKey: Key.addScreenshots) } }
    /// Apps (Bundle-IDs), in denen der Rand die Ablage nicht öffnet, solange sie vorn sind
    @Published var excludedApps: [String] { didSet { defaults.set(excludedApps, forKey: Key.excludedApps) } }
    /// Der Rand öffnet die Ablage auch, wenn die App vorn im Vollbild ist
    @Published var openInFullScreen: Bool { didSet { defaults.set(openInFullScreen, forKey: Key.openInFullScreen) } }
    /// Namen unter den Aktionen in der Ablage
    @Published var showActionLabels: Bool { didSet { defaults.set(showActionLabels, forKey: Key.showActionLabels) } }
    /// Mit Namen: nur Ordner bekommen einen Namen (AirDrop, Papierkorb & Co. erkennt man am Symbol)
    @Published var labelsOnlyFolders: Bool { didSet { defaults.set(labelsOnlyFolders, forKey: Key.labelsOnlyFolders) } }
    /// Auch Beta-Versionen installieren (Vorabversionen auf GitHub)
    @Published var betaUpdates: Bool { didSet { defaults.set(betaUpdates, forKey: Key.betaUpdates) } }
    /// Größe der Symbole und Vorschauen in der Ablage (pt)
    @Published var tileIconSize: Double { didSet { defaults.set(tileIconSize, forKey: Key.tileIconSize) } }
    /// Plugins verwenden (Einstellungen → Plugins). Standardmäßig aus; erst beim
    /// Einschalten lädt BarDrop die Standard-Plugins aus dem Katalog.
    @Published var pluginsEnabled: Bool { didSet { defaults.set(pluginsEnabled, forKey: Key.pluginsEnabled) } }
    /// Eigenes Protokoll der Plugins führen (getrennt vom Diagnoseprotokoll)
    @Published var pluginLogEnabled: Bool {
        didSet {
            defaults.set(pluginLogEnabled, forKey: Key.pluginLogEnabled)
            PluginLog.shared.isEnabled = pluginLogEnabled
        }
    }
    /// Größe der Symbole in der Aktionsleiste (pt); ohne Namen kommen 10 pt dazu
    @Published var actionIconSize: Double { didSet { defaults.set(actionIconSize, forKey: Key.actionIconSize) } }

    /// Grenze zwischen oberer und unterer Reihe, so begrenzt, dass keine Reihe mehr als
    /// fünf Aktionen hat.
    var effectiveActionSplit: Int {
        Self.clampSplit(actionRowSplit, count: quickActions.count)
    }

    static func clampSplit(_ split: Int, count: Int) -> Int {
        let per = QuickAction.perRow
        return min(max(split, max(0, count - per)), min(per, count))
    }

    /// Lässt sich dieser Ordner bzw. diese App gerade in der Ablage anheften?
    func canPin(_ url: URL) -> Bool {
        pinFromShelf
            && quickActions.count < QuickAction.limit(twoRows: twoActionRows)
            && QuickAction.pinnableKind(url) != nil
            && !quickActions.contains { $0.path == url.path }
    }

    /// Ordner oder App hinten an die Aktionsleiste anheften
    @discardableResult
    func pin(_ url: URL) -> Bool {
        guard canPin(url), let kind = QuickAction.pinnableKind(url) else { return false }
        quickActions.append(QuickAction(kind: kind, path: url.path))
        return true
    }

    /// Aktion entfernen; aus der oberen Reihe rückt die Grenze mit, die untere bleibt
    func removeQuickAction(_ id: QuickAction.ID) {
        guard let index = quickActions.firstIndex(where: { $0.id == id }) else { return }
        let split = effectiveActionSplit
        quickActions.remove(at: index)
        if index < split { actionRowSplit = split - 1 }
    }

    /// Ab dieser Verzögerung lässt sich das Öffnen per Klick abkürzen.
    static let clickToOpenMinDelay = 1.0

    /// Nimmt der Streifen bzw. Griff gerade einen Klick zum Öffnen an?
    /// Mit Wartezeit öffnet ein Klick immer sofort.
    var hintAcceptsClick: Bool {
        openMode == .click || openDelay >= Self.clickToOpenMinDelay - 0.01
    }

    /// „Öffnen“ in einer Auswahl: Wartezeit in Sekunden oder nur per Klick
    var openChoice: OpenChoice {
        get { openMode == .click ? .click : .after(openDelay) }
        set {
            switch newValue {
            case .click:
                openMode = .click
            case .after(let delay):
                openDelay = delay
                openMode = .automatic
            }
        }
    }
    /// Reihenfolge der Objekte in der Ablage.
    @Published var sortOrder: SortOrder { didSet { defaults.set(sortOrder.rawValue, forKey: Key.sortOrder) } }

    /// Aktionen in der Leiste unten, in der gewünschten Reihenfolge.
    @Published var quickActions: [QuickAction] {
        didSet {
            if let data = try? JSONEncoder().encode(quickActions) {
                defaults.set(data, forKey: Key.quickActions)
            }
        }
    }

    var didLaunchBefore: Bool {
        get { defaults.bool(forKey: Key.didLaunchBefore) }
        set { defaults.set(newValue, forKey: Key.didLaunchBefore) }
    }

    private init() {
        defaults.register(defaults: [
            Key.edge: ShelfDefaults.edge.rawValue,
            Key.verticalPosition: ShelfDefaults.verticalPosition,
            Key.adaptivePosition: ShelfDefaults.adaptivePosition,
            Key.adaptiveMiddleThird: ShelfDefaults.adaptiveMiddleThird,
            Key.adaptiveZoneHalf: ShelfDefaults.adaptiveZoneHalf,
            Key.displayMode: ShelfDefaults.displayMode.rawValue,
            Key.shelfWidth: ShelfDefaults.width,
            Key.shelfHeight: ShelfDefaults.height,
            Key.showOnDrag: true,
            Key.peekThickness: PeekDefaults.thickness,
            Key.peekLength: PeekDefaults.length,
            Key.peekRoundness: PeekDefaults.roundness,
            Key.hapticsEnabled: true,
            Key.removeAfterDragOut: true,
            Key.stackMultiple: true,
            Key.stackThreshold: 2,
            // Standard „Nach dem Herausziehen entfernen“: Nach Aktionen bleibt das Objekt
            Key.keepAfterAction: true,
            Key.animationStyle: AnimationStyle.standard.rawValue,
            Key.openMode: OpenMode.automatic.rawValue,
            Key.autoRemoveAfter: AutoRemoveOption.never.rawValue,
            Key.convertWebImages: true,
            Key.copyAllFiles: false,
            Key.dragOutCopyOnly: false,
            Key.sortOrder: SortOrder.newestFirst.rawValue,
            Key.showOutline: true,
            Key.showTitle: true,
            Key.openDelay: OpenDelay.quick,
            Key.language: AppLanguage.system.rawValue,
            Key.reopenWhereLeft: false,
            Key.exactPointer: false,
            Key.diagnosticsEnabled: false,
            Key.twoActionRows: false,
            Key.pinFromShelf: true,
            Key.addScreenshots: false,
            Key.openInFullScreen: false,
            Key.showActionLabels: true,
            Key.labelsOnlyFolders: false,
            Key.betaUpdates: false,
            Key.tileIconSize: ShelfDefaults.iconSize,
            Key.actionIconSize: ShelfDefaults.actionIconSize,
            // Alle Aktionen standardmäßig in der unteren Reihe
            Key.actionRowSplit: 0,
            Key.autoUpdateCheck: true,
            Key.pluginsEnabled: false,
            Key.pluginLogEnabled: false,
            Key.hotKeyCode: Self.defaultHotKey.code,
            Key.hotKeyModifiers: Self.defaultHotKey.modifiers,
            Key.hotKeyLabel: Self.defaultHotKey.label
        ])
        edge = ScreenEdge(rawValue: defaults.string(forKey: Key.edge) ?? "") ?? ShelfDefaults.edge
        verticalPosition = defaults.double(forKey: Key.verticalPosition)
        adaptivePosition = defaults.bool(forKey: Key.adaptivePosition)
        adaptiveMiddleThird = defaults.bool(forKey: Key.adaptiveMiddleThird)
        // „Am Zeiger, nur mittleres Drittel“ gibt es nicht mehr: wird zur mittleren Hälfte
        if defaults.object(forKey: Key.adaptiveZoneHalf) as? Bool == false {
            defaults.removeObject(forKey: Key.adaptiveZoneHalf)
        }
        adaptiveZoneHalf = defaults.bool(forKey: Key.adaptiveZoneHalf)
        // Bereich am Zeiger: eigener Wert, sonst wie bisher eingestellt (mittlere Hälfte
        // bzw. ganzer Rand). Bewusst nicht registriert, damit sich „nie gesetzt“ erkennen lässt
        if let stored = defaults.object(forKey: Key.adaptiveZone) as? Double {
            adaptiveZone = min(max(stored, Self.adaptiveZoneRange.lowerBound), Self.adaptiveZoneRange.upperBound)
        } else {
            adaptiveZone = adaptiveMiddleThird ? Self.defaultAdaptiveZone : 1
        }
        displayMode = DisplayMode(rawValue: defaults.string(forKey: Key.displayMode) ?? "") ?? ShelfDefaults.displayMode
        shelfWidth = defaults.double(forKey: Key.shelfWidth)
        shelfHeight = defaults.double(forKey: Key.shelfHeight)
        // Ältere Versionen hatten nur „Beim Ziehen einblenden“ an/aus
        // „Nie“ gibt es nicht mehr (Ablegen ist die Hauptsache): wird zu „Erst in Randnähe“
        let storedReveal = DragReveal(rawValue: defaults.string(forKey: Key.dragReveal) ?? "")
            ?? (defaults.bool(forKey: Key.showOnDrag) ? .immediately : .nearEdge)
        dragReveal = storedReveal == .off ? .nearEdge : storedReveal
        // Ab 1.8 ist der Streifen flacher: alte Standardwerte (16 / 84 / 0,62) einmalig übernehmen,
        // selbst gewählte Werte bleiben
        if defaults.object(forKey: Key.peekThickness) as? Double == 16,
           defaults.object(forKey: Key.peekLength) as? Double ?? 84 == 84 {
            defaults.removeObject(forKey: Key.peekThickness)
            defaults.removeObject(forKey: Key.peekLength)
            defaults.removeObject(forKey: Key.peekRoundness)
        }
        // 1.9: „Übergang“ ersetzt „Enden“ mit anderer Bedeutung; einmalig auf Standard
        if !defaults.bool(forKey: "peekShapeV19") {
            defaults.removeObject(forKey: Key.peekRoundness)
            defaults.set(true, forKey: "peekShapeV19")
        }
        peekThickness = defaults.double(forKey: Key.peekThickness)
        peekLength = defaults.double(forKey: Key.peekLength)
        // „Rundung zum Rand“ ist nicht mehr einstellbar: immer der Standard (die Ecken
        // bleiben bei jeder Dicke und Länge ohne Knick, siehe ShelfMetrics.peek)
        peekRoundness = PeekDefaults.roundness
        hapticsEnabled = defaults.bool(forKey: Key.hapticsEnabled)
        removeAfterDragOut = defaults.bool(forKey: Key.removeAfterDragOut)
        stackMultiple = defaults.bool(forKey: Key.stackMultiple)
        stackThreshold = min(max(defaults.integer(forKey: Key.stackThreshold), 2), 10)
        keepAfterAction = defaults.bool(forKey: Key.keepAfterAction)
        // „Nach Aktionen entfernen“ gibt es nicht mehr: Wer es gewählt hatte (Herausgezogenes
        // bleibt), bekommt die nächste Wahl, „In der Ablage behalten“
        if !removeAfterDragOut && !keepAfterAction { keepAfterAction = true }
        animationStyle = AnimationStyle(rawValue: defaults.string(forKey: Key.animationStyle) ?? "") ?? .standard
        openMode = OpenMode(rawValue: defaults.string(forKey: Key.openMode) ?? "") ?? .automatic
        convertWebImages = defaults.bool(forKey: Key.convertWebImages)
        copyAllFiles = defaults.bool(forKey: Key.copyAllFiles)
        dragOutCopyOnly = defaults.bool(forKey: Key.dragOutCopyOnly)
        // 1.25 hatte „ohne Rahmen“ als Standard. Wer BarDrop schon benutzt und den Rahmen
        // nie selbst umgestellt hat, behält den Zustand, den er gerade sieht; neue
        // Installationen beginnen mit Rahmen.
        // (object(forKey:) sähe auch den registrierten Standard, deshalb im eigenen Bereich nachsehen)
        let store = UserDefaults.standard
        let ownValues = Bundle.main.bundleIdentifier.flatMap { store.persistentDomain(forName: $0) } ?? [:]
        if ownValues[Key.showOutline] == nil, store.bool(forKey: Key.didLaunchBefore) {
            store.set(false, forKey: Key.showOutline)
        }
        showOutline = defaults.bool(forKey: Key.showOutline)
        // Bis 1.30.0 Beta 13 nur „BarDrop“ oder „Ablage“ (showTitle): einmalig übernehmen
        titleStyle = ShelfTitle(rawValue: defaults.string(forKey: Key.titleStyle) ?? "")
            ?? (defaults.bool(forKey: Key.showTitle) ? .bardrop : .shelf)
        // Auf eine der wählbaren Wartezeiten runden (ältere Versionen hatten andere)
        let storedDelay = defaults.double(forKey: Key.openDelay)
        openDelay = OpenDelay.choices.min { abs($0 - storedDelay) < abs($1 - storedDelay) } ?? OpenDelay.quick
        let storedLanguage = AppLanguage(rawValue: defaults.string(forKey: Key.language) ?? "") ?? .system
        language = storedLanguage
        AppLanguage.current = storedLanguage.resolved
        // „Größerer Trefferbereich“ ist immer an: alten Wert aufräumen
        defaults.removeObject(forKey: Key.generousHitArea)
        reopenWhereLeft = defaults.bool(forKey: Key.reopenWhereLeft)
        exactPointer = defaults.bool(forKey: Key.exactPointer)
        diagnosticsEnabled = defaults.bool(forKey: Key.diagnosticsEnabled)
        // Zwei Reihen gibt es immer: Eine leere untere Reihe ist einfach nicht zu sehen
        twoActionRows = true
        actionRowSplit = defaults.integer(forKey: Key.actionRowSplit)
        pinFromShelf = defaults.bool(forKey: Key.pinFromShelf)
        addScreenshots = defaults.bool(forKey: Key.addScreenshots)
        excludedApps = defaults.stringArray(forKey: Key.excludedApps) ?? []
        openInFullScreen = defaults.bool(forKey: Key.openInFullScreen)
        showActionLabels = defaults.bool(forKey: Key.showActionLabels)
        labelsOnlyFolders = defaults.bool(forKey: Key.labelsOnlyFolders)
        betaUpdates = defaults.bool(forKey: Key.betaUpdates)
        tileIconSize = min(max(defaults.double(forKey: Key.tileIconSize), 40), 96)
        actionIconSize = min(max(defaults.double(forKey: Key.actionIconSize), 24), 54)
        autoUpdateCheck = defaults.bool(forKey: Key.autoUpdateCheck)
        pluginsEnabled = defaults.bool(forKey: Key.pluginsEnabled)
        pluginLogEnabled = defaults.bool(forKey: Key.pluginLogEnabled)
        PluginLog.shared.isEnabled = defaults.bool(forKey: Key.pluginLogEnabled)
        hotKeyCode = defaults.integer(forKey: Key.hotKeyCode)
        hotKeyModifiers = defaults.integer(forKey: Key.hotKeyModifiers)
        hotKeyLabel = defaults.string(forKey: Key.hotKeyLabel) ?? Self.defaultHotKey.label
        // Die Ablage zeigt immer das Neueste zuerst; die Einstellung dafür gibt es nicht mehr
        sortOrder = .newestFirst
        defaults.removeObject(forKey: Key.sortOrder)

        // Werte aus älteren Versionen (Woche, 30 Tage) gibt es nicht mehr
        let stored = defaults.double(forKey: Key.autoRemoveAfter)
        autoRemoveAfter = AutoRemoveOption(rawValue: stored)?.rawValue ?? AutoRemoveOption.never.rawValue

        // Nicht mehr einstellbar: Der Rand öffnet die Ablage immer, ein Symbol in der
        // Menüleiste gibt es nicht mehr. Alte Werte aufräumen.
        defaults.removeObject(forKey: "revealOnHover")
        defaults.removeObject(forKey: "showMenuBarIcon")
        // „Klick öffnet sofort“ gibt es nicht mehr als Schalter: Mit Wartezeit gilt es immer
        defaults.removeObject(forKey: "clickToOpenEarly")
        // Versionen überspringen gibt es nicht mehr: Updates kommen still im Hintergrund
        defaults.removeObject(forKey: "skippedUpdateVersion")

        if let data = defaults.data(forKey: Key.quickActions),
           let decoded = try? JSONDecoder().decode([QuickAction].self, from: data) {
            // „Umwandeln“ war in 1.28 eine Aktion; jetzt steht es im Kontextmenü
            quickActions = decoded.filter { $0.kind != .convert }
        } else {
            quickActions = QuickAction.defaults
        }
    }

    /// Lage und Größe der Ablage auf den Standard setzen.
    func resetShelfLayout() {
        resetPosition()
        resetLook()
    }

    /// „Öffnen → Wo“: Rand, Position, Bildschirme
    func resetPosition() {
        edge = ShelfDefaults.edge
        verticalPosition = ShelfDefaults.verticalPosition
        adaptivePosition = ShelfDefaults.adaptivePosition
        adaptiveMiddleThird = ShelfDefaults.adaptiveMiddleThird
        adaptiveZoneHalf = ShelfDefaults.adaptiveZoneHalf
        adaptiveZone = Self.defaultAdaptiveZone
        displayMode = ShelfDefaults.displayMode
    }

    /// „Aussehen“: Größe und Streifen
    func resetLook() {
        shelfWidth = ShelfDefaults.width
        shelfHeight = ShelfDefaults.height
        tileIconSize = ShelfDefaults.iconSize
        actionIconSize = ShelfDefaults.actionIconSize
        peekThickness = PeekDefaults.thickness
        peekLength = PeekDefaults.length
        peekRoundness = PeekDefaults.roundness
    }

    /// Alle Einstellungen auf den Auslieferungszustand. Inhalt der Ablage,
    /// Einführung und interne Umstellungen bleiben unberührt.
    func resetAll() {
        resetShelfLayout()
        language = .system
        betaUpdates = false
        labelsOnlyFolders = false
        titleStyle = .bardrop
        dragReveal = .immediately
        hapticsEnabled = true
        animationStyle = .standard
        openMode = .automatic
        openDelay = OpenDelay.quick
        reopenWhereLeft = false
        exactPointer = false
        diagnosticsEnabled = false
        twoActionRows = true
        actionRowSplit = 0
        pinFromShelf = true
        addScreenshots = false
        excludedApps = []
        openInFullScreen = false
        showActionLabels = true
        labelsOnlyFolders = false
        showOutline = true
        titleStyle = .bardrop
        removeAfterDragOut = true
        stackMultiple = true
        stackThreshold = 2
        keepAfterAction = true
        autoRemoveAfter = AutoRemoveOption.never.rawValue
        convertWebImages = true
        copyAllFiles = false
        dragOutCopyOnly = false
        sortOrder = .newestFirst
        quickActions = QuickAction.defaults
        autoUpdateCheck = true
        // Plugins bleiben installiert, sind aber aus und haben keine Rechte mehr
        pluginsEnabled = false
        pluginLogEnabled = false
        PluginManager.shared.resetAll()
        resetHotKey()
    }

    /// Form des ersten Streifens
    var peekSignature: String { "\(peekThickness)|\(peekLength)|\(peekRoundness)" }

    /// Größe der offenen Ablage
    var sizeSignature: String { "\(shelfWidth)|\(shelfHeight)|\(tileIconSize)|\(actionIconSize)|\(showActionLabels)" }

    /// Alles, was Lage oder Größe der Ablage beeinflusst.
    var layoutSignature: String {
        "\(tileIconSize)|\(actionIconSize)|\(showActionLabels)|\(edge.rawValue)|\(verticalPosition)|\(adaptivePosition)|\(adaptiveZone)|\(displayMode.rawValue)|\(shelfWidth)|\(shelfHeight)"
    }
}
