import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Unterseiten von Einstellungen → Plugins, wie in den Systemeinstellungen von macOS:
/// Die Liste ist die Startseite; jede Unterseite zeigt oben in der Titelzeile einen
/// Zurück-Knopf und ihren eigenen Titel (`PluginPageHeader`).
enum PluginPage: Hashable {
    case list
    case plugin(String)
    case permissions(String)
    case gallery
    case order

    /// Wohin „Zurück“ führt
    var parent: PluginPage {
        switch self {
        case .permissions(let id): return .plugin(id)
        default: return .list
        }
    }

    func title(_ manager: PluginManager) -> String {
        switch self {
        case .list: return SettingsPane.plugins.title
        case .plugin(let id): return manager.plugin(id)?.manifest.name.text ?? SettingsPane.plugins.title
        case .permissions: return L("Permissions", "Rechte")
        case .gallery: return L("More Plugins", "Weitere Plugins")
        case .order: return L("Order When Dropped", "Reihenfolge beim Ablegen")
        }
    }
}

/// Titelzeile einer Unterseite: runder Zurück-Knopf und der Titel der Seite (statt des
/// Symbols und „Plugins“). Esc führt ebenfalls zurück.
struct PluginPageHeader: View {
    @ObservedObject var navigation: SettingsNavigation
    @ObservedObject var manager: PluginManager = .shared
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            Button(action: back) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 28, height: 28)
                    .background(Circle().fill(Color.primary.opacity(hovering ? 0.12 : 0.07)))
                    .overlay(Circle().strokeBorder(SettingsTheme.separator, lineWidth: 0.5))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            .keyboardShortcut(.cancelAction)
            .help(L("Back", "Zurück"))
            .accessibilityLabel(L("Back", "Zurück"))
            // Liegt in der Titelleiste: Klicks kommen über das Fenster an
            .background(GeometryReader { g in
                Color.clear
                    .onAppear { register(g.frame(in: .global)) }
                    .onChange(of: g.frame(in: .global)) { _, frame in register(frame) }
            })
            .onDisappear { SettingsNSWindow.titlebarButtons["back"] = nil }
            // Plugins haben ein Symbol: dann wie bei den Bereichen davor
            if case .plugin(let id) = navigation.pluginPage, let plugin = manager.plugin(id) {
                PluginIconView(icon: plugin.manifest.icon, size: 24)
            }
            Text(navigation.pluginPage.title(manager))
                .font(.system(size: 17, weight: .semibold))
                .lineLimit(1)
        }
    }

    private func back() {
        withAnimation(.easeInOut(duration: 0.18)) { navigation.pluginBack() }
    }

    private func register(_ frame: CGRect) {
        let navigation = navigation
        SettingsNSWindow.titlebarButtons["back"] = (frame.insetBy(dx: -4, dy: -4), {
            withAnimation(.easeInOut(duration: 0.18)) { navigation.pluginBack() }
        })
    }
}

/// Einstellungen → Plugins. Startseite: Hauptschalter, die installierten Plugins (Zeile mit
/// „Ein“/„Aus“ und Pfeil), „Plugin importieren“, „Weitere Plugins“ und das Protokoll.
struct PluginSettings: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject private var manager: PluginManager
    @ObservedObject private var navigation: SettingsNavigation

    /// `manager` und `navigation` nur für Tests und Vorschaubilder
    init(settings: AppSettings, manager: PluginManager = .shared, navigation: SettingsNavigation = .shared) {
        self.settings = settings
        self.manager = manager
        self.navigation = navigation
    }

    private var page: PluginPage { navigation.pluginPage }

    var body: some View {
        SettingsPage {
            switch page {
            case .list:
                start
            case .plugin(let id):
                if let plugin = manager.plugin(id) {
                    PluginPageView(plugin: plugin, manager: manager, settings: settings, open: open)
                } else {
                    // Entfernt oder nicht mehr lesbar: zurück zur Liste
                    start.onAppear { navigation.pluginPage = .list }
                }
            case .permissions(let id):
                if let plugin = manager.plugin(id) {
                    PluginPermissionsPage(plugin: plugin, manager: manager)
                } else {
                    start.onAppear { navigation.pluginPage = .list }
                }
            case .gallery:
                GalleryPage(manager: manager) { id in open(.plugin(id)) }
            case .order:
                PluginOrderPage(manager: manager)
            }
        }
        .id(page)
        .onAppear {
            // Bearbeitete Skripte erkennen; Katalog abgleichen, wenn es länger her ist
            manager.reload()
            manager.syncCatalog(maxAge: 3600)
        }
    }

    private func open(_ next: PluginPage) {
        withAnimation(.easeInOut(duration: 0.18)) { navigation.openPluginPage(next) }
    }

    // MARK: Startseite

    /// Plugin-Protokoll ein: erst nach dem Hinweis, was erfasst wird (wie beim
    /// Diagnoseprotokoll); aus: Protokoll gelöscht
    private var pluginLog: Binding<Bool> {
        Binding(get: { settings.pluginLogEnabled }, set: { on in
            if on {
                guard PluginLog.confirm() else { return }
                settings.pluginLogEnabled = true
            } else {
                settings.pluginLogEnabled = false
                PluginLog.shared.clear()
            }
        })
    }

    private var nothingInstalled: Bool {
        manager.plugins.isEmpty && manager.missingStandard.isEmpty && manager.broken.isEmpty
    }

    @ViewBuilder
    private var start: some View {
        SettingsSection(note: settings.pluginsEnabled ? nil
                        : L("Plugins are small add-ons that teach BarDrop new things, such as shrinking images, reading text from screenshots or converting files. They show up in the right-click menu and the action bar, or run by themselves when you drop something.",
                            "Plugins sind kleine Erweiterungen, die BarDrop Neues beibringen: etwa Bilder verkleinern, Text aus Bildschirmfotos lesen oder Dateien umwandeln. Sie erscheinen im Rechtsklick-Menü und in der Aktionsleiste oder laufen von selbst, wenn du etwas ablegst.")) {
            ToggleRow(L("Use plugins", "Plugins verwenden"), isOn: $settings.pluginsEnabled)
        }

        if settings.pluginsEnabled {
            if nothingInstalled {
                // Noch nichts installiert: gleich zeigen, was es gibt
                GalleryPage(manager: manager, title: L("Available", "Verfügbar")) { id in open(.plugin(id)) }
                importButton
            } else {
                SettingsSection(L("Installed", "Installiert")) {
                    ForEach(manager.plugins) { plugin in
                        InstalledRow(plugin: plugin, manager: manager) { open(.plugin(plugin.id)) }
                    }
                    ForEach(manager.missingStandard) { entry in
                        MissingPluginRow(entry: entry) { manager.syncCatalog(force: true) }
                    }
                    ForEach(manager.broken.keys.sorted(), id: \.self) { id in
                        BrokenPluginRow(id: id, message: manager.broken[id] ?? "", manager: manager)
                    }
                }

                VStack(alignment: .trailing, spacing: 10) {
                    SettingsCard {
                        NavigationRow(L("More Plugins", "Weitere Plugins"),
                                      value: manager.catalogExtras.isEmpty ? nil
                                          : L("\(manager.catalogExtras.count) new", "\(manager.catalogExtras.count) neu")) {
                            open(.gallery)
                        }
                        if manager.plugins.filter({ manager.isAutomatic($0) }).count > 1 {
                            NavigationRow(L("Order When Dropped", "Reihenfolge beim Ablegen")) { open(.order) }
                        }
                    }
                    importButton
                }
            }

            SettingsSection(L("Log", "Protokoll")) {
                ToggleRow(L("Plugin log", "Plugin-Protokoll"),
                          info: L("Records which plugin runs and when, what works and what fails, with file names and error messages, to find problems with plugins. Stays on this Mac until you save it.",
                                  "Hält fest, welches Plugin wann läuft, was klappt und was fehlschlägt, mit Dateinamen und Fehlermeldungen, um Probleme mit Plugins zu finden. Bleibt auf diesem Mac, bis du es sicherst."),
                          isOn: pluginLog)
                if settings.pluginLogEnabled {
                    SettingsRow(L("Log file", "Protokolldatei")) {
                        Button(L("Save Log", "Protokoll sichern")) { PluginLog.shared.saveReport() }
                            .buttonStyle(KlackButtonStyle())
                    }
                }
            }
        }
    }

    /// Klein und rechts: Die meisten nehmen Plugins aus der Galerie
    private var importButton: some View {
        HStack {
            Spacer(minLength: 0)
            Button(L("Import From File", "Aus Datei importieren")) { PluginImporter.chooseAndImport() }
                .buttonStyle(KlackButtonStyle())
                .help(L("Install a .bdrop file. You can also double-click it.",
                        "Eine .bdrop-Datei installieren. Doppelklicken geht auch."))
        }
    }
}

/// Zeile, die zu einer Unterseite führt: Bezeichnung, rechts grau ein Wert und der Pfeil
private struct NavigationRow: View {
    let title: String
    var value: String?
    let action: () -> Void
    @State private var hovering = false

    init(_ title: String, value: String? = nil, action: @escaping () -> Void) {
        self.title = title
        self.value = value
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Text(title)
                    .font(.system(size: 13.5))
                    .foregroundStyle(.primary)
                Spacer(minLength: 8)
                if let value {
                    Text(value)
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, SettingsTheme.rowPadding)
            .frame(minHeight: SettingsTheme.rowHeight)
            .background(Color.primary.opacity(hovering ? 0.03 : 0))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

// MARK: Installiert

/// Eine Zeile je Plugin: Symbol, Name, darunter die Beschreibung oder was gerade ansteht;
/// rechts „Ein“ oder „Aus“ und der Pfeil. Ein Klick öffnet die Seite des Plugins.
private struct InstalledRow: View {
    let plugin: InstalledPlugin
    @ObservedObject var manager: PluginManager
    let open: () -> Void
    @State private var hovering = false

    private var state: PluginState { manager.state(plugin.id) }
    private var running: Int { manager.runningCounts[plugin.id] ?? 0 }

    /// Zustand vor der Beschreibung: läuft, braucht Erlaubnis, hat nicht geklappt
    private var subtitle: (String, Color) {
        if running > 0 { return (L("Running", "Läuft gerade"), Color(nsColor: .controlAccentColor)) }
        if state.enabled && !manager.isFullyAuthorized(plugin) {
            return (L("Needs your permission", "Braucht deine Erlaubnis"), .orange)
        }
        if manager.lastErrors[plugin.id] != nil { return (L("Last run didn’t work", "Letzter Lauf hat nicht geklappt"), .orange) }
        if let description = plugin.manifest.description?.text, !description.isEmpty { return (description, .secondary) }
        return (L("Version \(plugin.manifest.version)", "Version \(plugin.manifest.version)"), .secondary)
    }

    var body: some View {
        Button(action: open) {
            HStack(spacing: 10) {
                PluginIconView(icon: plugin.manifest.icon, size: 26)
                VStack(alignment: .leading, spacing: 1) {
                    Text(plugin.manifest.name.text)
                        .font(.system(size: 13.5))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text(subtitle.0)
                        .font(.system(size: 11))
                        .foregroundStyle(subtitle.1)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                Text(state.enabled ? L("On", "Ein") : L("Off", "Aus"))
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, SettingsTheme.rowPadding)
            .frame(minHeight: 52)
            .background(Color.primary.opacity(hovering ? 0.03 : 0))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

// MARK: Weitere Plugins (Galerie)

private struct GalleryPage: View {
    @ObservedObject var manager: PluginManager
    /// Überschrift über der Liste (auf der Startseite, solange nichts installiert ist)
    var title: String?
    let open: (String) -> Void
    @State private var query = ""

    private var entries: [PluginCatalogEntry] {
        let all = manager.catalogEntries
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return all }
        return all.filter { entry in
            [entry.name.text, entry.description?.text ?? "", entry.author ?? ""]
                .contains { $0.localizedCaseInsensitiveContains(q) }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title {
                SettingsHeader(title) {
                    if manager.syncing && !manager.catalogEntries.isEmpty { ProgressView().controlSize(.small) }
                }
                .padding(.horizontal, 8)
            }
            content
        }
    }

    @ViewBuilder
    private var content: some View {
        // Suche erst, wenn es etwas zu suchen gibt
        if manager.catalogEntries.count > 6 {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                TextField(L("Search", "Suchen"), text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
            }
            .padding(.horizontal, 9)
            .frame(height: 28)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(SettingsTheme.segmentTrough))
            .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(SettingsTheme.separator, lineWidth: 1))
        }

        if manager.catalogEntries.isEmpty {
            SettingsCard {
                if manager.syncFailed {
                    SettingsRow(L("Couldn’t load", "Ließ sich nicht laden"),
                                subtitle: L("Check your internet connection.", "Prüf deine Internetverbindung.")) {
                        Button(L("Try Again", "Erneut versuchen")) { manager.syncCatalog(force: true) }
                            .buttonStyle(KlackButtonStyle())
                    }
                } else {
                    SettingsRow(L("No plugins available yet", "Noch keine Plugins verfügbar")) {
                        if manager.syncing { ProgressView().controlSize(.small) }
                    }
                }
            }
        } else if entries.isEmpty {
            SectionNote(L("Nothing found.", "Nichts gefunden."))
                .padding(.horizontal, 8)
        } else {
            SettingsCard {
                ForEach(entries) { entry in
                    GalleryRow(entry: entry, manager: manager) { open(entry.id) }
                }
            }
        }
    }
}

/// Plugin in der Galerie: Symbol, Name, ein Satz, darunter offline oder nicht und die Größe
private struct GalleryRow: View {
    let entry: PluginCatalogEntry
    @ObservedObject var manager: PluginManager
    let open: () -> Void
    @State private var loading = false
    @State private var failed = false

    private var installed: Bool { manager.plugin(entry.id) != nil }

    var body: some View {
        HStack(spacing: 10) {
            PluginIconView(icon: entry.icon, size: 26)
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.name.text)
                    .font(.system(size: 13.5))
                    .lineLimit(1)
                Text(failed ? L("Loading didn’t work", "Laden hat nicht geklappt") : (entry.description?.text ?? entry.version))
                    .font(.system(size: 11))
                    .foregroundStyle(failed ? Color.orange : Color.secondary)
                    .lineLimit(1)
                HStack(spacing: 10) {
                    // Nur, wenn der Katalog die Rechte nennt (ältere Einträge: nichts behaupten)
                    if let permissions = entry.permissions {
                        let connectivity = PluginConnectivity(permissions: permissions.compactMap(PluginPermission.init(rawValue:)),
                                                              tools: entry.tools ?? [])
                        HStack(spacing: 4) {
                            Image(systemName: connectivity.symbol).font(.system(size: 9.5, weight: .medium))
                            Text(connectivity.short)
                        }
                        .help(connectivity.text)
                    }
                    if let size = PluginSize.catalogText(entry) { Text(size) }
                }
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .padding(.top, 2)
            }
            Spacer(minLength: 8)
            if loading {
                ProgressView().controlSize(.small)
            } else if installed {
                Button(L("Open", "Öffnen"), action: open)
                    .buttonStyle(KlackButtonStyle())
            } else {
                Button(L("Get", "Laden")) {
                    loading = true
                    failed = false
                    manager.installFromCatalog(entry) { ok in
                        loading = false
                        failed = !ok
                    }
                }
                .buttonStyle(KlackButtonStyle())
            }
        }
        .padding(.horizontal, SettingsTheme.rowPadding)
        .padding(.vertical, 8)
        .frame(minHeight: 58)
    }
}

// MARK: Seite eines Plugins

/// Wie eine Seite der Systemeinstellungen: oben Symbol, Name und Schalter, darunter was
/// ansteht, dann das Bedienen (Wann es läuft, Einstellungen), ganz unten die Info.
private struct PluginPageView: View {
    let plugin: InstalledPlugin
    @ObservedObject var manager: PluginManager
    @ObservedObject var settings: AppSettings
    let open: (PluginPage) -> Void
    @State private var sizes: PluginSize.Parts?

    private var state: PluginState { manager.state(plugin.id) }
    private var manifest: PluginManifest { plugin.manifest }
    private var running: Int { manager.runningCounts[plugin.id] ?? 0 }

    private var enabled: Binding<Bool> {
        Binding(get: { state.enabled }, set: { on in
            // Einschalten: was noch fehlt, gleich hier in einem Fenster, nicht beim ersten Lauf
            if on, !PluginDialogs.authorize(plugin, manager: manager, ui: nil) { return }
            manager.update(plugin.id) { $0.enabled = on }
        })
    }

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

    private var hasTriggers: Bool {
        manifest.allTriggers.contains(.action) || manifest.allTriggers.contains(.automatic) || manifest.canReplaceOriginal == true
    }

    var body: some View {
        // Kopf wie in den Systemeinstellungen: Symbol, Name, Beschreibung und der Schalter
        SettingsCard {
            HStack(spacing: 12) {
                PluginIconView(icon: manifest.icon, size: 36)
                VStack(alignment: .leading, spacing: 2) {
                    Text(manifest.name.text)
                        .font(.system(size: 14, weight: .semibold))
                        .lineLimit(1)
                    if let description = manifest.description?.text, !description.isEmpty {
                        Text(description)
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 8)
                KlackSwitch(isOn: enabled)
            }
            .padding(.horizontal, SettingsTheme.rowPadding)
            .padding(.vertical, 12)
            .frame(minHeight: 60)
        }

        // Was gerade ansteht: läuft, Erlaubnis fehlt, letzter Fehler
        if running > 0 || !manager.isFullyAuthorized(plugin) || manager.lastErrors[plugin.id] != nil {
            SettingsCard {
                if running > 0 {
                    SettingsRow(L("Running", "Läuft gerade")) {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Button(L("Stop", "Beenden")) { manager.stopRuns?(plugin.id) }
                                .buttonStyle(KlackButtonStyle())
                                .help(L("Ends all runs of this plugin, also a script that is stuck.",
                                        "Beendet alle Läufe dieses Plugins, auch ein Skript, das hängt."))
                        }
                    }
                }
                if !manager.isFullyAuthorized(plugin) {
                    SettingsRow(L("Needs your permission", "Braucht deine Erlaubnis")) {
                        Button(L("Allow", "Erlauben")) { _ = PluginDialogs.authorize(plugin, manager: manager, ui: nil) }
                            .buttonStyle(KlackButtonStyle(prominent: true))
                    }
                }
                if let error = manager.lastErrors[plugin.id] {
                    HStack(alignment: .top, spacing: 10) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(L("Last run didn’t work", "Letzter Lauf hat nicht geklappt"))
                                .font(.system(size: 13.5))
                            Text(error)
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 8)
                        Button(L("Copy", "Kopieren")) {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(error, forType: .string)
                        }
                        .buttonStyle(KlackButtonStyle())
                    }
                    .padding(.horizontal, SettingsTheme.rowPadding)
                    .padding(.vertical, 11)
                }
            }
        }

        if hasTriggers {
            SettingsSection(L("When it runs", "Wann es läuft"),
                            info: L("It’s always in the right-click menu of matching items.",
                                    "Im Rechtsklick-Menü passender Objekte steht es immer.")) {
                if manifest.allTriggers.contains(.action) {
                    ToggleRow(L("In the action bar", "In der Aktionsleiste"), isOn: inActionBar)
                }
                if manifest.allTriggers.contains(.automatic) {
                    ToggleRow(L("Automatically when dropped", "Automatisch beim Ablegen"),
                              info: L("Runs as soon as you drop a matching item.",
                                      "Läuft, sobald du ein passendes Objekt ablegst."),
                              isOn: automatic)
                }
                if manifest.canReplaceOriginal == true {
                    ToggleRow(L("Replace original", "Original ersetzen"),
                              info: L("The result takes the place of the original in the shelf. The original file itself stays where it is; ⌘Z brings it back.",
                                      "Das Ergebnis nimmt den Platz des Originals in der Ablage ein. Die Originaldatei bleibt, wo sie ist; ⌘Z holt sie zurück."),
                              isOn: replace)
                }
            }
        }

        if let specs = manifest.settings, !specs.isEmpty {
            SettingsSection(L("Settings", "Einstellungen")) {
                ForEach(specs) { spec in
                    PluginSettingRow(spec: spec, plugin: plugin, manager: manager)
                }
            }
        }

        SettingsSection(L("Info", "Info")) {
            InfoValueRow(L("Internet", "Internet"), PluginConnectivity(manifest: manifest).answer)
            InfoValueRow(L("Works with", "Passt zu"), PluginSummary.matches(manifest.match))
            InfoValueRow(L("Version", "Version"), manifest.version)
            if let author = manifest.author, !author.isEmpty {
                InfoValueRow(L("Developer", "Entwickler"), author)
            }
            InfoValueRow(L("Size", "Größe"), sizes.map { PluginSize.text($0.own) } ?? "")
            if let tools = manifest.tools, !tools.isEmpty {
                SettingsRow(tools.count == 1 ? L("Program", "Programm") : L("Programs", "Programme")) {
                    HStack(spacing: 8) {
                        Text(programsValue(tools))
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                        if tools.contains(where: { state.approvedTools.contains($0.approvalKey) }) {
                            Button(L("Update", "Aktualisieren")) { manager.refreshTools(of: plugin) }
                                .buttonStyle(KlackButtonStyle())
                                .disabled(manager.toolRefresh[plugin.id] == .running)
                                .help(L("Downloads the plugin’s programs again, for example when a newer version fixes an error.",
                                        "Lädt die Programme des Plugins neu, etwa wenn eine neuere Fassung einen Fehler behebt."))
                        }
                    }
                }
            }
            if !manifest.allPermissions.isEmpty || !(manifest.tools ?? []).isEmpty {
                NavigationRow(L("Permissions", "Rechte"),
                              value: manager.isFullyAuthorized(plugin) ? L("Allowed", "Erlaubt") : L("Not allowed", "Nicht erlaubt")) {
                    open(.permissions(plugin.id))
                }
            }
        }

        HStack(spacing: 8) {
            Spacer(minLength: 8)
            Button(L("Show Script", "Skript zeigen")) { ScriptViewer.show(plugin) }
                .buttonStyle(KlackButtonStyle())
            if !plugin.isStandard {
                Button(L("Remove", "Entfernen")) { confirmRemove() }
                    .buttonStyle(KlackButtonStyle(destructive: true))
            }
        }
        .padding(.horizontal, 4)
        .onAppear { sizes = PluginSize.parts(of: plugin, tools: manager.tools) }
        .onChange(of: manager.toolRefresh[plugin.id]) { _, _ in sizes = PluginSize.parts(of: plugin, tools: manager.tools) }
    }

    /// „92 MB“, „noch nicht geladen“ oder der Stand nach „Aktualisieren“
    private func programsValue(_ tools: [PluginTool]) -> String {
        switch manager.toolRefresh[plugin.id] {
        case .running: return L("updating", "wird aktualisiert")
        case .failed(let message): return message
        default: break
        }
        guard let sizes, let programs = sizes.programs else { return L("not downloaded yet", "noch nicht geladen") }
        return PluginSize.text(programs)
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
        open(.list)
        withAnimation(.spring(response: 0.3, dampingFraction: 0.88)) { manager.remove(plugin.id) }
    }
}

/// Info-Zeile: Bezeichnung links, Wert rechts in Grau (lange Werte brechen um)
private struct InfoValueRow: View {
    let title: String
    let value: String

    init(_ title: String, _ value: String) {
        self.title = title
        self.value = value
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(title)
                .font(.system(size: 13.5))
                .layoutPriority(1)
            Spacer(minLength: 12)
            Text(value)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, SettingsTheme.rowPadding)
        .padding(.vertical, 12)
        .frame(minHeight: SettingsTheme.rowHeight)
    }
}

// MARK: Rechte

/// Was das Plugin darf und lädt, je Zeile mit Stand; darunter Erlauben bzw. Zurücksetzen
private struct PluginPermissionsPage: View {
    let plugin: InstalledPlugin
    @ObservedObject var manager: PluginManager

    private var state: PluginState { manager.state(plugin.id) }

    var body: some View {
        let manifest = plugin.manifest
        SettingsSection(note: L("If the plugin’s files change, it asks again.",
                                "Ändern sich die Dateien des Plugins, fragt es erneut.")) {
            if manifest.consent != nil {
                SettingsRow(L("Notice", "Hinweis"), subtitle: manifest.consent?.text) {
                    status(manager.hasConsented(plugin), allowed: L("Agreed", "Zugestimmt"))
                }
            }
            ForEach(manifest.allPermissions) { permission in
                SettingsRow(permission.title, subtitle: permission.explanation) {
                    status(manager.isGranted(permission, for: plugin))
                }
            }
            ForEach(manifest.tools ?? [], id: \.approvalKey) { tool in
                SettingsRow(L("Downloads “\(tool.name)”", "Lädt „\(tool.name)“"),
                            subtitle: [URL(string: tool.resolvedURL)?.host, tool.license].compactMap { $0 }.joined(separator: " · ")) {
                    status(state.approvedTools.contains(tool.approvalKey))
                }
            }
        }

        HStack(spacing: 8) {
            Spacer(minLength: 8)
            if !state.granted.isEmpty || !state.approvedTools.isEmpty {
                Button(L("Reset", "Zurücksetzen")) { manager.revokePermissions(plugin.id) }
                    .buttonStyle(KlackButtonStyle())
            }
            if !manager.isFullyAuthorized(plugin) {
                Button(L("Allow", "Erlauben")) { _ = PluginDialogs.authorize(plugin, manager: manager, ui: nil) }
                    .buttonStyle(KlackButtonStyle(prominent: true))
            }
        }
        .padding(.horizontal, 4)
    }

    private func status(_ granted: Bool, allowed: String = L("Allowed", "Erlaubt")) -> some View {
        Text(granted ? allowed : L("Not yet", "Noch nicht"))
            .font(.system(size: 13))
            .foregroundStyle(.secondary)
    }
}

// MARK: Reihenfolge

/// Welches automatische Plugin läuft, wenn mehrere zum selben Objekt passen: das oberste
private struct PluginOrderPage: View {
    @ObservedObject var manager: PluginManager

    var body: some View {
        let automatic = manager.plugins.filter { manager.isAutomatic($0) }
        SettingsSection(note: L("If several plugins match the same item, only the top one runs. Standard plugins stay above your own.",
                                "Passen mehrere Plugins zum selben Objekt, läuft nur das oberste. Standard-Plugins bleiben über deinen eigenen.")) {
            if automatic.isEmpty {
                SettingsRow(L("No plugin runs automatically", "Kein Plugin läuft automatisch")) { EmptyView() }
            }
            ForEach(automatic) { plugin in
                HStack(spacing: 10) {
                    PluginIconView(icon: plugin.manifest.icon, size: 22)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(plugin.manifest.name.text)
                            .font(.system(size: 13.5))
                            .lineLimit(1)
                        Text(PluginSummary.matches(plugin.manifest.match))
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    Button { withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) { manager.moveAutomatic(plugin.id, by: -1) } } label: {
                        Image(systemName: "chevron.up")
                    }
                    .buttonStyle(KlackButtonStyle())
                    .disabled(!manager.canMoveAutomatic(plugin.id, by: -1))
                    .help(L("Move up", "Nach oben"))
                    Button { withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) { manager.moveAutomatic(plugin.id, by: 1) } } label: {
                        Image(systemName: "chevron.down")
                    }
                    .buttonStyle(KlackButtonStyle())
                    .disabled(!manager.canMoveAutomatic(plugin.id, by: 1))
                    .help(L("Move down", "Nach unten"))
                }
                .padding(.horizontal, SettingsTheme.rowPadding)
                .frame(minHeight: 50)
            }
        }
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
        if !tools.isEmpty { return tools.count == 1 ? L("Program", "Programm") : L("Programs", "Programme") }
        return L("Offline", "Offline")
    }

    var symbol: String {
        if usesNetwork { return "globe" }
        return tools.isEmpty ? "wifi.slash" : "arrow.down.circle"
    }
}

extension PluginConnectivity {
    init(manifest: PluginManifest) {
        self.init(permissions: manifest.allPermissions, tools: (manifest.tools ?? []).map(\.name))
    }

    /// Antwort in der Info einer Plugin-Seite: Geht es ins Internet?
    var answer: String {
        if usesNetwork { return L("Yes", "Ja") }
        if !tools.isEmpty { return L("Only to download programs", "Nur zum Laden von Programmen") }
        return L("No, works offline", "Nein, offline")
    }

    struct LegendItem: Hashable {
        let symbol: String
        let text: String
    }

    /// Erklärung der Zeichen unter der Liste
    static var legend: [LegendItem] {
        [LegendItem(symbol: "wifi.slash", text: L("offline", "offline")),
         LegendItem(symbol: "globe", text: L("internet", "Internet")),
         LegendItem(symbol: "arrow.down.circle", text: L("downloads a program", "lädt ein Programm"))]
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

    /// Galerie, vor dem Laden: „14 KB“ oder, mit Programmen, „8 KB + 61 MB“ (das Zeichen
    /// und „Programm“ davor nennt die Zeile schon; ohne bekannte Größe nur „8 KB“)
    static func catalogText(_ entry: PluginCatalogEntry) -> String? {
        guard let size = entry.size else { return nil }
        guard (entry.tools?.count ?? 0) > 0, let programs = entry.toolsSize else { return text(Int64(size)) }
        return text(Int64(size)) + " + " + text(Int64(programs))
    }

    /// Plugin und Programme getrennt, für die Seite eines Plugins. `programs` nil: noch
    /// keines geladen (oder das Plugin braucht keine)
    struct Parts: Equatable {
        let own: Int64
        let programs: Int64?
    }

    static func parts(of plugin: InstalledPlugin, tools: PluginTools) -> Parts {
        let folders = Set((plugin.manifest.tools ?? []).compactMap { tools.installed($0)?.deletingLastPathComponent() })
        return Parts(own: folder(plugin.directory),
                     programs: folders.isEmpty ? nil : folders.reduce(Int64(0)) { $0 + folder($1) })
    }

    /// Summe unter der Liste; Programme, die sich Plugins teilen, zählen einmal
    struct Totals: Equatable {
        let plugins: Int64
        let programs: Int64

        func text(count: Int) -> String {
            var parts = [count == 1 ? L("1 plugin", "1 Plugin") : L("\(count) plugins", "\(count) Plugins"),
                         PluginSize.text(plugins)]
            if programs > 0 { parts.append(L("programs ", "Programme ") + PluginSize.text(programs)) }
            return parts.joined(separator: " · ")
        }
    }

    static func totals(_ plugins: [InstalledPlugin], tools: PluginTools) -> Totals {
        let own = plugins.reduce(Int64(0)) { $0 + folder($1.directory) }
        let folders = Set(plugins.flatMap { ($0.manifest.tools ?? []).compactMap { tools.installed($0)?.deletingLastPathComponent() } })
        return Totals(plugins: own, programs: folders.reduce(Int64(0)) { $0 + folder($1) })
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
