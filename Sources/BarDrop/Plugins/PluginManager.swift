import AppKit
import Combine

/// Ein installiertes Plugin, so wie es gerade auf der Platte liegt.
struct InstalledPlugin: Identifiable, Equatable {
    let manifest: PluginManifest
    let directory: URL
    let script: String
    /// Über Manifest und Skript; ändert sich beim Bearbeiten
    let fingerprint: String
    /// Aus dem Katalog als Standard-Plugin installiert: nicht löschbar, nicht bearbeitbar
    let isStandard: Bool

    var id: String { manifest.id }
    var scriptURL: URL { directory.appendingPathComponent(manifest.script) }
    var manifestURL: URL { directory.appendingPathComponent("manifest.json") }

    static func == (a: InstalledPlugin, b: InstalledPlugin) -> Bool {
        a.id == b.id && a.fingerprint == b.fingerprint && a.isStandard == b.isStandard
    }
}

/// Was der Nutzer für ein Plugin eingestellt und erlaubt hat.
struct PluginState: Codable, Equatable {
    var enabled = false
    /// nil: Standard des Plugins
    var automatic: Bool?
    var replaceOriginal = false
    var values: [String: PluginValue] = [:]
    /// Erteilte Rechte. Sie gelten nur für den Code mit `grantedFingerprint`.
    var granted: [PluginPermission] = []
    var grantedFingerprint: String?
    /// Dem Hinweis des Plugins (`consent`) zugestimmt
    var consented = false
    /// Programme (`tools`), deren Download der Nutzer schon erlaubt hat. Gilt auch für
    /// automatische Läufe, die selbst nie fragen.
    var approvedTools: [String] = []
    var isStandard = false

    init() {}

    /// Fehlende Schlüssel (ältere Fassungen) bekommen ihren Standard, statt alles zu verwerfen
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        automatic = try c.decodeIfPresent(Bool.self, forKey: .automatic)
        replaceOriginal = try c.decodeIfPresent(Bool.self, forKey: .replaceOriginal) ?? false
        values = try c.decodeIfPresent([String: PluginValue].self, forKey: .values) ?? [:]
        granted = (try c.decodeIfPresent([String].self, forKey: .granted) ?? []).compactMap(PluginPermission.init(rawValue:))
        grantedFingerprint = try c.decodeIfPresent(String.self, forKey: .grantedFingerprint)
        consented = try c.decodeIfPresent(Bool.self, forKey: .consented) ?? false
        approvedTools = try c.decodeIfPresent([String].self, forKey: .approvedTools) ?? []
        isStandard = try c.decodeIfPresent(Bool.self, forKey: .isStandard) ?? false
    }
}

/// Eintrag im Katalog (index.json). Der Katalog kennt nur Plugins, die geprüft wurden.
struct PluginCatalogEntry: Codable, Equatable, Identifiable {
    var id: String
    var version: String
    var name: LocalizedText
    var description: LocalizedText?
    var icon: PluginManifest.Icon?
    /// .bdrop-Datei (https)
    var url: String
    var sha256: String
    /// Wird mit dem Einschalten der Plugins automatisch installiert und lässt sich nicht löschen
    var standard: Bool?
    /// Zurückgezogen: BarDrop entfernt es beim nächsten Abgleich
    var removed: Bool?
    var minAppVersion: String?
}

struct PluginCatalog: Codable, Equatable {
    var schema: Int = 1
    var plugins: [PluginCatalogEntry]
}

/// Verwaltet die Plugins: installieren, entfernen, Reihenfolge, Einstellungen, Rechte
/// und den Abgleich mit dem Katalog.
///
/// Leistung: Im Ruhezustand tut die Verwaltung nichts. Plugins werden beim Start einmal
/// gelesen; der Katalog wird höchstens einmal am Tag abgefragt und nur, wenn Plugins
/// eingeschaltet sind. Skripte laufen erst, wenn ein Plugin gestartet wird.
final class PluginManager: ObservableObject {
    static let shared = PluginManager()

    /// Katalog der Standard-Plugins. Er liegt im Repository von BarDrop und lässt sich
    /// später in ein eigenes Repository verschieben (nur diese Adresse ändern).
    static let catalogURL = URL(string: "https://raw.githubusercontent.com/zzuuuiii/BarDrop/main/Plugins/index.json")!

    /// Installierte Plugins in der eingestellten Reihenfolge (die erste passende läuft
    /// automatisch). Standard-Plugins stehen vor den importierten.
    @Published private(set) var plugins: [InstalledPlugin] = []
    @Published private(set) var states: [String: PluginState] = [:]
    /// Standard-Plugins, die der Katalog nennt, die aber nicht geladen werden konnten
    @Published private(set) var missingStandard: [PluginCatalogEntry] = []
    /// Weitere Plugins im Katalog (nicht Standard, noch nicht installiert)
    @Published private(set) var catalogExtras: [PluginCatalogEntry] = []
    @Published private(set) var syncing = false
    /// Der letzte Abgleich mit dem Katalog ist gescheitert (kein Internet)
    @Published private(set) var syncFailed = false
    /// Plugins, deren Ordner nicht mehr lesbar ist (z. B. nach dem Bearbeiten): Fehlertext
    @Published private(set) var broken: [String: String] = [:]
    /// Letzter Fehler je Plugin (nur bis zum Beenden), sichtbar in den Einstellungen
    @Published var lastErrors: [String: String] = [:]

    let baseDirectory: URL
    private var pluginsDirectory: URL { baseDirectory.appendingPathComponent("Plugins", isDirectory: true) }
    var toolsDirectory: URL { baseDirectory.appendingPathComponent("Tools", isDirectory: true) }
    var scratchDirectory: URL { baseDirectory.appendingPathComponent("PluginWork", isDirectory: true) }
    private var stateURL: URL { pluginsDirectory.appendingPathComponent("plugins.json") }
    private var order: [String] = []
    private var lastSync: Date?
    private var cachedCatalog: PluginCatalog?
    private let appVersion: String
    private var enabledObserver: AnyCancellable?

    /// `baseDirectory` nur für Tests; normal ~/Library/Application Support/BarDrop
    init(baseDirectory: URL? = nil, appVersion: String? = nil) {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        self.baseDirectory = baseDirectory ?? support.appendingPathComponent("BarDrop", isDirectory: true)
        self.appVersion = appVersion ?? (Bundle.main.object(forInfoDictionaryKey: "BarDropVersion") as? String ?? "1.31.0")
        try? FileManager.default.createDirectory(at: pluginsDirectory, withIntermediateDirectories: true)
        loadState()
        reload()
        // Arbeitsordner laufender Plugins vom letzten Mal sind verwaist
        try? FileManager.default.removeItem(at: scratchDirectory)
    }

    /// Beim Start der App: Katalog abgleichen, wenn die Plugins an sind (höchstens täglich)
    func start(settings: AppSettings = .shared) {
        enabledObserver = settings.$pluginsEnabled
            .removeDuplicates()
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] on in if on { self?.syncCatalog(force: true) } }
        if settings.pluginsEnabled {
            DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in self?.syncCatalog() }
        }
    }

    // MARK: Lesen

    /// Liest alle installierten Plugins neu von der Platte (nach Bearbeiten, Installieren).
    func reload() {
        let fm = FileManager.default
        let dirs = ((try? fm.contentsOfDirectory(at: pluginsDirectory, includingPropertiesForKeys: [.isDirectoryKey])) ?? [])
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true }
        var found: [InstalledPlugin] = []
        var errors: [String: String] = [:]
        for dir in dirs {
            do {
                let unpacked = try PluginPackage.read(directory: dir, appVersion: appVersion)
                guard unpacked.manifest.id == dir.lastPathComponent else { continue }
                let manifestData = (try? Data(contentsOf: dir.appendingPathComponent("manifest.json"))) ?? Data()
                let stamp = PluginPackage.fingerprint(manifest: manifestData, script: unpacked.script)
                found.append(InstalledPlugin(manifest: unpacked.manifest, directory: dir, script: unpacked.script,
                                             fingerprint: stamp, isStandard: states[unpacked.manifest.id]?.isStandard ?? false))
            } catch let error as PluginPackage.PackageError {
                errors[dir.lastPathComponent] = error.message
            } catch {
                errors[dir.lastPathComponent] = error.localizedDescription
            }
        }
        // Reihenfolge: gespeicherte zuerst, neue hinten; Standard-Plugins vor importierten
        found.sort { a, b in
            if a.isStandard != b.isStandard { return a.isStandard }
            let ia = order.firstIndex(of: a.id) ?? Int.max
            let ib = order.firstIndex(of: b.id) ?? Int.max
            if ia != ib { return ia < ib }
            return a.manifest.name.text.localizedCaseInsensitiveCompare(b.manifest.name.text) == .orderedAscending
        }
        // Geänderter Code: Erteilte Rechte gelten nicht mehr
        for plugin in found {
            var state = states[plugin.id] ?? PluginState()
            if state.grantedFingerprint != nil, state.grantedFingerprint != plugin.fingerprint {
                state.granted = []
                state.grantedFingerprint = nil
                states[plugin.id] = state
            }
        }
        if found != plugins { plugins = found }
        if errors != broken { broken = errors }
        order = found.map(\.id)
        saveState()
    }

    /// Liest ein einzelnes Plugin neu, bevor es läuft (es könnte bearbeitet worden sein).
    func refreshed(_ id: String) -> InstalledPlugin? {
        guard let current = plugin(id) else { return nil }
        let manifestData = (try? Data(contentsOf: current.manifestURL)) ?? Data()
        let script = (try? String(contentsOf: current.scriptURL, encoding: .utf8)) ?? ""
        if PluginPackage.fingerprint(manifest: manifestData, script: script) != current.fingerprint { reload() }
        return plugin(id)
    }

    func plugin(_ id: String?) -> InstalledPlugin? {
        guard let id else { return nil }
        return plugins.first { $0.id == id }
    }

    func state(_ id: String) -> PluginState { states[id] ?? PluginState() }

    // MARK: Zustand

    private struct Saved: Codable {
        var order: [String]
        var states: [String: PluginState]
        var lastSync: Date?
        var catalog: PluginCatalog?
    }

    private func loadState() {
        guard let data = try? Data(contentsOf: stateURL),
              let saved = try? JSONDecoder().decode(Saved.self, from: data) else { return }
        order = saved.order
        states = saved.states
        lastSync = saved.lastSync
        cachedCatalog = saved.catalog
    }

    private func saveState() {
        let saved = Saved(order: order, states: states, lastSync: lastSync, catalog: cachedCatalog)
        if let data = try? JSONEncoder().encode(saved) { try? data.write(to: stateURL, options: .atomic) }
    }

    func update(_ id: String, _ change: (inout PluginState) -> Void) {
        var state = states[id] ?? PluginState()
        change(&state)
        guard state != states[id] else { return }
        states[id] = state
        saveState()
    }

    /// Ist das Plugin eingeschaltet (und die Plugins überhaupt)?
    func isActive(_ id: String?, settings: AppSettings = .shared) -> Bool {
        guard settings.pluginsEnabled, let id, plugin(id) != nil else { return false }
        return state(id).enabled
    }

    var activePlugins: [InstalledPlugin] {
        guard AppSettings.shared.pluginsEnabled else { return [] }
        return plugins.filter { state($0.id).enabled }
    }

    /// Braucht ein eingeschaltetes Plugin diese Adresse als Link? (Beim Hineinziehen aus dem
    /// Browser kommt oft ein Vorschaubild mit; dann wird trotzdem der Link übernommen.)
    func wantsLink(_ url: URL) -> Bool {
        activePlugins.contains { PluginMatcher.matchesLink($0.manifest.match, url) }
    }

    func isAutomatic(_ plugin: InstalledPlugin) -> Bool {
        guard plugin.manifest.allTriggers.contains(.automatic) else { return false }
        return state(plugin.id).automatic ?? plugin.manifest.automaticDefault
    }

    func value(_ spec: PluginSettingSpec, of id: String) -> PluginValue {
        state(id).values[spec.key] ?? spec.defaultValue
    }

    func settingsValues(of plugin: InstalledPlugin) -> [String: Any] {
        var values: [String: Any] = [:]
        for spec in plugin.manifest.settings ?? [] { values[spec.key] = value(spec, of: plugin.id).any }
        values["replaceOriginal"] = state(plugin.id).replaceOriginal
        return values
    }

    func isGranted(_ permission: PluginPermission, for plugin: InstalledPlugin) -> Bool {
        let s = state(plugin.id)
        return s.grantedFingerprint == plugin.fingerprint && s.granted.contains(permission)
    }

    func grant(_ permission: PluginPermission, for plugin: InstalledPlugin) {
        update(plugin.id) { s in
            if s.grantedFingerprint != plugin.fingerprint { s.granted = [] }
            s.grantedFingerprint = plugin.fingerprint
            if !s.granted.contains(permission) { s.granted.append(permission) }
        }
    }

    func revokePermissions(_ id: String) {
        update(id) { s in
            s.granted = []
            s.grantedFingerprint = nil
        }
    }

    /// Reihenfolge ändern (nur innerhalb von Standard- bzw. importierten Plugins)
    func move(_ id: String, by offset: Int) {
        guard let i = plugins.firstIndex(where: { $0.id == id }) else { return }
        let j = i + offset
        guard plugins.indices.contains(j), plugins[i].isStandard == plugins[j].isStandard else { return }
        var list = plugins
        list.swapAt(i, j)
        plugins = list
        order = list.map(\.id)
        saveState()
    }

    // MARK: Installieren

    enum InstallError: Error {
        case package(PluginPackage.PackageError)
        case standardExists
        case failed(String)

        var message: String {
            switch self {
            case .package(let e): return e.message
            case .standardExists:
                return L("A standard plugin with this identifier is already installed.",
                         "Ein Standard-Plugin mit dieser Kennung ist schon installiert.")
            case .failed(let text): return text
            }
        }
    }

    /// Prüft eine .bdrop-Datei, ohne sie zu installieren (für den Dialog vor dem Import)
    func inspect(_ file: URL) throws -> PluginPackage.Unpacked {
        try FileManager.default.createDirectory(at: scratchDirectory, withIntermediateDirectories: true)
        do {
            return try PluginPackage.unpack(file, into: scratchDirectory, appVersion: appVersion)
        } catch let error as PluginPackage.PackageError {
            throw InstallError.package(error)
        }
    }

    /// Übernimmt ein geprüftes, entpacktes Plugin. Eine vorhandene Fassung wird ersetzt,
    /// Einstellungen bleiben; Rechte gelten danach nur weiter, wenn `keepPermissions`.
    @discardableResult
    func install(_ unpacked: PluginPackage.Unpacked, standard: Bool, keepPermissions: Bool = false) throws -> InstalledPlugin {
        let id = unpacked.manifest.id
        if !standard, state(id).isStandard, plugin(id) != nil { throw InstallError.standardExists }
        let fm = FileManager.default
        let target = pluginsDirectory.appendingPathComponent(id, isDirectory: true)
        let staging = pluginsDirectory.appendingPathComponent(".install-\(UUID().uuidString)", isDirectory: true)
        do {
            try fm.copyItem(at: unpacked.directory, to: staging)
            if fm.fileExists(atPath: target.path) {
                _ = try fm.replaceItemAt(target, withItemAt: staging)
            } else {
                try fm.moveItem(at: staging, to: target)
            }
        } catch {
            try? fm.removeItem(at: staging)
            throw InstallError.failed(error.localizedDescription)
        }
        try? fm.removeItem(at: unpacked.directory)
        let manifestData = (try? Data(contentsOf: target.appendingPathComponent("manifest.json"))) ?? Data()
        let stamp = PluginPackage.fingerprint(manifest: manifestData, script: unpacked.script)
        update(id) { s in
            s.isStandard = standard
            if keepPermissions, s.grantedFingerprint != nil {
                // Aktualisierung aus dem Katalog: Rechte, die es noch braucht, bleiben
                s.granted = s.granted.filter { unpacked.manifest.allPermissions.contains($0) }
                s.grantedFingerprint = stamp
            } else {
                s.granted = []
                s.grantedFingerprint = nil
            }
        }
        if !order.contains(id) { order.append(id) }
        reload()
        guard let installed = plugin(id) else { throw InstallError.failed(L("The plugin couldn’t be read.", "Das Plugin ließ sich nicht lesen.")) }
        return installed
    }

    /// Ordner eines installierten Plugins (auch eines, das sich nicht lesen lässt)
    func folder(of id: String) -> URL {
        pluginsDirectory.appendingPathComponent(id, isDirectory: true)
    }

    /// Entfernt ein Plugin, das sich nicht mehr lesen lässt (außer Standard-Plugins)
    func removeBroken(_ id: String) {
        guard broken[id] != nil, !state(id).isStandard else { return }
        uninstall(id)
    }

    /// Entfernt ein importiertes Plugin. Standard-Plugins lassen sich nur ausschalten.
    func remove(_ id: String) {
        guard let plugin = plugin(id), !plugin.isStandard else { return }
        uninstall(id)
    }

    private func uninstall(_ id: String) {
        try? FileManager.default.removeItem(at: pluginsDirectory.appendingPathComponent(id, isDirectory: true))
        states.removeValue(forKey: id)
        order.removeAll { $0 == id }
        reload()
        // Aktionen dieses Plugins aus der Leiste nehmen
        let settings = AppSettings.shared
        if settings.quickActions.contains(where: { $0.kind == .plugin && $0.path == id }) {
            settings.quickActions.removeAll { $0.kind == .plugin && $0.path == id }
        }
    }

    // MARK: Katalog

    /// Gleicht mit dem Katalog ab: Standard-Plugins installieren und still aktualisieren,
    /// zurückgezogene entfernen. Ohne `force` höchstens einmal am Tag.
    func syncCatalog(force: Bool = false, completion: (() -> Void)? = nil) {
        guard AppSettings.shared.pluginsEnabled, !syncing else { completion?(); return }
        if !force, let lastSync, Date().timeIntervalSince(lastSync) < 24 * 3600 { completion?(); return }
        syncing = true
        var request = URLRequest(url: Self.catalogURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.setValue("BarDrop/\(appVersion)", forHTTPHeaderField: "User-Agent")
        URLSession.shared.dataTask(with: request) { [weak self] data, response, _ in
            let ok = (response as? HTTPURLResponse)?.statusCode == 200
            let catalog = ok ? data.flatMap { try? JSONDecoder().decode(PluginCatalog.self, from: $0) } : nil
            DispatchQueue.main.async {
                guard let self else { return }
                guard let catalog, catalog.schema == 1 else {
                    self.syncing = false
                    self.syncFailed = true
                    self.applyCatalog(self.cachedCatalog, online: false)
                    completion?()
                    return
                }
                self.cachedCatalog = catalog
                self.lastSync = Date()
                self.syncFailed = false
                self.saveState()
                self.applyCatalog(catalog, online: true) {
                    self.syncing = false
                    completion?()
                }
            }
        }.resume()
    }

    private func applyCatalog(_ catalog: PluginCatalog?, online: Bool, completion: @escaping () -> Void = {}) {
        guard let catalog else {
            missingStandard = []
            catalogExtras = []
            return completion()
        }
        let usable = catalog.plugins.filter { entry in
            entry.minAppVersion.map { !Updater.isNewer($0, than: PluginManifest.releaseVersion(appVersion)) } ?? true
        }
        // Zurückgezogen: entfernen, auch Standard-Plugins (das darf nur der Katalog)
        for entry in catalog.plugins where entry.removed == true && plugin(entry.id) != nil {
            if state(entry.id).isStandard || entry.standard == true { uninstall(entry.id) }
        }
        let live = usable.filter { $0.removed != true }
        catalogExtras = live.filter { $0.standard != true && plugin($0.id) == nil }
        let needed = live.filter { entry in
            guard entry.standard == true || state(entry.id).isStandard else { return false }
            guard let installed = plugin(entry.id) else { return true }
            return Updater.isNewer(entry.version, than: installed.manifest.version)
        }
        guard online, !needed.isEmpty else {
            missingStandard = live.filter { $0.standard == true && plugin($0.id) == nil }
            return completion()
        }
        let group = DispatchGroup()
        for entry in needed {
            group.enter()
            download(entry) { [weak self] result in
                if let self, let unpacked = result {
                    _ = try? self.install(unpacked, standard: entry.standard == true || self.state(entry.id).isStandard,
                                          keepPermissions: true)
                }
                group.leave()
            }
        }
        group.notify(queue: .main) { [weak self] in
            guard let self else { return }
            self.missingStandard = live.filter { $0.standard == true && self.plugin($0.id) == nil }
            completion()
        }
    }

    /// Lädt ein Plugin aus dem Katalog und prüft seine Prüfsumme
    private func download(_ entry: PluginCatalogEntry, completion: @escaping (PluginPackage.Unpacked?) -> Void) {
        guard let url = URL(string: entry.url), url.scheme == "https" else { return completion(nil) }
        URLSession.shared.downloadTask(with: url) { [weak self] file, response, _ in
            guard let self, let file, (response as? HTTPURLResponse)?.statusCode == 200,
                  PluginPackage.sha256(of: file)?.lowercased() == entry.sha256.lowercased() else {
                DispatchQueue.main.async { completion(nil) }
                return
            }
            let renamed = file.deletingLastPathComponent().appendingPathComponent(UUID().uuidString + ".bdrop")
            try? FileManager.default.moveItem(at: file, to: renamed)
            let unpacked = try? self.inspect(renamed)
            try? FileManager.default.removeItem(at: renamed)
            DispatchQueue.main.async {
                completion(unpacked?.manifest.id == entry.id ? unpacked : nil)
            }
        }.resume()
    }

    /// Installiert ein weiteres Plugin aus dem Katalog (nicht Standard)
    func installFromCatalog(_ entry: PluginCatalogEntry, completion: @escaping (Bool) -> Void) {
        download(entry) { [weak self] unpacked in
            guard let self, let unpacked, (try? self.install(unpacked, standard: false)) != nil else { return completion(false) }
            self.catalogExtras.removeAll { $0.id == entry.id }
            completion(true)
        }
    }

    /// Alles zurücksetzen (Einstellungen → Alle Einstellungen zurücksetzen): Plugins
    /// bleiben installiert, sind aber aus und haben keine Rechte mehr.
    func resetAll() {
        for id in states.keys {
            update(id) { s in
                let standard = s.isStandard
                s = PluginState()
                s.isStandard = standard
            }
        }
    }
}
