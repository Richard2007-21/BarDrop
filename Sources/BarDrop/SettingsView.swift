import SwiftUI
import AppKit
import ServiceManagement
import UniformTypeIdentifiers

// MARK: Allgemein

/// „Beim Anmelden öffnen“: Auch eine Anmeldung, die macOS erst noch bestätigt haben will,
/// gilt als eingeschaltet. Sonst stand der Schalter aus, obwohl BarDrop angemeldet war.
enum LoginItem {
    static var isOn: Bool {
        let status = SMAppService.mainApp.status
        return status == .enabled || status == .requiresApproval
    }
    static var needsApproval: Bool { SMAppService.mainApp.status == .requiresApproval }
}

struct GeneralSettings: View {
    @ObservedObject var settings: AppSettings
    @State private var launchAtLogin = LoginItem.isOn
    @State private var needsApproval = LoginItem.needsApproval
    @State private var loginError: String?

    var body: some View {
        SettingsPage {
            // Start, Sprache und Impuls in einer Karte: je eine Zeile, eigene Abschnitte lohnen nicht
            SettingsSection(note: loginError, noteColor: .red) {
                ToggleRow(L("Open at login", "Beim Anmelden öffnen"), isOn: $launchAtLogin)
                if launchAtLogin && needsApproval {
                    SettingsRow(L("Needs approval in System Settings", "Muss in den Systemeinstellungen erlaubt werden")) {
                        Button(L("Open", "Öffnen")) { SMAppService.openSystemSettingsLoginItems() }
                            .buttonStyle(KlackButtonStyle())
                    }
                }
                PickerRow(L("Language", "Sprache"), selection: $settings.language,
                          options: AppLanguage.allCases.map { ($0, $0.title) })
                ToggleRow(L("Haptic feedback", "Haptisches Feedback"),
                          isOn: $settings.hapticsEnabled)
            }
            .onChange(of: launchAtLogin) { _, enabled in
                do {
                    if enabled { try SMAppService.mainApp.register() }
                    else { try SMAppService.mainApp.unregister() }
                    loginError = nil
                } catch {
                    loginError = L("Couldn’t turn this on. Move BarDrop to the Applications folder and try again.",
                                   "Das hat nicht geklappt. Leg BarDrop in den Ordner „Programme“ und versuch es erneut.")
                    Diagnostics.shared.failure("login", "Beim Anmelden öffnen nicht umgestellt", error)
                    launchAtLogin = LoginItem.isOn
                }
                needsApproval = LoginItem.needsApproval
            }

            SettingsSection(L("Reset", "Zurücksetzen")) {
                SettingsRow(L("All settings", "Alle Einstellungen")) {
                    Button(L("Reset", "Zurücksetzen")) { confirmReset() }
                        .buttonStyle(KlackButtonStyle(destructive: true))
                }
            }
        }
    }

    private func confirmReset() {
        let alert = NSAlert()
        alert.messageText = L("Reset all settings?", "Alle Einstellungen zurücksetzen?")
        alert.informativeText = L("All settings go back to their defaults, including the language, the shortcut, the action bar, updates and beta versions. Plugins stay installed but are turned off and lose their permissions. Only the items in the shelf are kept. This can’t be undone.",
                                  "Alle Einstellungen werden auf die Standardwerte zurückgesetzt, auch Sprache, Kurzbefehl, Aktionsleiste, Updates und Beta-Versionen. Plugins bleiben installiert, sind aber aus und ohne Berechtigungen. Nur die Objekte in der Ablage bleiben. Das lässt sich nicht widerrufen.")
        alert.alertStyle = .warning
        alert.addButton(withTitle: L("Reset", "Zurücksetzen"))
        alert.addButton(withTitle: L("Cancel", "Abbrechen"))
        alert.buttons.first?.hasDestructiveAction = true
        alert.icon = NSApp.applicationIconImage
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        settings.resetAll()
        if !launchAtLogin { launchAtLogin = true }   // Standard: angemeldet (über onChange)
    }
}

// MARK: Tastatur

struct KeyboardSettings: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject private var hotKeyStatus = HotKeyStatus.shared
    @State private var showShortcuts = false

    var body: some View {
        SettingsPage {
            SettingsSection(L("Show or hide the shelf", "Ablage ein- oder ausblenden"),
                            info: L("Click ⌃, ⌥, ⇧ or ⌘ to add or remove a modifier key. To change the key, click it on the right and press a new one.",
                                    "Klick auf ⌃, ⌥, ⇧ oder ⌘, um eine Sondertaste hinzuzufügen oder wegzunehmen. Für eine andere Taste klick rechts auf die Taste und drück die neue."),
                            note: hotKeyStatus.available ? nil : L("Another app already uses this shortcut. Choose a different combination.",
                                                                   "Dieser Kurzbefehl ist schon von einer anderen App belegt. Wähl eine andere Kombination."),
                            noteColor: .red) {
                HotKeyEditor(settings: settings)
                    .padding(8)
            }

            // Die Kürzel in der Ablage sind eingeklappt: Wer sie sucht, klappt sie auf
            SettingsSection(L("In the open shelf", "In der offenen Ablage")) {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { showShortcuts.toggle() }
                } label: {
                    SettingsRow(L("Keyboard shortcuts", "Tastenkürzel")) {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .rotationEffect(.degrees(showShortcuts ? 90 : 0))
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if showShortcuts {
                    ShortcutRow(L("Quick Look", "Übersicht"), [L("Space", "Leertaste")])
                    ShortcutRow(L("Open", "Öffnen"), ["↩"])
                    ShortcutRow(L("Remove from shelf", "Aus der Ablage entfernen"), ["⌫"])
                    ShortcutRow(L("Move to Trash", "In den Papierkorb legen"), ["⌘", "⌫"])
                    ShortcutRow(L("Undo", "Widerrufen"), ["⌘", "Z"])
                    ShortcutRow(L("Redo", "Wiederholen"), ["⇧", "⌘", "Z"])
                    ShortcutRow(L("Copy", "Kopieren"), ["⌘", "C"])
                    ShortcutRow(L("Cut", "Ausschneiden"), ["⌘", "X"])
                    ShortcutRow(L("Paste from clipboard", "Aus der Zwischenablage einfügen"), ["⌘", "V"])
                    ShortcutRow(L("Copy path", "Pfad kopieren"), ["⌥", "⌘", "C"])
                    ShortcutRow(L("Show in Finder", "Im Finder zeigen"), ["⌘", "R"])
                    ShortcutRow(L("Get Info", "Informationen"), ["⌘", "I"])
                    ShortcutRow(L("Select all", "Alle auswählen"), ["⌘", "A"])
                    ShortcutRow(L("Move selection", "Auswahl bewegen"), ["←", "→", "↑", "↓"])
                    ShortcutRow(L("Extend selection", "Auswahl erweitern"), ["⇧", "←"])
                    ShortcutRow(L("Back from a stack or folder", "Zurück aus Stapel oder Ordner"), ["⌘", "↑"])
                    ShortcutRow(L("Move or remove an action", "Aktion verschieben oder entfernen"), ["⌘", L("Drag", "Ziehen")])
                    ShortcutRow(L("Settings", "Einstellungen"), ["⌘", ","])
                    ShortcutRow(L("Go back or close", "Zurück oder schließen"), ["esc"])
                }
            }
        }
    }
}

/// Eine Zeile mit Tasten als kleine Kappen, wie die Tasten oben beim Kurzbefehl
struct ShortcutRow: View {
    let title: String
    let keys: [String]
    init(_ title: String, _ keys: [String]) {
        self.title = title
        self.keys = keys
    }
    var body: some View {
        SettingsRow(title) {
            HStack(spacing: 3) {
                ForEach(Array(keys.enumerated()), id: \.offset) { _, key in
                    label(key)
                        .foregroundStyle(.secondary)
                        .frame(minWidth: 22, minHeight: 22)
                        .padding(.horizontal, key.count > 1 ? 5 : 0)
                        .background(
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .fill(SettingsTheme.shortcutKey)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .strokeBorder(SettingsTheme.separator, lineWidth: 1)
                        )
                }
            }
        }
    }

    /// Sondertasten als Systemsymbol: Die Zeichen ⌘, ⌫ usw. sitzen in der Schrift nicht in
    /// der Mitte ihrer Zeile und standen deshalb schief in der Taste. Symbole werden nach
    /// ihrer Form mittig gesetzt. Buchstaben und Wörter bleiben Text.
    private static let symbols: [String: String] = [
        "⌘": "command", "⇧": "shift", "⌥": "option", "⌃": "control",
        "⌫": "delete.left", "↩": "return",
        "←": "arrow.left", "→": "arrow.right", "↑": "arrow.up", "↓": "arrow.down",
    ]

    @ViewBuilder
    private func label(_ key: String) -> some View {
        if let name = Self.symbols[key] {
            Image(systemName: name)
                .font(.system(size: 10.5, weight: .medium))
        } else {
            Text(key)
                .font(.system(size: 11.5, weight: .medium, design: .rounded))
        }
    }
}

// MARK: Öffnen

/// Wo am Rand die Ablage erscheint: fest an einer Stelle oder am Zeiger (dann in einem
/// einstellbaren Bereich des Rands)
private enum HeightMode: String, CaseIterable, Identifiable {
    case fixed, adaptive
    var id: String { rawValue }
    var title: String {
        switch self {
        case .fixed: return L("Fixed", "Fest")
        case .adaptive: return L("Follows pointer", "Folgt dem Zeiger")
        }
    }
}

/// Öffnen: wo die Ablage am Rand sitzt und wann sie aufgeht.
struct OpeningSettings: View {
    @ObservedObject var settings: AppSettings

    private var heightMode: Binding<HeightMode> {
        Binding(
            get: { settings.adaptivePosition ? .adaptive : .fixed },
            set: { mode in settings.adaptivePosition = mode == .adaptive }
        )
    }

    var body: some View {
        SettingsPage {
            SettingsCard {
                ScreenPreview(settings: settings)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
            }

            SettingsSection(L("Where", "Wo")) {
                PickerRow(L("Screen edge", "Bildschirmrand"), selection: $settings.edge,
                          options: ScreenEdge.allCases.map { ($0, $0.title) })
                PickerRow(L("Position along the edge", "Position am Rand"), selection: heightMode,
                          options: HeightMode.allCases.map { ($0, $0.title) })
                if settings.adaptivePosition {
                    // Wie viel vom Rand reagiert, mittig: ein kleines Stück bis der ganze Rand
                    SliderRow(L("Area along the edge", "Bereich am Rand"),
                              info: L("In this part of the edge, the shelf opens at the pointer.",
                                      "In diesem Teil des Rands öffnet sich die Ablage am Zeiger."),
                              value: $settings.adaptiveZone,
                              range: AppSettings.adaptiveZoneRange, step: AppSettings.adaptiveZoneStep,
                              format: SliderRow.percent)
                } else {
                    SliderRow(L("Height on the edge", "Höhe am Rand"), value: $settings.verticalPosition, range: 0...1, step: 0.05,
                              format: SliderRow.percent)
                }
                PickerRow(L("Displays", "Bildschirme"), selection: $settings.displayMode,
                          options: DisplayMode.allCases.map { ($0, $0.title) })
            }

            SettingsSection(L("When", "Wann"),
                            note: settings.exactPointer
                                ? L("“Strip while dragging” has no effect while “Open only at the strip” is on.",
                                    "„Streifen beim Ziehen“ wirkt nicht, solange „Nur direkt am Streifen öffnen“ an ist.") : nil) {
                PickerRow(L("Open shelf", "Ablage öffnen"),
                          info: L("From a 1 second delay on, clicking the strip still opens the shelf right away.",
                                  "Ab 1 Sekunde Wartezeit öffnet ein Klick auf den Streifen die Ablage trotzdem sofort."),
                          selection: $settings.openChoice,
                          options: OpenChoice.all.map { ($0, $0.title) })
                ToggleRow(L("Open only at the strip", "Nur direkt am Streifen öffnen"),
                          info: L("The shelf only opens when the pointer or a dragged item reaches the strip itself, not the area around it.",
                                  "Die Ablage öffnet sich erst, wenn der Zeiger oder ein gezogenes Objekt den Streifen selbst erreicht, nicht schon den Bereich darum."),
                          isOn: $settings.exactPointer)
                // Als Menü: Für einen Umschalter sind die Texte zu lang, er drückte den Titel
                // auf mehrere Zeilen zusammen
                // „Nur direkt am Streifen“ gilt auch beim Ziehen: Dann gibt es keinen Streifen in
                // Randnähe, die Wahl hier wirkt nicht und ist grau
                PickerRow(L("Strip while dragging", "Streifen beim Ziehen"),
                          selection: $settings.dragReveal,
                          options: DragReveal.selectable.map { ($0, $0.title) }, menu: true)
                    .disabled(settings.exactPointer)
                ToggleRow(L("Open where you left off", "An letzter Stelle öffnen"),
                          info: L("The shelf opens where you were last: at the same place in the list, in the same stack or folder.",
                                  "Die Ablage öffnet sich dort, wo du zuletzt warst: an derselben Stelle in der Liste, im selben Stapel oder Ordner."),
                          isOn: $settings.reopenWhereLeft)
            }

            // Wie die Aktionsliste: Liste in einer Karte, „Hinzufügen“ als eigene Karte darunter
            VStack(alignment: .leading, spacing: 8) {
                // Ausnahmen: Vollbild und einzelne Apps, in denen der Rand die Ablage nicht öffnet
                SettingsSection(L("Exceptions", "Ausnahmen")) {
                    ToggleRow(L("Open over full-screen apps", "Auch über Apps im Vollbild öffnen"),
                              isOn: $settings.openInFullScreen)
                    if settings.excludedApps.isEmpty {
                        Text(L("No apps excluded", "Keine Apps ausgenommen"))
                            .font(.system(size: 13.5))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, SettingsTheme.rowPadding)
                            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    }
                    ForEach(settings.excludedApps, id: \.self) { id in
                        ExcludedAppRow(bundleID: id) {
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.88)) {
                                settings.excludedApps.removeAll { $0 == id }
                            }
                        }
                    }
                }
                AddExcludedAppRow(settings: settings)
                    .padding(.top, 4)
            }
        }
    }
}

// MARK: Aussehen

struct AppearanceSettings: View {
    @ObservedObject var settings: AppSettings

    var body: some View {
        SettingsPage {
            SettingsSection(L("Size", "Größe")) {
                SliderRow(L("Width", "Breite"), value: $settings.shelfWidth, range: 220...400, step: 10,
                          format: SliderRow.points)
                SliderRow(L("Height", "Höhe"), value: $settings.shelfHeight, range: 280...680, step: 10,
                          format: SliderRow.points)
                SliderRow(L("Item size", "Größe der Objekte"), value: $settings.tileIconSize, range: 40...96, step: 4,
                          format: SliderRow.points)
            }

            SettingsSection(L("Strip at the edge", "Streifen am Rand")) {
                SliderRow(L("Thickness", "Dicke"), value: $settings.peekThickness, range: 3...20, step: 1,
                          format: SliderRow.points)
                SliderRow(L("Length", "Länge"), value: $settings.peekLength, range: 60...200, step: 4,
                          format: SliderRow.points)
            }

            SettingsSection(L("Style", "Stil")) {
                ToggleRow(L("Light outline", "Heller Rahmen"),
                          isOn: $settings.showOutline)
                ToggleRow(L("Translucent when detached", "Durchscheinend, wenn losgelöst"),
                          info: L("When you pull the shelf away from the edge, it turns translucent like glass. When off, it stays black.",
                                  "Ziehst du die Ablage vom Rand weg, wird sie durchscheinend wie Glas. Ist das aus, bleibt sie schwarz."),
                          isOn: $settings.detachedGlass)
                PickerRow(L("Animation", "Animation"),
                          // Nur wenn die Auswahl gesperrt ist, braucht es eine Erklärung
                          info: AnimationStyle.reduceMotion
                              ? L("“Reduce motion” is on in Accessibility, so BarDrop only uses fades.",
                                  "„Bewegung reduzieren“ ist in den Bedienungshilfen aktiv, daher blendet BarDrop nur über.")
                              : nil,
                          selection: $settings.animationStyle,
                          options: AnimationStyle.allCases.map { ($0, $0.title) })
                    .disabled(AnimationStyle.reduceMotion)
            }
        }
    }
}

/// Kleine Bildschirmvorschau mit der Ablage an der gewählten Stelle.
private struct ScreenPreview: View {
    @ObservedObject var settings: AppSettings

    var body: some View {
        let w: CGFloat = 220, h: CGFloat = 132
        let nubH: CGFloat = 34, nubW: CGFloat = 4
        let usable = h - 12 - nubH - 8
        let y = 12 + 4 + usable * (1 - CGFloat(settings.verticalPosition))

        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(LinearGradient(colors: [Color(nsColor: .controlAccentColor).opacity(0.55),
                                              Color(nsColor: .controlAccentColor).opacity(0.25)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
            Rectangle()
                .fill(Color.white.opacity(0.35))
                .frame(width: w, height: 8)
            if settings.adaptivePosition {
                // Bereich, in dem die adaptive Ablage reagiert
                let zone = settings.adaptiveZoneFraction ?? 1
                let top: CGFloat = 8 + (h - 8) * (1 - zone) / 2
                let len: CGFloat = (h - 8) * zone
                Capsule()
                    .fill(Color.black.opacity(0.55))
                    .frame(width: 4, height: len)
                    .offset(x: settings.edge == .right ? w - 4 : 0, y: top)
                    .animation(.spring(response: 0.35, dampingFraction: 0.85), value: settings.adaptiveZone)
            }
            EdgeBlobShape(edge: settings.edge, cornerRadius: 2, fillet: 4, filletStretch: 1.4)
                .fill(Color.black)
                .opacity(settings.adaptivePosition ? 0 : 1)
                .frame(width: nubW, height: nubH)
                .offset(x: settings.edge == .right ? w - nubW : 0, y: y)
                .animation(.spring(response: 0.35, dampingFraction: 0.85), value: settings.edge)
                .animation(.spring(response: 0.35, dampingFraction: 0.85), value: settings.verticalPosition)
        }
        .frame(width: w, height: h)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.15), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.15), radius: 6, y: 2)
    }
}

// MARK: Objekte

/// Dateien aus dem Finder: auf das Original zeigen oder eine eigene Kopie behalten
private enum FinderFiles: String, CaseIterable, Identifiable {
    case original, copy
    var id: String { rawValue }
    var title: String {
        switch self {
        case .original: return L("Use original", "Original verwenden")
        case .copy: return L("Keep a copy", "Kopie behalten")
        }
    }
}

/// Was nach dem Verwenden mit einem Objekt geschieht (fasst zwei Schalter zusammen). Standard: nach dem Herausziehen
/// entfernen, nach Aktionen (AirDrop, Mail, Ordner …) behalten.
private enum AfterUse: String, CaseIterable, Identifiable {
    case keep, afterDragOut, always
    var id: String { rawValue }
    var title: String {
        switch self {
        case .keep: return L("Keep in the shelf", "In der Ablage behalten")
        case .afterDragOut: return L("Remove after dragging out", "Nach dem Herausziehen entfernen")
        case .always: return L("Always remove", "Immer entfernen")
        }
    }
}

struct ItemSettings: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var store: ShelfStore
    @ObservedObject private var folderAccess = FolderAccess.shared

    private var autoRemove: Binding<AutoRemoveOption> {
        Binding(get: { AutoRemoveOption(rawValue: settings.autoRemoveAfter) ?? .never },
                set: { settings.autoRemoveAfter = $0.rawValue })
    }

    /// 0 = keine Stapel, sonst Anzahl
    private var stackFrom: Binding<Int> {
        Binding(get: { settings.stackMultiple ? settings.stackThreshold : 0 },
                set: { value in
                    settings.stackMultiple = value > 0
                    if value > 0 { settings.stackThreshold = value }
                })
    }

    private var finderFiles: Binding<FinderFiles> {
        Binding(get: { settings.copyAllFiles ? .copy : .original },
                set: { settings.copyAllFiles = $0 == .copy })
    }

    private var afterUse: Binding<AfterUse> {
        Binding(
            get: {
                guard settings.removeAfterDragOut else { return .keep }
                return settings.keepAfterAction ? .afterDragOut : .always
            },
            set: { value in
                settings.removeAfterDragOut = value != .keep
                settings.keepAfterAction = value != .always
            }
        )
    }

    /// Erklärung passend zur gewählten Option
    private var afterUseNote: String {
        // Kurz: was mit dem Objekt geschieht, und nur bei Bedarf, wie man es zurückholt
        let copy = settings.dragOutCopyOnly ? ""
            : L(" The Finder may move files you drag out.", " Der Finder darf herausgezogene Dateien verschieben.")
        switch afterUse.wrappedValue {
        case .keep:
            return L("Items stay until you remove them or file them in a folder.", "Objekte bleiben, bis du sie entfernst oder in einen Ordner legst.") + copy
        case .afterDragOut:
            return L("Items leave the shelf when you drag them out or file them in a folder, but stay after other actions. ⌘Z brings them back.",
                     "Herausgezogene und in Ordner gelegte Objekte verschwinden, nach anderen Aktionen bleiben sie. ⌘Z holt sie zurück.") + copy
        case .always:
            return L("Items leave the shelf after dragging out and after actions. ⌘Z brings them back.",
                     "Objekte verschwinden nach dem Herausziehen und nach Aktionen. ⌘Z holt sie zurück.") + copy
        }
    }

    /// Wahlen für „Stapel bilden“; ein selbst gewählter anderer Wert bleibt in der Liste
    private var stackThresholds: [Int] {
        var values = [2, 3, 5, 10]
        if settings.stackMultiple, !values.contains(settings.stackThreshold) {
            values.append(settings.stackThreshold)
            values.sort()
        }
        return values
    }

    var body: some View {
        SettingsPage {
            SettingsSection(L("Arrangement", "Anordnung")) {
                PickerRow(L("Group into a stack", "Stapel bilden"),
                          info: L("When this many items are dropped at once, they become a stack. You can also select several items, right-click and choose “Group as Stack”. Click a stack to open it.",
                                  "Werden so viele Objekte auf einmal abgelegt, entsteht ein Stapel. Du kannst auch mehrere Objekte auswählen und per Rechtsklick „Als Stapel zusammenfassen“ wählen. Ein Klick öffnet einen Stapel."),
                          selection: stackFrom,
                          options: [(0, L("Never", "Nie"))] + stackThresholds.map { ($0, L("\($0) or more items", "Ab \($0) Objekten")) })
            }

            // Alles, was Objekte aus der Ablage nimmt, an einer Stelle: nach dem Verwenden
            // und nach Zeit (vorher zwei Abschnitte mit ähnlichen Namen)
            SettingsSection(L("Using and removing", "Verwenden und entfernen"), info: afterUseNote) {
                PickerRow(L("After use", "Nach dem Verwenden"), selection: afterUse,
                          options: AfterUse.allCases.map { ($0, $0.title) })
                PickerRow(L("Remove automatically", "Automatisch entfernen"),
                          info: L("Removing (⌫) only takes items out of the shelf; files stay in the Finder. Copies, images, links and text that exist only in BarDrop are deleted once ⌘Z can no longer bring them back, at the latest 15 minutes after you drag them out or use them in an action. ⌘⌫ moves files to the Trash; ⌘Z puts them back.",
                                  "Entfernen (⌫) nimmt Objekte nur aus der Ablage, Dateien im Finder bleiben. Was nur in BarDrop liegt (Kopien, Bilder, Links, Texte), wird gelöscht, sobald ⌘Z es nicht mehr zurückholen kann, spätestens 15 Minuten nach dem Herausziehen oder einer Aktion. ⌘⌫ legt Dateien in den Papierkorb, ⌘Z legt sie zurück."),
                          selection: autoRemove,
                          options: AutoRemoveOption.allCases.map { ($0, $0.title) })
                ToggleRow(L("Always copy when dragging out", "Beim Herausziehen immer kopieren"), isOn: $settings.dragOutCopyOnly)
            }

            SettingsSection(L("Storage", "Speicherung"),
                            info: L("Images from the web, text, links and files from browsers or other apps are always stored in BarDrop.",
                                    "Bilder aus dem Web, Texte, Links und Dateien aus Browsern oder anderen Apps werden immer in BarDrop gespeichert.")) {
                PickerRow(L("Files from the Finder", "Dateien aus dem Finder"),
                          info: L("Use original: The shelf remembers where the file is and always uses its latest version. Keep a copy: The shelf stores its own copy, which doesn’t change.",
                                  "Original verwenden: Die Ablage merkt sich, wo die Datei liegt, und verwendet immer die aktuelle Version. Kopie behalten: Die Ablage legt eine eigene Kopie an, die sich nicht mehr ändert."),
                          selection: finderFiles,
                          options: FinderFiles.allCases.map { ($0, $0.title) },
                          menu: true)
                ToggleRow(L("Convert web images", "Webbilder umwandeln"),
                          info: L("Images from the web in WebP, AVIF or HEIC format are saved as PNG or JPEG, so any app can open them.",
                                  "Bilder aus dem Web im Format WebP, AVIF oder HEIC werden als PNG oder JPEG gespeichert, damit jede App sie öffnen kann."),
                          isOn: $settings.convertWebImages)
                ToggleRow(L("Add new screenshots", "Neue Bildschirmfotos hinzufügen"),
                          isOn: $settings.addScreenshots)
                ToggleRow(L("Add AirDrop files", "AirDrop-Dateien hinzufügen"),
                          info: L("Files you receive with AirDrop go straight into the shelf instead of the Downloads folder.",
                                  "Per AirDrop empfangene Dateien kommen direkt in die Ablage statt in den Ordner „Downloads“."),
                          isOn: $settings.addAirDrop)
                // macOS lässt BarDrop den Ordner nicht lesen: sagen, welcher, und wohin
                ForEach(deniedFolders, id: \.self) { folder in
                    SettingsRow(L("No access to “\(FolderAccess.displayName(folder))”", "Kein Zugriff auf „\(FolderAccess.displayName(folder))“"),
                                subtitle: L("Allow access in System Settings → Privacy & Security → Files & Folders.",
                                            "Erlaube den Zugriff unter Systemeinstellungen → Datenschutz & Sicherheit → Dateien und Ordner.")) {
                        Button(L("Open", "Öffnen")) { FolderAccess.openPrivacySettings() }
                            .buttonStyle(KlackButtonStyle())
                    }
                }
            }
        }
    }
}

extension ItemSettings {
    /// Nur Ordner, die gerade beobachtet werden (Bildschirmfotos bzw. AirDrop an)
    fileprivate var deniedFolders: [URL] {
        var folders: [URL] = []
        if settings.addScreenshots { folders.append(ScreenshotWatcher.screenshotFolder()) }
        if settings.addAirDrop { folders.append(AirDropWatcher.downloadsFolder) }
        return Array(Set(folders.map(\.standardizedFileURL))).filter { folderAccess.isDenied($0) }
            .sorted { $0.path < $1.path }
    }
}

// MARK: Aktionen

/// Namen unter den Aktionen: alle, nur Ordner oder keine
private enum ActionLabelMode: String, CaseIterable, Identifiable {
    case all, folders, none
    var id: String { rawValue }
    var title: String {
        switch self {
        case .all: return L("All", "Alle")
        case .folders: return L("Folders only", "Nur Ordner")
        case .none: return L("None", "Keine")
        }
    }
}

struct ActionSettings: View {
    @ObservedObject var settings: AppSettings
    @State private var selection: QuickAction.ID?
    @State private var addButtonFrame: CGRect = .zero

    private var limit: Int { QuickAction.limit }

    private var labelMode: Binding<ActionLabelMode> {
        Binding(
            get: {
                guard settings.showActionLabels else { return .none }
                return settings.labelsOnlyFolders ? .folders : .all
            },
            set: { mode in
                settings.showActionLabels = mode != .none
                settings.labelsOnlyFolders = mode == .folders
            }
        )
    }

    var body: some View {
        SettingsPage {
            VStack(alignment: .leading, spacing: 8) {
                SettingsHeader(L("Action bar", "Aktionsleiste"))
                .padding(.horizontal, 8)

                ActionListEditor(settings: settings, selection: $selection,
                                 onRemove: remove, onMove: move)
                    .zIndex(1)   // gezogene Zeile liegt über allem darunter

                AddActionRow(count: settings.quickActions.count, limit: limit, frame: $addButtonFrame) {
                    showAddMenu()
                }
                .padding(.top, 4)
            }
            .zIndex(1)

            SettingsSection(L("Layout", "Darstellung")) {
                SliderRow(L("Action size", "Größe der Aktionen"), value: $settings.actionIconSize, range: 24...54, step: 2,
                          format: SliderRow.points)
                PickerRow(L("Show names", "Namen anzeigen"), selection: labelMode,
                          options: ActionLabelMode.allCases.map { ($0, $0.title) })
            }

            SettingsSection(L("In the shelf", "In der Ablage")) {
                ToggleRow(L("Pin by dragging", "Per Ziehen anheften"),
                          info: L("Drag a folder or app over the open shelf and drop it on “Pin” at the end of the action bar. Hold ⌘ and drag an action out of the shelf to remove it.",
                                  "Zieh einen Ordner oder eine App über die offene Ablage und lass sie auf „Anheften“ am Ende der Aktionsleiste los. Halt ⌘ gedrückt und zieh eine Aktion aus der Ablage heraus, um sie zu entfernen."),
                          isOn: $settings.pinFromShelf)
            }
        }
    }

    private func showAddMenu() {
        let menu = NSMenu()
        for kind in [QuickAction.Kind.airdrop, .mail, .messages, .share, .trash] {
            let item = ClosureMenuItem(QuickAction(kind: kind).title) { add(QuickAction(kind: kind)) }
            if settings.quickActions.contains(where: { $0.kind == kind }) {
                item.action = nil   // schon vorhanden: ausgegraut
            }
            menu.addItem(item)
        }
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem(L("Folder", "Ordner")) { chooseFolder() })
        menu.addItem(ClosureMenuItem("App") { chooseApp() })
        // Kurzbefehle aus der App Kurzbefehle: Objekte darauf ziehen führt sie aus
        let shortcuts = NSMenu()
        let names = ShortcutRunner.list()
        if names.isEmpty {
            let none = NSMenuItem(title: L("No shortcuts found", "Keine Kurzbefehle gefunden"), action: nil, keyEquivalent: "")
            shortcuts.addItem(none)
        }
        for name in names {
            let item = ClosureMenuItem(name) { add(QuickAction(kind: .shortcut, path: name)) }
            if settings.quickActions.contains(where: { $0.kind == .shortcut && $0.path == name }) {
                item.action = nil
            }
            shortcuts.addItem(item)
        }
        let shortcutItem = NSMenuItem(title: L("Shortcut", "Kurzbefehl"), action: nil, keyEquivalent: "")
        shortcutItem.submenu = shortcuts
        menu.addItem(shortcutItem)
        // Eingeschaltete Plugins, die in der Aktionsleiste laufen können
        let plugins = PluginManager.shared.activePlugins.filter { $0.manifest.allTriggers.contains(.action) }
        if !plugins.isEmpty {
            menu.addItem(.separator())
            for plugin in plugins {
                let item = ClosureMenuItem(plugin.manifest.title) { add(QuickAction(kind: .plugin, path: plugin.id)) }
                if settings.quickActions.contains(where: { $0.kind == .plugin && $0.path == plugin.id }) {
                    item.action = nil
                }
                menu.addItem(item)
            }
        }
        MenuPresenter.show(menu, below: addButtonFrame)
    }

    private func remove(_ action: QuickAction) {
        guard let index = settings.quickActions.firstIndex(where: { $0.id == action.id }) else { return }
        let split = settings.effectiveActionSplit
        withAnimation(.spring(response: 0.3, dampingFraction: 0.88)) {
            settings.quickActions.remove(at: index)
            // Aus der oberen Reihe entfernt: die Grenze rückt mit, die untere Reihe bleibt, wie sie ist
            if index < split { settings.actionRowSplit = split - 1 }
        }
        if selection == action.id { selection = nil }
    }

    /// Nach oben oder unten um einen Platz; über die Grenze der Reihen hinweg wechselt die Reihe.
    private func move(_ action: QuickAction, by offset: Int) {
        guard let i = settings.quickActions.firstIndex(of: action) else { return }
        var order = settings.quickActions
        var split = settings.effectiveActionSplit
        // Erst die Reihe wechseln, wenn die Aktion am Rand ihrer Reihe steht
        if offset < 0 && i == split, split < QuickAction.perRow { split += 1 }
        else if offset > 0 && i == split - 1, order.count - split < QuickAction.perRow { split -= 1 }
        else {
            let j = i + offset
            guard order.indices.contains(j) else { return }
            order.swapAt(i, j)
        }
        withAnimation(.spring(response: 0.3, dampingFraction: 0.88)) {
            settings.quickActions = order
            settings.actionRowSplit = AppSettings.clampSplit(split, count: order.count)
        }
        Haptics.tap()
    }

    private func add(_ action: QuickAction) {
        guard settings.quickActions.count < limit else { return }
        withAnimation(.spring(response: 0.3, dampingFraction: 0.88)) {
            settings.quickActions.append(action)
        }
        selection = action.id
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = L("Add", "Hinzufügen")
        panel.message = L("Choose a folder to move items to.", "Wähl einen Ordner, in den Objekte verschoben werden.")
        if panel.runModal() == .OK, let url = panel.url {
            add(QuickAction(kind: .folder, path: url.path))
        }
    }

    private func chooseApp() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.prompt = L("Add", "Hinzufügen")
        panel.message = L("Choose an app to open items with.", "Wähl eine App, mit der Objekte geöffnet werden.")
        if panel.runModal() == .OK, let url = panel.url {
            add(QuickAction(kind: .app, path: url.path))
        }
    }
}

// MARK: Aktionen anordnen

/// Liste der Aktionen zum Anordnen per Ziehen, bei zwei Reihen in zwei Karten.
///
/// Während des Ziehens bleibt die gespeicherte Reihenfolge unverändert. Aus der
/// Zeigerposition wird nur ein Vorschlag berechnet, und jede Zeile bekommt ihre Lage
/// aus diesem Vorschlag. Die gezogene Zeile folgt dem Zeiger, die anderen gleiten an
/// ihren neuen Platz, jeder neue Platz rastet mit einem leichten Impuls ein. Erst beim
/// Loslassen wird gespeichert. So springt nichts, und die Trennlinien bleiben stehen.
private struct ActionListEditor: View {
    @ObservedObject var settings: AppSettings
    @Binding var selection: QuickAction.ID?
    let onRemove: (QuickAction) -> Void
    let onMove: (QuickAction, Int) -> Void

    /// Reihenfolge und Grenze zwischen den Reihen
    struct Arrangement: Equatable {
        var order: [QuickAction.ID]
        var split: Int
    }

    @State private var dragging: QuickAction.ID?
    @State private var dragStartY: CGFloat = 0
    @State private var dragTranslation: CGFloat = 0
    @State private var proposal: Arrangement?

    private static let rowHeight: CGFloat = 52
    private static let pitch: CGFloat = rowHeight + 1      // Zeile plus Trennlinie
    private static let labelHeight: CGFloat = 26           // „Obere Reihe“ über der Karte
    private static let rowGap: CGFloat = 14                // Abstand zwischen den Karten
    private static let space = "actionList"

    private var committed: Arrangement {
        Arrangement(order: settings.quickActions.map(\.id), split: settings.effectiveActionSplit)
    }

    /// Was gerade gezeigt wird: der Vorschlag beim Ziehen, sonst das Gespeicherte
    private var shown: Arrangement { proposal ?? committed }

    // MARK: Geometrie

    private func counts(_ a: Arrangement) -> (top: Int, bottom: Int) {
        (a.split, a.order.count - a.split)
    }

    /// Gezeigte Zeilen je Karte. Während des Ziehens behält die obere Karte ihre Höhe,
    /// auch wenn die Aktion nach unten wandert: So bleibt die untere Reihe stehen,
    /// statt unter dem Zeiger nach oben zu springen, und man trifft ihre Plätze.
    private func displayCounts(_ a: Arrangement) -> (top: Int, bottom: Int) {
        let c = counts(a)
        guard dragging != nil else { return c }
        return (max(c.top, counts(committed).top), c.bottom)
    }

    private func cardHeight(_ n: Int) -> CGFloat { CGFloat(max(1, n)) * Self.pitch - 1 }

    /// Oberkante der Karte einer Reihe
    private func rowTop(_ row: Int, _ a: Arrangement) -> CGFloat {
        if row == 0 { return Self.labelHeight }
        return Self.labelHeight + cardHeight(displayCounts(a).top) + Self.rowGap + Self.labelHeight
    }

    private func totalHeight(_ a: Arrangement) -> CGFloat {
        let c = displayCounts(a)
        return rowTop(1, a) + cardHeight(c.bottom)
    }

    /// Reihe und Platz einer Aktion
    private func slot(of id: QuickAction.ID, in a: Arrangement) -> (row: Int, index: Int)? {
        guard let i = a.order.firstIndex(of: id) else { return nil }
        if i >= a.split { return (1, i - a.split) }
        return (0, i)
    }

    private func y(of id: QuickAction.ID, in a: Arrangement) -> CGFloat {
        guard let s = slot(of: id, in: a) else { return 0 }
        return rowTop(s.row, a) + CGFloat(s.index) * Self.pitch
    }

    // MARK: Vorschlag aus der Zeigerposition

    /// Wohin die gezogene Aktion käme, wenn ihre Oberkante bei `top` liegt.
    private func propose(for id: QuickAction.ID, top: CGFloat) -> Arrangement {
        let base = committed
        var rest = base.order
        guard let from = rest.firstIndex(of: id) else { return base }
        rest.remove(at: from)
        let center = top + Self.rowHeight / 2

        // Zwei Reihen: Anzahlen ohne die gezogene Aktion
        let topCount = from < base.split ? base.split - 1 : base.split
        let bottomCount = rest.count - topCount
        // Grenze: Mitte zwischen der oberen Karte, wie sie gerade zu sehen ist, und der
        // unteren. Sie wandert nur, wenn die obere Karte wächst; das wirkt zugleich als
        // Puffer, damit die Reihe an der Grenze nicht hin und her springt.
        let shownTop = displayCounts(shown).top
        let boundary = Self.labelHeight + cardHeight(shownTop) + (Self.rowGap + Self.labelHeight) / 2
        let toBottomRow = center > boundary

        var split = topCount
        let insertAt: Int
        if toBottomRow {
            // Die obere Karte behält beim Ziehen mindestens ihre ursprüngliche Höhe
            let rowStart = Self.labelHeight + cardHeight(max(topCount, base.split)) + Self.rowGap + Self.labelHeight
            let index = min(max(Int(((center - rowStart - Self.rowHeight / 2) / Self.pitch).rounded()), 0), bottomCount)
            insertAt = topCount + index
        } else {
            let index = min(max(Int(((center - Self.labelHeight - Self.rowHeight / 2) / Self.pitch).rounded()), 0), topCount)
            insertAt = index
            split += 1
        }
        rest.insert(id, at: insertAt)
        // Ist die Zielreihe voll, rückt ihre letzte bzw. erste Aktion in die andere Reihe
        return Arrangement(order: rest, split: AppSettings.clampSplit(split, count: rest.count))
    }

    // MARK: Ansicht

    var body: some View {
        let a = shown
        let c = counts(a)
        let actions = Dictionary(uniqueKeysWithValues: settings.quickActions.map { ($0.id, $0) })

        ZStack(alignment: .topLeading) {
            // Karten, Überschriften und Trennlinien: stehen fest, nur die Höhe passt sich an
            rowLabel(L("Top row", "Obere Reihe"), y: 0)
            rowLabel(L("Bottom row", "Untere Reihe"), y: rowTop(1, a) - Self.labelHeight)
            let d = displayCounts(a)
            card(count: d.top, top: rowTop(0, a), emptyHint: c.top == 0)
            card(count: d.bottom, top: rowTop(1, a), emptyHint: c.bottom == 0)

            // Zeilen: liegen frei über den Karten
            ForEach(settings.quickActions) { action in
                let isDragged = dragging == action.id
                ActionRow(action: action,
                          selected: selection == action.id,
                          lifted: isDragged,
                          dragging: dragging != nil,
                          onRemove: { onRemove(action) })
                    .frame(height: Self.rowHeight)
                    .offset(y: isDragged ? dragStartY + dragTranslation : y(of: action.id, in: a))
                    .zIndex(isDragged ? 2 : 1)
                    .onTapGesture { selection = selection == action.id ? nil : action.id }
                    .gesture(dragGesture(for: action))
                    .contextMenu { menu(for: action) }
            }
            .animation(nil, value: dragTranslation)
        }
        .frame(height: totalHeight(a), alignment: .top)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .coordinateSpace(name: Self.space)
        .onChange(of: actions.count) { _, _ in
            if let id = dragging, actions[id] == nil { endDrag(commit: false) }
        }
    }

    private func rowLabel(_ text: String, y: CGFloat) -> some View {
        Text(text)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.leading, 8)
            .frame(height: Self.labelHeight, alignment: .center)
            .offset(y: y)
    }

    /// Karte mit Trennlinien für `count` Zeilen; leer mit Hinweis zum Hineinziehen.
    private func card(count: Int, top: CGFloat, emptyHint: Bool) -> some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: SettingsTheme.cardRadius, style: .continuous)
                .fill(SettingsTheme.card)
            RoundedRectangle(cornerRadius: SettingsTheme.cardRadius, style: .continuous)
                .strokeBorder(SettingsTheme.cardBorder, lineWidth: 1)
            ForEach(1..<max(count, 1), id: \.self) { i in
                Rectangle()
                    .fill(SettingsTheme.separator)
                    .frame(height: 1)
                    .padding(.leading, SettingsTheme.rowPadding + 36)
                    .offset(y: CGFloat(i) * Self.pitch - 1)
            }
            if emptyHint {
                Text(L("Drag actions here", "Aktionen hierher ziehen"))
                    .font(.system(size: 12.5))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .frame(height: Self.rowHeight)
            }
        }
        .frame(height: cardHeight(count))
        .offset(y: top)
    }

    @ViewBuilder
    private func menu(for action: QuickAction) -> some View {
        let order = settings.quickActions
        Button(L("Move Up", "Nach oben")) { onMove(action, -1) }
            .disabled(order.first?.id == action.id)
        Button(L("Move Down", "Nach unten")) { onMove(action, 1) }
            .disabled(order.last?.id == action.id)
        Divider()
        Button(L("Remove", "Entfernen")) { onRemove(action) }
    }

    // MARK: Ziehen

    private func dragGesture(for action: QuickAction) -> some Gesture {
        DragGesture(minimumDistance: 2, coordinateSpace: .named(Self.space))
            .onChanged { g in
                if dragging != action.id {
                    dragging = action.id
                    dragStartY = y(of: action.id, in: committed)
                }
                // Nur innerhalb der Liste: von der ersten bis zur letzten Zeile
                // (mit zwei Reihen bis zum letzten Platz der unteren Reihe)
                let minTop = Self.labelHeight
                let maxTop = max(minTop, totalHeight(shown) - Self.rowHeight)
                let top = min(max(dragStartY + g.translation.height, minTop), maxTop)
                dragTranslation = top - dragStartY
                let next = propose(for: action.id, top: top)
                if next != shown {
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) { proposal = next }
                    Haptics.tap()   // eingerastet
                }
            }
            .onEnded { _ in endDrag(commit: true) }
    }

    private func endDrag(commit: Bool) {
        if commit, let proposal {
            // Ohne Animation speichern: Die Zeilen stehen schon an diesem Platz
            var t = Transaction()
            t.disablesAnimations = true
            withTransaction(t) {
                let byID = Dictionary(uniqueKeysWithValues: settings.quickActions.map { ($0.id, $0) })
                let order = proposal.order.compactMap { byID[$0] }
                if order.count == settings.quickActions.count {
                    settings.quickActions = order
                    settings.actionRowSplit = proposal.split
                }
            }
        }
        // Die gezogene Zeile gleitet auf ihren Platz
        withAnimation(.spring(response: 0.3, dampingFraction: 0.86)) {
            dragging = nil
            dragTranslation = 0
            proposal = nil
        }
    }
}

/// Eine Zeile der Aktionsliste.
private struct ActionRow: View {
    let action: QuickAction
    let selected: Bool
    let lifted: Bool
    /// Irgendeine Zeile wird gerade gezogen: dann keine Knöpfe einblenden
    let dragging: Bool
    let onRemove: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            QuickActionIcon(action: action, size: 26)
            VStack(alignment: .leading, spacing: 1) {
                Text(action.title)
                    .font(.system(size: 13.5))
                    .foregroundStyle(selected ? Color.white : Color.primary)
                    .lineLimit(1)
                Text(action.help)
                    .font(.system(size: 11))
                    .foregroundStyle(selected ? Color.white.opacity(0.8) : Color.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            // Entfernen direkt an der Zeile, sichtbar beim Darüberfahren
            Button(action: onRemove) {
                Image(systemName: "minus.circle.fill")
                    .font(.system(size: 15))
                    .foregroundStyle(selected ? Color.white.opacity(0.85) : Color.secondary)
                    .frame(width: 26, height: 40)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(L("Remove", "Entfernen"))
            .opacity(hovering && !dragging ? 1 : 0)
            .allowsHitTesting(hovering && !dragging)
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(selected ? Color.white.opacity(0.75) : Color.secondary.opacity(lifted ? 1 : 0.6))
                .frame(width: 30, height: 40)
                .contentShape(Rectangle())
                .help(L("Drag to reorder", "Zum Verschieben ziehen"))
        }
        .padding(.leading, SettingsTheme.rowPadding)
        .padding(.trailing, 6)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: lifted ? SettingsTheme.cardRadius : 8, style: .continuous)
                .fill(selected ? Color(nsColor: .controlAccentColor) : (lifted ? SettingsTheme.cardSolid : Color.clear))
                .padding(lifted ? 0 : 4)
        )
        .overlay(
            RoundedRectangle(cornerRadius: SettingsTheme.cardRadius, style: .continuous)
                .strokeBorder(SettingsTheme.cardBorder, lineWidth: lifted ? 1 : 0)
        )
        .shadow(color: .black.opacity(lifted ? 0.4 : 0), radius: 10, y: 4)
        .scaleEffect(lifted ? 1.02 : 1)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

/// Letzte Zeile unter der Aktionsliste: neue Aktion hinzufügen, wie in den Listen
/// der Systemeinstellungen. Ist die Leiste voll, steht das dort.
private struct AddActionRow: View {
    let count: Int
    let limit: Int
    @Binding var frame: CGRect
    let action: () -> Void

    var body: some View {
        let full = count >= limit
        AddListRow(title: full ? L("Action bar is full (\(count) of \(limit))", "Aktionsleiste ist voll (\(count) von \(limit))")
                               : L("Add Action", "Aktion hinzufügen"),
                   enabled: !full, frame: $frame, action: action)
    }
}

/// Eigene Karte unter einer Liste: Eintrag hinzufügen (Aktionen, ausgenommene Apps).
struct AddListRow: View {
    let title: String
    var enabled = true
    @Binding var frame: CGRect
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: "plus.circle.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(enabled ? Color(nsColor: .controlAccentColor) : Color.secondary)
                    .frame(width: 26)
                Text(title)
                    .font(.system(size: 13.5, weight: .medium))
                    .foregroundStyle(enabled ? Color(nsColor: .controlAccentColor) : Color.secondary)
                Spacer()
            }
            .padding(.horizontal, SettingsTheme.rowPadding)
            .frame(height: 44)
            .background(
                RoundedRectangle(cornerRadius: SettingsTheme.cardRadius, style: .continuous)
                    .fill(SettingsTheme.card.opacity(hovering && enabled ? 1 : 0.6))
            )
            .overlay(
                RoundedRectangle(cornerRadius: SettingsTheme.cardRadius, style: .continuous)
                    .strokeBorder(SettingsTheme.cardBorder, lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .onHover { hovering = $0 }
        .readFrame($frame)
    }
}

// MARK: Ausgenommene Apps

/// Eine ausgenommene App: Symbol, Name, Entfernen beim Darüberfahren.
private struct ExcludedAppRow: View {
    let bundleID: String
    let onRemove: () -> Void
    @State private var hovering = false

    private var appURL: URL? { NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) }

    private var name: String {
        guard let url = appURL else { return bundleID }
        return (FileManager.default.displayName(atPath: url.path) as NSString).deletingPathExtension
    }

    var body: some View {
        HStack(spacing: 10) {
            Group {
                if let url = appURL {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                        .resizable()
                        .interpolation(.high)
                } else {
                    Image(systemName: "app.dashed")
                        .font(.system(size: 18))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 24, height: 24)
            Text(name)
                .font(.system(size: 13.5))
                .lineLimit(1)
            Spacer(minLength: 8)
            Button(action: onRemove) {
                Image(systemName: "minus.circle.fill")
                    .font(.system(size: 15))
                    .foregroundStyle(Color.secondary)
                    .frame(width: 26, height: 30)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(L("Remove", "Entfernen"))
            .opacity(hovering ? 1 : 0)
            .allowsHitTesting(hovering)
        }
        .padding(.horizontal, SettingsTheme.rowPadding)
        .frame(height: 44)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .contextMenu {
            Button(L("Remove", "Entfernen"), action: onRemove)
        }
    }
}

/// Letzte Zeile der Liste: App hinzufügen, aus den laufenden Apps oder per Auswahl.
private struct AddExcludedAppRow: View {
    @ObservedObject var settings: AppSettings
    @State private var frame: CGRect = .zero

    var body: some View {
        AddListRow(title: L("Add App", "App hinzufügen"), frame: $frame, action: showMenu)
    }

    private func showMenu() {
        let menu = NSMenu()
        let own = Bundle.main.bundleIdentifier
        // Nur die zuletzt gestarteten Apps vorschlagen, sonst wird das Menü zu lang;
        // alle anderen über „Andere App wählen“
        let running = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .sorted { ($0.launchDate ?? .distantPast) > ($1.launchDate ?? .distantPast) }
            .compactMap { app -> (id: String, name: String, icon: NSImage?)? in
                guard let id = app.bundleIdentifier, id != own, !settings.excludedApps.contains(id) else { return nil }
                return (id, app.localizedName ?? id, app.icon)
            }
            .prefix(8)
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        for app in running {
            let item = ClosureMenuItem(app.name) { add(app.id) }
            if let icon = app.icon?.copy() as? NSImage {
                icon.size = NSSize(width: 16, height: 16)
                item.image = icon
            }
            menu.addItem(item)
        }
        if !running.isEmpty { menu.addItem(.separator()) }
        menu.addItem(ClosureMenuItem(L("Choose Another App", "Andere App wählen")) { choose() })
        MenuPresenter.show(menu, below: frame)
    }

    private func add(_ id: String) {
        guard !settings.excludedApps.contains(id) else { return }
        withAnimation(.spring(response: 0.3, dampingFraction: 0.88)) {
            settings.excludedApps.append(id)
        }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.prompt = L("Add", "Hinzufügen")
        panel.message = L("Choose apps in which the shelf doesn’t open at the edge.",
                          "Wähl Apps, in denen sich die Ablage am Rand nicht öffnet.")
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            if let id = Bundle(url: url)?.bundleIdentifier { add(id) }
        }
    }
}
