import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Einstellungen → Plugins: oben der Hauptschalter, darunter die installierten Plugins
/// (zuerst die Standard-Plugins, dann eigene), ganz unten „Plugin importieren“.
struct PluginSettings: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject private var manager: PluginManager
    @State private var expanded: String?
    @State private var importFrame: CGRect = .zero

    /// `manager` und `expanded` nur für Tests und Vorschaubilder
    init(settings: AppSettings, manager: PluginManager = .shared, expanded: String? = nil) {
        self.settings = settings
        self.manager = manager
        _expanded = State(initialValue: expanded)
    }

    var body: some View {
        SettingsPage {
            SettingsSection(note: L("Plugins add their own entries to the right-click menu and the action bar, or run when you drop matching items. BarDrop doesn’t come with any plugin. When you turn this on, BarDrop loads the standard plugins from its catalog; they stay off until you turn them on.",
                                    "Plugins ergänzen eigene Einträge im Rechtsklick und in der Aktionsleiste oder laufen beim Ablegen passender Objekte. BarDrop bringt selbst kein Plugin mit. Beim Einschalten lädt BarDrop die Standard-Plugins aus seinem Katalog; sie bleiben aus, bis du sie einschaltest.")) {
                ToggleRow(L("Use plugins", "Plugins verwenden"), isOn: $settings.pluginsEnabled)
            }

            if settings.pluginsEnabled {
                installed
                if !manager.catalogExtras.isEmpty { more }
                AddListRow(title: L("Import Plugin", "Plugin importieren"), frame: $importFrame) {
                    PluginImporter.chooseAndImport()
                }
                SectionNote(L("You can also double-click a .bdrop file. Plugins that aren’t from the catalog show a warning and their script first.",
                              "Du kannst auch eine .bdrop-Datei doppelklicken. Plugins, die nicht aus dem Katalog stammen, zeigen vorher eine Warnung und ihr Skript."))
                    .padding(.horizontal, 8)
            }
        }
        .onAppear {
            // Bearbeitete Skripte erkennen; Katalog abgleichen, wenn es länger her ist
            manager.reload()
            manager.syncCatalog()
        }
    }

    // MARK: Installiert

    @ViewBuilder
    private var installed: some View {
        VStack(alignment: .leading, spacing: 8) {
            SettingsHeader(L("Installed", "Installiert"),
                           info: L("When several plugins run automatically for the same item, only the first one in this list runs. Use the arrows to change the order.",
                                   "Passen mehrere automatische Plugins zum selben Objekt, läuft nur das erste in dieser Liste. Mit den Pfeilen änderst du die Reihenfolge.")) {
                if manager.syncing {
                    ProgressView().controlSize(.small)
                }
            }
            .padding(.horizontal, 8)

            if manager.plugins.isEmpty && manager.missingStandard.isEmpty && manager.broken.isEmpty {
                SettingsCard {
                    HStack(spacing: 10) {
                        Image(systemName: "puzzlepiece.extension")
                            .font(.system(size: 18))
                            .foregroundStyle(.secondary)
                            .frame(width: 26)
                        Text(manager.syncFailed
                             ? L("The catalog couldn’t be loaded. Check your internet connection.",
                                 "Der Katalog ließ sich nicht laden. Prüf die Internetverbindung.")
                             : L("No plugins installed yet.", "Noch keine Plugins installiert."))
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 8)
                        if manager.syncFailed {
                            Button(L("Try Again", "Erneut versuchen")) { manager.syncCatalog(force: true) }
                                .buttonStyle(KlackButtonStyle())
                        }
                    }
                    .padding(.horizontal, SettingsTheme.rowPadding)
                    .frame(minHeight: SettingsTheme.rowHeight)
                }
            } else {
                SettingsCard {
                    ForEach(manager.plugins) { plugin in
                        PluginRow(plugin: plugin, manager: manager, settings: settings,
                                  expanded: Binding(get: { expanded == plugin.id },
                                                    set: { open in withAnimation(.easeInOut(duration: 0.2)) {
                                                        expanded = open ? plugin.id : nil
                                                    } }))
                    }
                    ForEach(manager.missingStandard) { entry in
                        MissingPluginRow(entry: entry) { manager.syncCatalog(force: true) }
                    }
                    ForEach(manager.broken.keys.sorted(), id: \.self) { id in
                        BrokenPluginRow(id: id, message: manager.broken[id] ?? "")
                    }
                }
            }
        }
    }

    // MARK: Weitere aus dem Katalog

    private var more: some View {
        SettingsSection(L("More in the catalog", "Mehr im Katalog")) {
            ForEach(manager.catalogExtras) { entry in
                CatalogRow(entry: entry, manager: manager)
            }
        }
    }
}

// MARK: Eine Zeile je Plugin

private struct PluginRow: View {
    let plugin: InstalledPlugin
    @ObservedObject var manager: PluginManager
    @ObservedObject var settings: AppSettings
    @Binding var expanded: Bool

    private var state: PluginState { manager.state(plugin.id) }

    private var enabled: Binding<Bool> {
        Binding(get: { state.enabled }, set: { on in
            if on, !PluginDialogs.confirmConsent(plugin, manager: manager, ui: nil) { return }
            manager.update(plugin.id) { $0.enabled = on }
        })
    }

    private var subtitle: String {
        if let description = plugin.manifest.description?.text, !description.isEmpty { return description }
        return L("Version \(plugin.manifest.version)", "Version \(plugin.manifest.version)")
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Button {
                    expanded.toggle()
                } label: {
                    HStack(spacing: 10) {
                        PluginIconView(icon: plugin.manifest.icon, size: 26)
                        VStack(alignment: .leading, spacing: 1) {
                            HStack(spacing: 6) {
                                Text(plugin.manifest.name.text)
                                    .font(.system(size: 13.5))
                                    .lineLimit(1)
                                if plugin.isStandard {
                                    Badge(L("Standard", "Standard"))
                                }
                            }
                            Text(subtitle)
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 8)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .rotationEffect(.degrees(expanded ? 90 : 0))
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                KlackSwitch(isOn: enabled)
            }
            .padding(.horizontal, SettingsTheme.rowPadding)
            .frame(minHeight: 52)

            if expanded {
                PluginDetails(plugin: plugin, manager: manager, settings: settings)
                    .transition(.opacity)
            }
        }
    }
}

/// Aufgeklappt: Auslöser, Einstellungen des Plugins, Rechte und Skript
private struct PluginDetails: View {
    let plugin: InstalledPlugin
    @ObservedObject var manager: PluginManager
    @ObservedObject var settings: AppSettings

    private var state: PluginState { manager.state(plugin.id) }
    private var manifest: PluginManifest { plugin.manifest }

    private var automatic: Binding<Bool> {
        Binding(get: { manager.isAutomatic(plugin) }, set: { on in
            // Rechte und Zustimmung jetzt erfragen, damit beim Ablegen nichts aufspringt
            if on, !PluginDialogs.prepareAutomatic(plugin, manager: manager) { return }
            manager.update(plugin.id) { $0.automatic = on }
        })
    }

    private var replace: Binding<Bool> {
        Binding(get: { state.replaceOriginal }, set: { on in manager.update(plugin.id) { $0.replaceOriginal = on } })
    }

    private var inActionBar: Binding<Bool> {
        Binding(get: { settings.quickActions.contains { $0.kind == .plugin && $0.path == plugin.id } },
                set: { on in
                    if on {
                        guard settings.quickActions.count < QuickAction.limit(twoRows: settings.twoActionRows) else { return NSSound.beep() }
                        settings.quickActions.append(QuickAction(kind: .plugin, path: plugin.id))
                    } else {
                        settings.quickActions.removeAll { $0.kind == .plugin && $0.path == plugin.id }
                    }
                })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            divider
            if manifest.allTriggers.contains(.automatic) {
                ToggleRow(L("Automatically when dropped", "Automatisch beim Ablegen"),
                          info: L("Runs as soon as you drop a matching item. Permissions are asked when you turn this on.",
                                  "Läuft, sobald du ein passendes Objekt ablegst. Die Rechte werden beim Einschalten erfragt."),
                          isOn: automatic)
                divider
            }
            if manifest.allTriggers.contains(.action) {
                ToggleRow(L("In the action bar", "In der Aktionsleiste"), isOn: inActionBar)
                divider
            }
            if manifest.canReplaceOriginal == true {
                ToggleRow(L("Replace original", "Original ersetzen"),
                          info: L("The result takes the place of the original in the shelf. The original file itself stays where it is; ⌘Z brings it back into the shelf.",
                                  "Das Ergebnis nimmt den Platz des Originals in der Ablage ein. Die Originaldatei selbst bleibt, wo sie ist; ⌘Z holt sie zurück in die Ablage."),
                          isOn: replace)
                divider
            }
            ForEach(manifest.settings ?? []) { spec in
                PluginSettingRow(spec: spec, plugin: plugin, manager: manager)
                divider
            }
            if let error = manager.lastErrors[plugin.id] {
                SettingsRow(L("Last error", "Letzter Fehler"), subtitle: error) {
                    Button(L("Copy", "Kopieren")) {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(error, forType: .string)
                    }
                    .buttonStyle(KlackButtonStyle())
                }
                divider
            }
            SettingsRow(L("Works with", "Passt zu")) {
                Text(PluginSummary.matches(manifest.match))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.trailing)
                    .lineLimit(2)
            }
            if !manifest.allPermissions.isEmpty {
                divider
                SettingsRow(L("Permissions", "Rechte"),
                            subtitle: manifest.allPermissions.map { permission in
                                permission.title + ": " + (manager.isGranted(permission, for: plugin)
                                                           ? L("allowed", "erlaubt") : L("asks first", "fragt zuerst"))
                            }.joined(separator: " · ")) {
                    Button(L("Reset", "Zurücksetzen")) { manager.revokePermissions(plugin.id) }
                        .buttonStyle(KlackButtonStyle())
                        .disabled(state.granted.isEmpty)
                }
            }
            divider
            HStack(spacing: 8) {
                Text([plugin.manifest.version, plugin.manifest.author].compactMap { $0 }.joined(separator: " · "))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Button { manager.move(plugin.id, by: -1) } label: { Image(systemName: "chevron.up") }
                    .buttonStyle(KlackButtonStyle())
                    .help(L("Move up", "Nach oben"))
                Button { manager.move(plugin.id, by: 1) } label: { Image(systemName: "chevron.down") }
                    .buttonStyle(KlackButtonStyle())
                    .help(L("Move down", "Nach unten"))
                Button(L("Script", "Skript")) { ScriptViewer.show(plugin) }
                    .buttonStyle(KlackButtonStyle())
                if !plugin.isStandard {
                    Button(L("Remove", "Entfernen")) { confirmRemove() }
                        .buttonStyle(KlackButtonStyle(destructive: true))
                }
            }
            .padding(.horizontal, SettingsTheme.rowPadding)
            .frame(minHeight: SettingsTheme.rowHeight)
        }
        .background(Color.primary.opacity(0.02))
    }

    private var divider: some View {
        Rectangle().fill(SettingsTheme.separator).frame(height: 1)
    }

    private func confirmRemove() {
        let alert = PluginDialogs.makeAlert(manifest)
        alert.messageText = L("Remove “\(manifest.name.text)”?", "„\(manifest.name.text)“ entfernen?")
        alert.informativeText = L("The plugin and its settings are deleted. Items in the shelf stay.",
                                  "Das Plugin und seine Einstellungen werden gelöscht. Die Objekte in der Ablage bleiben.")
        alert.addButton(withTitle: L("Remove", "Entfernen"))
        alert.addButton(withTitle: L("Cancel", "Abbrechen"))
        alert.buttons.first?.hasDestructiveAction = true
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        withAnimation(.spring(response: 0.3, dampingFraction: 0.88)) { manager.remove(plugin.id) }
    }
}

/// Einstellung aus dem Manifest: Schalter, Auswahl oder Textfeld
private struct PluginSettingRow: View {
    let spec: PluginSettingSpec
    let plugin: InstalledPlugin
    @ObservedObject var manager: PluginManager

    private var value: PluginValue { manager.value(spec, of: plugin.id) }

    private func set(_ new: PluginValue) {
        manager.update(plugin.id) { $0.values[spec.key] = new }
    }

    var body: some View {
        switch spec.type {
        case .toggle:
            ToggleRow(spec.title.text, info: spec.info?.text,
                      isOn: Binding(get: { value.bool }, set: { set(.bool($0)) }))
        case .choice:
            PickerRow(spec.title.text, info: spec.info?.text,
                      selection: Binding(get: { value.string }, set: { set(.string($0)) }),
                      options: (spec.options ?? []).map { ($0.value, $0.title.text) })
        case .text:
            SettingsRow(spec.title.text, info: spec.info?.text) {
                TextField("", text: Binding(get: { value.string }, set: { set(.string($0)) }))
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 180)
            }
        }
    }
}

/// Standard-Plugin, das gerade nicht geladen werden konnte (z. B. ohne Internet)
private struct MissingPluginRow: View {
    let entry: PluginCatalogEntry
    let retry: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            PluginIconView(icon: entry.icon, size: 26)
                .opacity(0.5)
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.name.text)
                    .font(.system(size: 13.5))
                Text(L("Not loaded", "Nicht geladen"))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Button(L("Try Again", "Erneut versuchen"), action: retry)
                .buttonStyle(KlackButtonStyle())
        }
        .padding(.horizontal, SettingsTheme.rowPadding)
        .frame(minHeight: 52)
    }
}

/// Installiertes Plugin, das sich nicht mehr lesen lässt (z. B. nach dem Bearbeiten)
private struct BrokenPluginRow: View {
    let id: String
    let message: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 16))
                .foregroundStyle(.orange)
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 1) {
                Text(id)
                    .font(.system(size: 13.5))
                    .lineLimit(1)
                Text(message)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 8)
        }
        .padding(.horizontal, SettingsTheme.rowPadding)
        .frame(minHeight: 52)
    }
}

/// Weiteres Plugin im Katalog, mit „Laden“
private struct CatalogRow: View {
    let entry: PluginCatalogEntry
    @ObservedObject var manager: PluginManager
    @State private var loading = false
    @State private var failed = false

    var body: some View {
        HStack(spacing: 10) {
            PluginIconView(icon: entry.icon, size: 26)
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.name.text)
                    .font(.system(size: 13.5))
                Text(failed ? L("Loading didn’t work", "Laden hat nicht geklappt") : (entry.description?.text ?? entry.version))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            if loading {
                ProgressView().controlSize(.small)
            } else {
                Button(L("Get", "Laden")) {
                    loading = true
                    manager.installFromCatalog(entry) { ok in
                        loading = false
                        failed = !ok
                    }
                }
                .buttonStyle(KlackButtonStyle())
            }
        }
        .padding(.horizontal, SettingsTheme.rowPadding)
        .frame(minHeight: 52)
    }
}

private struct Badge: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 1.5)
            .background(Capsule().fill(Color.primary.opacity(0.07)))
            .overlay(Capsule().strokeBorder(SettingsTheme.separator, lineWidth: 1))
    }
}

/// Lesbare Kurzfassung, wofür ein Plugin zuständig ist
enum PluginSummary {
    static func matches(_ match: PluginMatch) -> String {
        var parts: [String] = []
        for identifier in match.types ?? [] {
            let name = UTType(identifier)?.localizedDescription ?? identifier
            parts.append(name.prefix(1).uppercased() + name.dropFirst())
        }
        if let ext = match.extensions, !ext.isEmpty {
            parts.append(ext.map { "." + $0.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".")) }.joined(separator: " "))
        }
        if let hosts = match.links?.hosts, !hosts.isEmpty {
            parts.append(hosts.contains("*") ? L("all links", "alle Links") : L("links: ", "Links: ") + hosts.joined(separator: ", "))
        }
        if !(match.links?.patterns ?? []).isEmpty, (match.links?.hosts ?? []).isEmpty {
            parts.append(L("some links", "bestimmte Links"))
        }
        return parts.joined(separator: " · ")
    }
}
