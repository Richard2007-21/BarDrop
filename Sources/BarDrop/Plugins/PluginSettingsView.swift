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
                                    "Plugins ergänzen eigene Einträge im Rechtsklick-Menü und in der Aktionsleiste oder laufen beim Ablegen passender Objekte. BarDrop bringt selbst kein Plugin mit. Beim Einschalten lädt BarDrop die Standard-Plugins aus seinem Katalog; sie bleiben aus, bis du sie einschaltest.")) {
                ToggleRow(L("Use plugins", "Plugins verwenden"), isOn: $settings.pluginsEnabled)
            }

            if settings.pluginsEnabled {
                installed
                if !manager.catalogExtras.isEmpty { more }
                AddListRow(title: L("Import Plugin", "Plugin importieren"), frame: $importFrame) {
                    PluginImporter.chooseAndImport()
                }
                SectionNote(L("You can also double-click a .bdrop file. Plugins that aren’t from the catalog show a warning first, and you can look at their script.",
                              "Du kannst auch eine .bdrop-Datei doppelklicken. Plugins, die nicht aus dem Katalog stammen, zeigen vorher eine Warnung, und du kannst dir ihr Skript ansehen."))
                    .padding(.horizontal, 8)

                SettingsSection(L("Log", "Protokoll"),
                                note: L("Its own file, separate from the diagnostic log of BarDrop. It names files and error messages and stays on this Mac.",
                                        "Eine eigene Datei, getrennt vom Diagnoseprotokoll von BarDrop. Sie nennt Dateinamen und Fehlermeldungen und bleibt auf diesem Mac.")) {
                    ToggleRow(L("Keep a plugin log", "Plugin-Protokoll führen"),
                              info: L("Records which plugin runs and when, what works and what fails: permissions, downloaded programs, started programs with their result, internet requests and the plugin’s own log lines.",
                                      "Hält fest, welches Plugin wann läuft, was klappt und was fehlschlägt: Rechte, geladene Programme, gestartete Programme mit ihrem Ergebnis, Anfragen ins Internet und eigene Zeilen des Plugins."),
                              isOn: $settings.pluginLogEnabled)
                    SettingsRow(L("Log file", "Protokolldatei")) {
                        HStack(spacing: 6) {
                            Button(L("Show", "Zeigen")) { PluginLog.shared.reveal() }
                                .buttonStyle(KlackButtonStyle())
                            Button(L("Clear", "Leeren")) { PluginLog.shared.clear() }
                                .buttonStyle(KlackButtonStyle())
                        }
                    }
                }
            }
        }
        .onAppear {
            // Bearbeitete Skripte erkennen; Katalog abgleichen, wenn es länger her ist
            manager.reload()
            manager.syncCatalog(maxAge: 3600)
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
                                 "Der Katalog ließ sich nicht laden. Prüf deine Internetverbindung.")
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
                        BrokenPluginRow(id: id, message: manager.broken[id] ?? "", manager: manager)
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
            // Einschalten: was noch fehlt, gleich hier in einem Fenster, nicht beim ersten Lauf
            if on, !PluginDialogs.authorize(plugin, manager: manager, ui: nil) { return }
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

    /// Namen der Programme und, nach „Aktualisieren“, wie es ausging
    private func toolSubtitle(_ tools: [PluginTool]) -> String {
        let names = tools.map(\.id).joined(separator: ", ")
        switch manager.toolRefresh[plugin.id] {
        case .running: return names + " · " + L("updating", "wird aktualisiert")
        case .done: return names + " · " + L("up to date", "aktualisiert")
        case .failed(let message): return names + " · " + message
        case nil: return names
        }
    }

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
                        guard settings.quickActions.count < QuickAction.limit else { return NSSound.beep() }
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
                          info: L("Runs as soon as you drop a matching item. Permissions and programs the plugin needs are asked for when you turn this on, so nothing pops up when you drop.",
                                  "Läuft, sobald du ein passendes Objekt ablegst. Rechte und Programme, die das Plugin braucht, werden beim Einschalten erfragt, damit beim Ablegen nichts aufspringt."),
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
            if let tools = manifest.tools, !tools.isEmpty, tools.contains(where: { state.approvedTools.contains($0.approvalKey) }) {
                SettingsRow(L("Programs", "Programme"), subtitle: toolSubtitle(tools)) {
                    Button(L("Update", "Aktualisieren")) { manager.refreshTools(of: plugin) }
                        .buttonStyle(KlackButtonStyle())
                        .disabled(manager.toolRefresh[plugin.id] == .running)
                        .help(L("Downloads the plugin’s programs again, for example when a newer version fixes an error.",
                                "Lädt die Programme des Plugins neu, etwa wenn eine neuere Fassung einen Fehler behebt."))
                }
                divider
            }
            if let count = manager.runningCounts[plugin.id], count > 0 {
                SettingsRow(L("Running", "Läuft gerade"),
                            subtitle: count == 1 ? L("1 run", "1 Lauf") : L("\(count) runs", "\(count) Läufe")) {
                    Button(L("Stop", "Beenden")) { manager.stopRuns?(plugin.id) }
                        .buttonStyle(KlackButtonStyle())
                        .help(L("Ends all runs of this plugin, also a script that is stuck.",
                                "Beendet alle Läufe dieses Plugins, auch ein Skript, das hängt."))
                }
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
            // Offline oder mit dem Internet: auf einen Blick, ohne die Rechte lesen zu müssen
            let connectivity = PluginConnectivity(permissions: manifest.allPermissions,
                                                  tools: (manifest.tools ?? []).map(\.name))
            SettingsRow(L("Internet", "Internet")) {
                Label(connectivity.text, systemImage: connectivity.symbol)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            divider
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
                    HStack(spacing: 6) {
                        if !manifest.allPermissions.allSatisfy({ manager.isGranted($0, for: plugin) }) {
                            // Hervorgehoben: Ohne Erlaubnis läuft das Plugin nicht, der Knopf soll auffallen
                            Button(L("Allow", "Erlauben")) { _ = PluginDialogs.prepareAutomatic(plugin, manager: manager) }
                                .buttonStyle(KlackButtonStyle(prominent: true))
                                .help(L("Asks for all permissions now, for example for automatic runs.",
                                        "Fragt jetzt nach allen Rechten, zum Beispiel für automatische Läufe."))
                        }
                        Button(L("Reset", "Zurücksetzen")) { manager.revokePermissions(plugin.id) }
                            .buttonStyle(KlackButtonStyle())
                            .disabled(state.granted.isEmpty)
                    }
                }
            }
            divider
            HStack(spacing: 8) {
                // Version, Autor und Platz auf dem Mac (mit geladenen Programmen)
                Text([plugin.manifest.version, plugin.manifest.author, PluginSize.summary(of: plugin, tools: manager.tools)]
                        .compactMap { $0 }.joined(separator: " · "))
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
    @ObservedObject var manager: PluginManager

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
            Button(L("Show in Finder", "Im Finder zeigen")) {
                NSWorkspace.shared.activateFileViewerSelecting([manager.folder(of: id)])
            }
            .buttonStyle(KlackButtonStyle())
            if !manager.state(id).isStandard {
                Button(L("Remove", "Entfernen")) { manager.removeBroken(id) }
                    .buttonStyle(KlackButtonStyle(destructive: true))
            }
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
                    .lineLimit(2)
                if !failed, let details = CatalogRow.details(entry) {
                    Text(details)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
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

extension CatalogRow {
    /// Zweite Zeile: zuerst, ob das Plugin offline bleibt, dann Kategorie und Autor
    static func details(_ entry: PluginCatalogEntry) -> String? {
        var parts: [String] = []
        // Nur bekannt, wenn der Katalog die Rechte nennt (ältere Einträge: nichts behaupten)
        if let permissions = entry.permissions {
            parts.append(PluginConnectivity(permissions: permissions.compactMap(PluginPermission.init(rawValue:)),
                                            tools: entry.tools ?? []).short)
        }
        if let size = PluginSize.catalogText(entry) { parts.append(size) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

/// Braucht ein Plugin das Internet? Aus seinen Rechten und Programmen abgeleitet:
/// Ohne `network` kann das Skript selbst keine Verbindung aufbauen; Programme aus `tools`
/// werden einmal geladen (ein mit `run` gestartetes Programm könnte trotzdem ins Netz).
struct PluginConnectivity {
    let permissions: [PluginPermission]
    let tools: [String]

    var usesNetwork: Bool { permissions.contains(.network) }

    var text: String {
        if usesNetwork { return L("Connects to the internet", "Verbindet sich mit dem Internet") }
        if !tools.isEmpty {
            return L("Downloads \(tools.joined(separator: ", ")) once, then offline",
                     "Lädt einmal \(tools.joined(separator: ", ")), dann offline")
        }
        return L("Works offline", "Funktioniert offline")
    }

    /// Kurz für die Zeilen der Galerie
    var short: String {
        if usesNetwork { return L("Internet", "Internet") }
        if !tools.isEmpty { return L("Downloads a program once", "Lädt einmal ein Programm") }
        return L("Offline", "Offline")
    }

    var symbol: String {
        if usesNetwork { return "globe" }
        return tools.isEmpty ? "wifi.slash" : "arrow.down.circle"
    }
}

/// Größe eines Plugins: eigene Dateien und die Programme, die es geladen hat
enum PluginSize {
    static func text(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    static func folder(_ url: URL) -> Int64 {
        let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .fileSizeKey, .isRegularFileKey]
        guard let walker = FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys) else { return 0 }
        var total: Int64 = 0
        for case let file as URL in walker {
            guard let v = try? file.resourceValues(forKeys: Set(keys)), v.isRegularFile == true else { continue }
            total += Int64(v.totalFileAllocatedSize ?? v.fileSize ?? 0)
        }
        return total
    }

    /// Installiert, getrennt: „Plugin 38 KB · Programme 92 MB“ (nur „Plugin …“ ohne
    /// Programme; „Programme noch nicht geladen“, solange sie fehlen)
    static func summary(of plugin: InstalledPlugin, tools: PluginTools) -> String {
        let own = L("Plugin ", "Plugin ") + text(folder(plugin.directory))
        let declared = plugin.manifest.tools ?? []
        guard !declared.isEmpty else { return own }
        let installed = declared.compactMap { tools.installed($0) }
        guard !installed.isEmpty else { return own + " · " + L("programs not downloaded yet", "Programme noch nicht geladen") }
        let programs = installed.reduce(Int64(0)) { $0 + folder($1.deletingLastPathComponent()) }
        return own + " · " + programsLabel(declared.count) + " " + text(programs)
    }

    /// Galerie, vor dem Laden: „14 KB“ oder „8 KB · Programm 61 MB“
    static func catalogText(_ entry: PluginCatalogEntry) -> String? {
        guard let size = entry.size else { return nil }
        let count = entry.tools?.count ?? 0
        guard count > 0 else { return text(Int64(size)) }
        let programs = entry.toolsSize.map { text(Int64($0)) } ?? L("size unknown", "Größe unbekannt")
        return text(Int64(size)) + " · " + programsLabel(count) + " " + programs
    }

    private static func programsLabel(_ count: Int) -> String {
        count == 1 ? L("Program", "Programm") : L("Programs", "Programme")
    }
}

/// Kategorien der Galerie (Werte in index.json)
enum PluginCategory {
    static let all = ["images", "links", "documents", "text", "media", "files", "other"]

    static func title(_ key: String) -> String? {
        switch key {
        case "images": return L("Images", "Bilder")
        case "links": return L("Links and web", "Links und Web")
        case "documents": return L("Documents", "Dokumente")
        case "text": return L("Text", "Text")
        case "media": return L("Audio and video", "Audio und Video")
        case "files": return L("Files", "Dateien")
        case "other": return L("Other", "Sonstiges")
        default: return nil
        }
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
    /// Häufige Typen in der Sprache der App; sonst die Kennung selbst (die Beschreibung
    /// des Systems käme in der Sprache von macOS, nicht der von BarDrop)
    static func typeName(_ identifier: String) -> String {
        switch identifier {
        case "public.image": return L("Images", "Bilder")
        case "public.movie", "public.video", "public.audiovisual-content": return L("Videos", "Videos")
        case "public.audio": return L("Audio", "Audio")
        case "com.adobe.pdf": return "PDF"
        case "public.text", "public.plain-text": return L("Text", "Text")
        case "public.folder", "public.directory": return L("Folders", "Ordner")
        case "public.archive", "public.zip-archive": return L("Archives", "Archive")
        case "public.url", "com.apple.web-internet-location": return L("Links", "Links")
        case "public.data", "public.item", "public.content": return L("All files", "Alle Dateien")
        default: return identifier
        }
    }

    static func matches(_ match: PluginMatch) -> String {
        var parts: [String] = []
        for identifier in match.types ?? [] {
            parts.append(typeName(identifier))
        }
        if let ext = match.extensions, !ext.isEmpty {
            parts.append(ext.map { "." + $0.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".")) }.joined(separator: " "))
        }
        if let hosts = match.links?.hosts, !hosts.isEmpty {
            parts.append(hosts.contains("*") ? L("All links", "Alle Links") : L("Links: ", "Links: ") + hosts.joined(separator: ", "))
        }
        if !(match.links?.patterns ?? []).isEmpty, (match.links?.hosts ?? []).isEmpty {
            parts.append(L("Some links", "Bestimmte Links"))
        }
        return parts.joined(separator: " · ")
    }
}
