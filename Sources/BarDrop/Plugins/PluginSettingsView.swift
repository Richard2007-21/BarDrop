import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Unterseiten von Einstellungen → Plugins. Die Liste ist die Startseite; ein Plugin, die
/// Reihenfolge und das Protokoll öffnen sich als eigene Seite mit „‹ Plugins“ zurück.
enum PluginPage: Hashable {
    case list
    case plugin(String)
    case order
    case log
}

/// Reiter der Startseite
enum PluginTab: Hashable {
    case installed
    case gallery
}

/// Einstellungen → Plugins: oben der Hauptschalter, darunter zwei Reiter. „Installiert“
/// zeigt je Plugin eine ruhige Zeile (Symbol, Name, Zustand, graue Zeichen für offline,
/// Internet, Programm und automatisch, Schalter); ein Klick öffnet seine Seite.
/// „Galerie“ zeigt die geprüften Plugins aus dem Katalog mit „Laden“.
struct PluginSettings: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject private var manager: PluginManager
    @State private var page: PluginPage
    @State private var tab: PluginTab
    @State private var importFrame: CGRect = .zero

    /// `manager`, `tab` und `page` nur für Tests und Vorschaubilder
    init(settings: AppSettings, manager: PluginManager = .shared, tab: PluginTab = .installed, page: PluginPage = .list) {
        self.settings = settings
        self.manager = manager
        _tab = State(initialValue: tab)
        _page = State(initialValue: page)
    }

    var body: some View {
        SettingsPage {
            switch page {
            case .list:
                start
            case .plugin(let id):
                if let plugin = manager.plugin(id) {
                    PluginPageView(plugin: plugin, manager: manager, settings: settings, back: back)
                } else {
                    // Entfernt oder nicht mehr lesbar: zurück zur Liste
                    start.onAppear { page = .list }
                }
            case .order:
                PluginOrderPage(manager: manager, back: back)
            case .log:
                PluginLogPage(settings: settings, back: back)
            }
        }
        .onAppear {
            // Bearbeitete Skripte erkennen; Katalog abgleichen, wenn es länger her ist
            manager.reload()
            manager.syncCatalog(maxAge: 3600)
        }
    }

    private func open(_ next: PluginPage) {
        withAnimation(.easeInOut(duration: 0.18)) { page = next }
    }

    private func back() { open(.list) }

    // MARK: Startseite

    @ViewBuilder
    private var start: some View {
        SettingsSection(note: settings.pluginsEnabled ? nil
                        : L("Plugins add their own entries to the right-click menu and the action bar, or run when you drop matching items. When you turn this on, BarDrop loads the standard plugins from its gallery; they stay off until you turn them on.",
                            "Plugins ergänzen eigene Einträge im Rechtsklick-Menü und in der Aktionsleiste oder laufen beim Ablegen passender Objekte. Beim Einschalten lädt BarDrop die Standard-Plugins aus seiner Galerie; sie bleiben aus, bis du sie einschaltest.")) {
            ToggleRow(L("Use plugins", "Plugins verwenden"), isOn: $settings.pluginsEnabled)
        }

        if settings.pluginsEnabled {
            HStack {
                Spacer(minLength: 0)
                SegmentedValue(selection: $tab, options: [(.installed, L("Installed", "Installiert")),
                                                          (.gallery, L("Gallery", "Galerie"))])
                Spacer(minLength: 0)
            }
            .padding(.top, -6)

            switch tab {
            case .installed:
                InstalledList(manager: manager, settings: settings, importFrame: $importFrame, open: open)
            case .gallery:
                GalleryList(manager: manager) { id in
                    tab = .installed
                    open(.plugin(id))
                }
            }
        }
    }
}

/// „‹ Plugins“ oben auf einer Unterseite
private struct BackLink: View {
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 3) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 12, weight: .semibold))
                Text(L("Plugins", "Plugins"))
                    .font(.system(size: 13.5))
            }
            .foregroundStyle(Color(nsColor: .controlAccentColor).opacity(hovering ? 0.8 : 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .keyboardShortcut(.cancelAction)
        .padding(.leading, 4)
        .padding(.bottom, -8)
    }
}

/// Graues Zeichen für eine Eigenschaft eines Plugins, mit Erklärung beim Darüberfahren
private struct TraitSymbol: View {
    let symbol: String
    let help: String

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.secondary)
            .frame(width: 16)
            .help(help)
            .accessibilityLabel(help)
    }
}

// MARK: Installiert

private struct InstalledList: View {
    @ObservedObject var manager: PluginManager
    @ObservedObject var settings: AppSettings
    @Binding var importFrame: CGRect
    let open: (PluginPage) -> Void
    @State private var totals: PluginSize.Totals?

    private var automaticCount: Int { manager.plugins.filter { manager.isAutomatic($0) }.count }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if manager.plugins.isEmpty && manager.missingStandard.isEmpty && manager.broken.isEmpty {
                SettingsCard {
                    HStack(spacing: 10) {
                        Image(systemName: "puzzlepiece.extension")
                            .font(.system(size: 18))
                            .foregroundStyle(.secondary)
                            .frame(width: 26)
                        Text(manager.syncFailed
                             ? L("The gallery couldn’t be loaded. Check your internet connection.",
                                 "Die Galerie ließ sich nicht laden. Prüf deine Internetverbindung.")
                             : L("No plugins installed yet. Find some in the gallery.",
                                 "Noch keine Plugins installiert. Welche findest du in der Galerie."))
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 8)
                        if manager.syncing {
                            ProgressView().controlSize(.small)
                        } else if manager.syncFailed {
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
                        InstalledRow(plugin: plugin, manager: manager) { open(.plugin(plugin.id)) }
                    }
                    ForEach(manager.missingStandard) { entry in
                        MissingPluginRow(entry: entry) { manager.syncCatalog(force: true) }
                    }
                    ForEach(manager.broken.keys.sorted(), id: \.self) { id in
                        BrokenPluginRow(id: id, message: manager.broken[id] ?? "", manager: manager)
                    }
                }
                legend
            }

            AddListRow(title: L("Import Plugin", "Plugin importieren"), frame: $importFrame) {
                PluginImporter.chooseAndImport()
            }
            .padding(.top, 6)
            SectionNote(L("Or double-click a .bdrop file. Plugins that aren’t from the gallery show a warning first.",
                          "Oder eine .bdrop-Datei doppelklicken. Plugins, die nicht aus der Galerie stammen, zeigen vorher eine Warnung."))
                .padding(.horizontal, 8)

            HStack(spacing: 8) {
                if let totals, !manager.plugins.isEmpty {
                    Text(totals.text(count: manager.plugins.count))
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                if automaticCount > 1 {
                    Button(L("Order", "Reihenfolge")) { open(.order) }
                        .buttonStyle(KlackButtonStyle())
                        .help(L("Which automatic plugin runs when several match", "Welches automatische Plugin läuft, wenn mehrere passen"))
                }
                Button(L("Log", "Protokoll")) { open(.log) }
                    .buttonStyle(KlackButtonStyle())
            }
            .padding(.top, 10)
            .padding(.horizontal, 4)
        }
        .onAppear { totals = PluginSize.totals(manager.plugins, tools: manager.tools) }
        .onChange(of: manager.plugins) { _, plugins in totals = PluginSize.totals(plugins, tools: manager.tools) }
    }

    /// Was die grauen Zeichen bedeuten, nur für die, die gerade vorkommen
    @ViewBuilder
    private var legend: some View {
        let kinds = Set(manager.plugins.map { PluginConnectivity(manifest: $0.manifest).symbol })
        let automatic = manager.plugins.contains { manager.isAutomatic($0) }
        HStack(spacing: 14) {
            ForEach(PluginConnectivity.legend.filter { kinds.contains($0.symbol) }, id: \.self) { item in
                legendItem(item.symbol, item.text)
            }
            if automatic { legendItem("bolt", L("automatic", "automatisch")) }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
    }

    private func legendItem(_ symbol: String, _ text: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: symbol).font(.system(size: 10, weight: .medium))
            Text(text).font(.system(size: 11))
        }
        .foregroundStyle(.secondary)
    }
}

/// Eine Zeile je installiertem Plugin. Ein Klick (außer auf den Schalter) öffnet seine Seite.
private struct InstalledRow: View {
    let plugin: InstalledPlugin
    @ObservedObject var manager: PluginManager
    let open: () -> Void
    @State private var hovering = false

    private var state: PluginState { manager.state(plugin.id) }
    private var running: Int { manager.runningCounts[plugin.id] ?? 0 }
    private var needsAllow: Bool { state.enabled && !manager.isFullyAuthorized(plugin) }

    private var enabled: Binding<Bool> {
        Binding(get: { state.enabled }, set: { on in
            // Einschalten: was noch fehlt, gleich hier in einem Fenster, nicht beim ersten Lauf
            if on, !PluginDialogs.authorize(plugin, manager: manager, ui: nil) { return }
            manager.update(plugin.id) { $0.enabled = on }
        })
    }

    /// Zustand vor der Beschreibung: läuft, braucht Erlaubnis, hat nicht geklappt
    private var subtitle: (String, Color) {
        if running > 0 {
            return (running == 1 ? L("Running", "Läuft gerade") : L("Running \(running) times", "Läuft \(running)-mal"),
                    Color(nsColor: .controlAccentColor))
        }
        if needsAllow { return (L("Needs your permission", "Braucht noch deine Erlaubnis"), .orange) }
        if manager.lastErrors[plugin.id] != nil { return (L("Last run didn’t work", "Letzter Lauf hat nicht geklappt"), .orange) }
        if let description = plugin.manifest.description?.text, !description.isEmpty { return (description, .secondary) }
        return (L("Version \(plugin.manifest.version)", "Version \(plugin.manifest.version)"), .secondary)
    }

    var body: some View {
        let connectivity = PluginConnectivity(manifest: plugin.manifest)
        HStack(spacing: 10) {
            Button(action: open) {
                HStack(spacing: 10) {
                    PluginIconView(icon: plugin.manifest.icon, size: 26)
                        .opacity(state.enabled ? 1 : 0.55)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(plugin.manifest.name.text)
                            .font(.system(size: 13.5))
                            .lineLimit(1)
                        Text(subtitle.0)
                            .font(.system(size: 11))
                            .foregroundStyle(subtitle.1)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    HStack(spacing: 6) {
                        if manager.isAutomatic(plugin) {
                            TraitSymbol(symbol: "bolt", help: L("Runs automatically when dropped", "Läuft automatisch beim Ablegen"))
                        }
                        TraitSymbol(symbol: connectivity.symbol, help: connectivity.text)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if needsAllow {
                Button(L("Allow", "Erlauben")) { _ = PluginDialogs.authorize(plugin, manager: manager, ui: nil) }
                    .buttonStyle(KlackButtonStyle(prominent: true))
            }
            KlackSwitch(isOn: enabled)
            Button(action: open) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .frame(width: 14, height: 30)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L("Open \(plugin.manifest.name.text)", "\(plugin.manifest.name.text) öffnen"))
        }
        .padding(.horizontal, SettingsTheme.rowPadding)
        .frame(minHeight: 52)
        .background(Color.primary.opacity(hovering ? 0.03 : 0))
        .onHover { hovering = $0 }
    }
}

// MARK: Galerie

private struct GalleryList: View {
    @ObservedObject var manager: PluginManager
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
                    HStack(spacing: 10) {
                        Image(systemName: "square.grid.2x2")
                            .font(.system(size: 17))
                            .foregroundStyle(.secondary)
                            .frame(width: 26)
                        Text(manager.syncFailed
                             ? L("The gallery couldn’t be loaded. Check your internet connection.",
                                 "Die Galerie ließ sich nicht laden. Prüf deine Internetverbindung.")
                             : manager.syncing ? L("Loading the gallery", "Galerie wird geladen")
                             : L("No plugins in the gallery yet.", "Noch keine Plugins in der Galerie."))
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 8)
                        if manager.syncing {
                            ProgressView().controlSize(.small)
                        } else {
                            Button(L("Try Again", "Erneut versuchen")) { manager.syncCatalog(force: true) }
                                .buttonStyle(KlackButtonStyle())
                        }
                    }
                    .padding(.horizontal, SettingsTheme.rowPadding)
                    .frame(minHeight: SettingsTheme.rowHeight)
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

            HStack(spacing: 8) {
                Text(L("Every plugin here has been reviewed.", "Alle Plugins hier sind geprüft."))
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Button(L("Submit Plugin", "Plugin einreichen")) {
                    if let url = URL(string: "https://github.com/zzuuuiii/BarDrop/blob/main/docs/PLUGINS.md") {
                        NSWorkspace.shared.open(url)
                    }
                }
                .buttonStyle(KlackButtonStyle())
            }
            .padding(.top, 10)
            .padding(.horizontal, 4)
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

private struct PluginPageView: View {
    let plugin: InstalledPlugin
    @ObservedObject var manager: PluginManager
    @ObservedObject var settings: AppSettings
    let back: () -> Void
    @State private var sizes: PluginSize.Parts?

    private var state: PluginState { manager.state(plugin.id) }
    private var manifest: PluginManifest { plugin.manifest }
    private var running: Int { manager.runningCounts[plugin.id] ?? 0 }

    private var enabled: Binding<Bool> {
        Binding(get: { state.enabled }, set: { on in
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

    var body: some View {
        let connectivity = PluginConnectivity(manifest: manifest)
        BackLink(action: back)

        HStack(spacing: 12) {
            PluginIconView(icon: manifest.icon, size: 40)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(manifest.name.text)
                        .font(.system(size: 16, weight: .semibold))
                        .lineLimit(1)
                    if plugin.isStandard { Badge(L("Standard", "Standard")) }
                }
                if let description = manifest.description?.text, !description.isEmpty {
                    Text(description)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 8)
            KlackSwitch(isOn: enabled)
        }
        .padding(.horizontal, 4)

        // Was gerade ansteht: läuft, Erlaubnis fehlt, letzter Fehler
        if running > 0 || !manager.isFullyAuthorized(plugin) || manager.lastErrors[plugin.id] != nil {
            SettingsCard {
                if running > 0 {
                    HStack(spacing: 10) {
                        ProgressView().controlSize(.small).frame(width: 18)
                        Text(running == 1 ? L("Running", "Läuft gerade") : L("Running \(running) times", "Läuft \(running)-mal"))
                            .font(.system(size: 13.5))
                        Spacer(minLength: 8)
                        Button(L("Stop", "Beenden")) { manager.stopRuns?(plugin.id) }
                            .buttonStyle(KlackButtonStyle())
                            .help(L("Ends all runs of this plugin, also a script that is stuck.",
                                    "Beendet alle Läufe dieses Plugins, auch ein Skript, das hängt."))
                    }
                    .padding(.horizontal, SettingsTheme.rowPadding)
                    .frame(minHeight: SettingsTheme.rowHeight)
                }
                if !manager.isFullyAuthorized(plugin) {
                    HStack(spacing: 10) {
                        Image(systemName: "hand.raised")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.orange)
                            .frame(width: 18)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(L("Needs your permission", "Braucht noch deine Erlaubnis"))
                                .font(.system(size: 13.5))
                            Text(connectivity.text)
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 8)
                        Button(L("Allow", "Erlauben")) { _ = PluginDialogs.authorize(plugin, manager: manager, ui: nil) }
                            .buttonStyle(KlackButtonStyle(prominent: true))
                    }
                    .padding(.horizontal, SettingsTheme.rowPadding)
                    .frame(minHeight: 52)
                }
                if let error = manager.lastErrors[plugin.id] {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.orange)
                            .frame(width: 18)
                            .padding(.top, 2)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(L("Last error", "Letzter Fehler"))
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
                    .padding(.vertical, 10)
                }
            }
        }

        SettingsSection(L("Overview", "Überblick")) {
            InfoRow(symbol: connectivity.symbol, title: L("Internet", "Internet"), value: connectivity.text)
            InfoRow(symbol: "puzzlepiece.extension", title: L("Plugin", "Plugin"),
                    value: [sizes.map { PluginSize.text($0.own) }, L("Version \(manifest.version)", "Version \(manifest.version)")]
                        .compactMap { $0 }.joined(separator: " · "))
            if let tools = manifest.tools, !tools.isEmpty {
                InfoRow(symbol: "terminal", title: tools.count == 1 ? L("Program", "Programm") : L("Programs", "Programme"),
                        value: programsValue(tools)) {
                    if tools.contains(where: { state.approvedTools.contains($0.approvalKey) }) {
                        Button(L("Update", "Aktualisieren")) { manager.refreshTools(of: plugin) }
                            .buttonStyle(KlackButtonStyle())
                            .disabled(manager.toolRefresh[plugin.id] == .running)
                            .help(L("Downloads the plugin’s programs again, for example when a newer version fixes an error.",
                                    "Lädt die Programme des Plugins neu, etwa wenn eine neuere Fassung einen Fehler behebt."))
                    }
                }
            }
            InfoRow(symbol: "tray.and.arrow.down", title: L("Works with", "Passt zu"), value: PluginSummary.matches(manifest.match))
            if !manifest.allPermissions.isEmpty {
                let granted = manifest.allPermissions.allSatisfy { manager.isGranted($0, for: plugin) }
                InfoRow(symbol: "lock", title: L("May", "Darf"),
                        value: manifest.allPermissions.map(\.title).joined(separator: ", ")
                            + " · " + (granted ? L("allowed", "erlaubt") : L("not allowed yet", "noch nicht erlaubt"))) {
                    Button(L("Reset", "Zurücksetzen")) { manager.revokePermissions(plugin.id) }
                        .buttonStyle(KlackButtonStyle())
                        .disabled(state.granted.isEmpty)
                        .help(L("Takes back all permissions; the plugin asks again before its next run.",
                                "Nimmt alle Rechte zurück; das Plugin fragt vor dem nächsten Lauf erneut."))
                }
            }
        }

        SettingsSection(L("When it runs", "Wann es läuft")) {
            if manifest.allTriggers.contains(.menu) {
                SettingsRow(L("In the right-click menu", "Im Rechtsklick-Menü")) {
                    Text(L("always", "immer"))
                        .font(.system(size: 12.5))
                        .foregroundStyle(.secondary)
                }
            }
            if manifest.allTriggers.contains(.action) {
                ToggleRow(L("In the action bar", "In der Aktionsleiste"), isOn: inActionBar)
            }
            if manifest.allTriggers.contains(.automatic) {
                ToggleRow(L("Automatically when dropped", "Automatisch beim Ablegen"),
                          info: L("Runs as soon as you drop a matching item. If several automatic plugins match, the first one in Order runs.",
                                  "Läuft, sobald du ein passendes Objekt ablegst. Passen mehrere automatische Plugins, läuft das erste unter „Reihenfolge“."),
                          isOn: automatic)
            }
            if manifest.canReplaceOriginal == true {
                ToggleRow(L("Replace original", "Original ersetzen"),
                          info: L("The result takes the place of the original in the shelf. The original file itself stays where it is; ⌘Z brings it back into the shelf.",
                                  "Das Ergebnis nimmt den Platz des Originals in der Ablage ein. Die Originaldatei selbst bleibt, wo sie ist; ⌘Z holt sie zurück in die Ablage."),
                          isOn: replace)
            }
        }

        if let specs = manifest.settings, !specs.isEmpty {
            SettingsSection(L("Settings", "Einstellungen")) {
                ForEach(specs) { spec in
                    PluginSettingRow(spec: spec, plugin: plugin, manager: manager)
                }
            }
        }

        HStack(spacing: 8) {
            Text([manifest.author, plugin.isStandard ? L("Standard plugin", "Standard-Plugin") : nil]
                    .compactMap { $0 }.joined(separator: " · "))
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 8)
            Button(L("Script", "Skript")) { ScriptViewer.show(plugin) }
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

    /// „2 · 92 MB“, „noch nicht geladen“ oder der Stand nach „Aktualisieren“
    private func programsValue(_ tools: [PluginTool]) -> String {
        switch manager.toolRefresh[plugin.id] {
        case .running: return L("updating", "wird aktualisiert")
        case .failed(let message): return message
        default: break
        }
        guard let sizes, let programs = sizes.programs else {
            return L("not downloaded yet", "noch nicht geladen")
        }
        let size = PluginSize.text(programs)
        return tools.count == 1 ? size : "\(tools.count) · " + size
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
        back()
        withAnimation(.spring(response: 0.3, dampingFraction: 0.88)) { manager.remove(plugin.id) }
    }
}

/// Zeile im Überblick: graues Zeichen, Bezeichnung, Wert rechts, optional ein Knopf
private struct InfoRow<Trailing: View>: View {
    let symbol: String
    let title: String
    let value: String
    let trailing: Trailing

    init(symbol: String, title: String, value: String, @ViewBuilder trailing: () -> Trailing) {
        self.symbol = symbol
        self.title = title
        self.value = value
        self.trailing = trailing()
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 18)
            Text(title)
                .font(.system(size: 13.5))
                .layoutPriority(1)
            Spacer(minLength: 12)
            Text(value)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
                .lineLimit(2)
            trailing
        }
        .padding(.horizontal, SettingsTheme.rowPadding)
        .frame(minHeight: 40)
    }
}

extension InfoRow where Trailing == EmptyView {
    init(symbol: String, title: String, value: String) {
        self.init(symbol: symbol, title: title, value: value) { EmptyView() }
    }
}

// MARK: Reihenfolge

/// Welches automatische Plugin läuft, wenn mehrere zum selben Objekt passen: das oberste
private struct PluginOrderPage: View {
    @ObservedObject var manager: PluginManager
    let back: () -> Void

    var body: some View {
        let automatic = manager.plugins.filter { manager.isAutomatic($0) }
        BackLink(action: back)
        SettingsSection(L("Automatically when dropped", "Automatisch beim Ablegen"),
                        note: L("If several plugins match the same item, only the top one runs. Standard plugins stay above your own.",
                                "Passen mehrere Plugins zum selben Objekt, läuft nur das oberste. Standard-Plugins bleiben über deinen eigenen.")) {
            if automatic.isEmpty {
                SettingsRow(L("No plugin runs automatically yet.", "Noch kein Plugin läuft automatisch.")) { EmptyView() }
            }
            ForEach(Array(automatic.enumerated()), id: \.element.id) { index, plugin in
                HStack(spacing: 10) {
                    Text("\(index + 1)")
                        .font(.system(size: 12, weight: .medium).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 14)
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

// MARK: Protokoll

private struct PluginLogPage: View {
    @ObservedObject var settings: AppSettings
    let back: () -> Void

    var body: some View {
        BackLink(action: back)
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
        if !tools.isEmpty { return L("Downloads a program once", "Lädt einmal ein Programm") }
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

    /// Galerie, vor dem Laden: „14 KB“ oder „8 KB · Programm 61 MB“
    static func catalogText(_ entry: PluginCatalogEntry) -> String? {
        guard let size = entry.size else { return nil }
        let count = entry.tools?.count ?? 0
        guard count > 0 else { return text(Int64(size)) }
        let programs = entry.toolsSize.map { text(Int64($0)) } ?? L("size unknown", "Größe unbekannt")
        return text(Int64(size)) + " · " + programsLabel(count) + " " + programs
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
