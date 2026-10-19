import AppKit
import SwiftUI

/// Startet Plugins für Objekte der Ablage und bringt ihre Ergebnisse zurück:
/// über den Rechtsklick, die Aktionsleiste oder automatisch beim Ablegen.
///
/// Laufende Plugins erscheinen als Platzhalter direkt neben dem Original. Ist ein Plugin
/// fertig, liegt das Ergebnis an genau dieser Stelle und ist sofort mit Vorschau zu sehen.
final class PluginRunner: ObservableObject, PluginPrompter {
    @Published private(set) var jobs: [PluginJob] = []

    private let manager: PluginManager
    private weak var actions: ShelfActions?
    private var runtimes: [UUID: PluginRuntime] = [:]
    private lazy var tools = PluginTools(directory: manager.toolsDirectory)
    /// Höchstens so viele Plugins gleichzeitig; weitere warten (schont den Mac)
    static let maxConcurrent = 3
    private var waiting: [PluginJob] = []
    /// Fehler eines Laufs per Rechtsklick oder Aktionsleiste als Dialog zeigen (Tests: aus)
    var showsErrorDialogs = true

    init(manager: PluginManager = .shared, actions: ShelfActions) {
        self.manager = manager
        self.actions = actions
    }

    private var store: ShelfStore? { actions?.store }
    private var settings: AppSettings { AppSettings.shared }

    // MARK: Welche Plugins passen

    /// Eingeschaltete Plugins, die zu mindestens einer der Dateien passen und den Auslöser kennen
    func plugins(for urls: [URL], trigger: PluginTrigger) -> [InstalledPlugin] {
        let active = manager.activePlugins.filter { $0.manifest.allTriggers.contains(trigger) }
        guard !active.isEmpty, !urls.isEmpty else { return [] }
        let items = urls.prefix(50).map(PluginItem.init(url:))
        return active.filter { plugin in items.contains { PluginMatcher.matches(plugin.manifest.match, $0) } }
    }

    func job(for id: UUID?) -> PluginJob? {
        guard let id else { return nil }
        return jobs.first { $0.id == id }
    }

    /// Laufende Plugins, die neben dieser Datei erscheinen
    func jobs(nextTo fileIDs: [UUID]) -> [PluginJob] {
        guard !jobs.isEmpty else { return [] }
        let ids = Set(fileIDs)
        return jobs.filter { ids.contains($0.anchorFileID) && !$0.replacesOriginal }
    }

    // MARK: Starten

    /// Rechtsklick oder Aktionsleiste: das Plugin für alle passenden Dateien
    func run(_ pluginID: String, on files: [ShelfFile]) {
        guard let plugin = manager.refreshed(pluginID), manager.isActive(pluginID) else { return NSSound.beep() }
        let matching = files.filter { PluginMatcher.matches(plugin.manifest.match, PluginItem(url: $0.url)) }
        guard !matching.isEmpty else {
            NSSound.beep()
            actions?.announce(L("“\(plugin.manifest.name.text)” doesn’t work with this item",
                                "„\(plugin.manifest.name.text)“ passt nicht zu diesem Objekt"), duration: 1.6)
            return
        }
        // Läuft dasselbe Plugin schon für eine Datei, nicht ein zweites Mal starten
        let fresh = matching.filter { file in !jobs.contains { $0.anchorFileID == file.id && $0.plugin.id == plugin.id } }
        guard !fresh.isEmpty else {
            actions?.announce(L("\(plugin.manifest.title) is already running", "\(plugin.manifest.title) läuft schon"), duration: 1.6)
            return
        }
        guard confirmConsent(plugin) else { return }
        let replaces = replacesOriginal(plugin)
        for file in fresh {
            enqueue(PluginJob(plugin: plugin, item: PluginItem(url: file.url), anchorFileID: file.id, automatic: false,
                              replacesOriginal: replaces))
        }
        actions?.announce(L("\(plugin.manifest.title) running", "\(plugin.manifest.title) läuft"), duration: 1.5)
    }

    /// Frisch abgelegte Dateien: je Datei das erste passende Plugin mit „Automatisch“
    func handleDropped(_ files: [ShelfFile]) {
        guard settings.pluginsEnabled, !IntroGate.active else { return }
        let automatic = manager.activePlugins.filter { manager.isAutomatic($0) }
        guard !automatic.isEmpty else { return }
        var started: [String: Int] = [:]
        var blocked: InstalledPlugin?
        for file in files {
            let item = PluginItem(url: file.url)
            guard let plugin = automatic.first(where: { PluginMatcher.matches($0.manifest.match, item) }) else { continue }
            // Automatisch nur mit allen nötigen Rechten (beim Einschalten erteilt) und Zustimmung
            guard readyForAutomatic(plugin), approveTools(plugin) else {
                blocked = plugin
                PluginLog.shared.record(plugin.id, "fehler", "automatisch nicht gestartet: Zustimmung, Rechte oder Programme fehlen")
                continue
            }
            enqueue(PluginJob(plugin: plugin, item: item, anchorFileID: file.id, automatic: true,
                              replacesOriginal: replacesOriginal(plugin)))
            started[plugin.manifest.title, default: 0] += 1
        }
        if started.count == 1, let name = started.keys.first {
            actions?.announce(L("Plugin \(name) active", "Plugin \(name) aktiv"), duration: 1.5)
        } else if started.count > 1 {
            actions?.announce(L("\(started.count) plugins active", "\(started.count) Plugins aktiv"), duration: 1.5)
        } else if let blocked {
            actions?.announce(L("\(blocked.manifest.title) needs permission in Settings",
                                "\(blocked.manifest.title) braucht eine Erlaubnis in den Einstellungen"), duration: 2.5)
        }
    }

    /// Programme, die ein automatisches Plugin laden muss: einmal erlauben lassen (für
    /// Plugins, deren Automatik schon vor dieser Abfrage eingeschaltet wurde)
    private func approveTools(_ plugin: InstalledPlugin) -> Bool {
        for tool in plugin.manifest.tools ?? [] where !manager.state(plugin.id).approvedTools.contains(tool.id) {
            guard PluginDialogs.allowDownload(of: tool, for: plugin, ui: actions?.ui) else { return false }
            manager.update(plugin.id) { $0.approvedTools.append(tool.id) }
        }
        return true
    }

    /// „Original ersetzen“ ist für dieses Plugin an
    func replacesOriginal(_ plugin: InstalledPlugin) -> Bool {
        plugin.manifest.canReplaceOriginal == true && manager.state(plugin.id).replaceOriginal
    }

    /// Platzhalter, der an der Stelle dieser Datei steht (sie selbst ist dann nicht zu sehen)
    func replacingJob(for fileID: UUID) -> PluginJob? {
        guard !jobs.isEmpty else { return nil }
        return jobs.first { $0.replacesOriginal && $0.anchorFileID == fileID }
    }

    /// Hat das Plugin alles, um ohne Rückfrage zu laufen?
    func readyForAutomatic(_ plugin: InstalledPlugin) -> Bool {
        if plugin.manifest.consent != nil && !manager.state(plugin.id).consented { return false }
        return plugin.manifest.allPermissions.allSatisfy { manager.isGranted($0, for: plugin) }
    }

    private func enqueue(_ job: PluginJob) {
        withAnimation(.easeOut(duration: 0.2)) { jobs.append(job) }
        if runtimes.count < Self.maxConcurrent { launch(job) } else { waiting.append(job) }
    }

    private func launch(_ job: PluginJob) {
        let work = manager.scratchDirectory.appendingPathComponent(job.id.uuidString, isDirectory: true)
        let plugin = job.plugin
        let runtime = PluginRuntime(
            job: job, workDirectory: work, tools: tools, prompter: self,
            settingsValues: manager.settingsValues(of: plugin),
            granted: Set(plugin.manifest.allPermissions.filter { manager.isGranted($0, for: plugin) }),
            approvedTools: Set(manager.state(plugin.id).approvedTools),
            onGrant: { [weak self] permission in self?.manager.grant(permission, for: plugin) },
            onToolApproved: { [weak self] tool in
                self?.manager.update(plugin.id) { s in if !s.approvedTools.contains(tool) { s.approvedTools.append(tool) } }
            },
            onNotify: { [weak self] text in self?.actions?.announce(text, duration: 2) }
        )
        runtimes[job.id] = runtime
        PluginLog.shared.record(plugin.id, "start",
                                "\(plugin.manifest.version) \(job.automatic ? "automatisch" : "von Hand")\(job.replacesOriginal ? ", ersetzt Original" : "") · \(job.item.kind.rawValue) „\(job.item.url.lastPathComponent)“\(job.item.link.map { " " + $0.absoluteString } ?? "")")
        runtime.start { [weak self] result in
            self?.finished(job, result: result, workDirectory: work)
        }
    }

    private func finished(_ job: PluginJob, result: Result<[URL], PluginRunError>, workDirectory: URL) {
        runtimes.removeValue(forKey: job.id)
        defer {
            try? FileManager.default.removeItem(at: workDirectory)
            if !waiting.isEmpty, runtimes.count < Self.maxConcurrent { launch(waiting.removeFirst()) }
        }
        switch result {
        case .success(let urls):
            PluginLog.shared.record(job.plugin.id, "ok", urls.isEmpty ? "fertig, kein Ergebnis"
                                    : "fertig: " + urls.map { "„\($0.lastPathComponent)“" }.joined(separator: ", "))
            manager.lastErrors.removeValue(forKey: job.plugin.id)
            deliver(job, urls)
        case .failure(.cancelled):
            PluginLog.shared.record(job.plugin.id, "abbruch", "abgebrochen")
            removeJob(job)
            actions?.announce(L("Cancelled", "Abgebrochen"), duration: 1.5)
        case .failure(let error):
            PluginLog.shared.record(job.plugin.id, "fehler", error.message)
            manager.lastErrors[job.plugin.id] = String(error.message.prefix(600))
            removeJob(job)
            NSSound.beep()
            actions?.announce(L("\(job.title) didn’t work", "\(job.title) hat nicht geklappt"), duration: 2.5)
            if !job.automatic && showsErrorDialogs { showError(error, of: job.plugin) }
        }
    }

    /// Ergebnis an die Stelle des Platzhalters. Die Vorschaubilder entstehen schon, solange
    /// noch der Platzhalter steht: Die neue Kachel erscheint dann sofort fertig gezeichnet,
    /// nicht erst als leere Fläche oder beim nächsten Öffnen der Ablage.
    private func deliver(_ job: PluginJob, _ urls: [URL]) {
        guard let store, !urls.isEmpty else {
            removeJob(job)
            return
        }
        let files = store.adoptResults(urls)
        guard !files.isEmpty else { return removeJob(job) }
        let size = CGFloat(settings.tileIconSize)
        let previews = files.map(\.url).filter(ThumbnailView.expectsPreview)
        Task { @MainActor [weak self] in
            // Höchstens kurz warten: Liefert Quick Look nichts, kommt das Symbol
            await withTaskGroup(of: Void.self) { group in
                group.addTask {
                    for url in previews {
                        _ = await Thumbnails.load(url, size: size)
                    }
                }
                group.addTask { try? await Task.sleep(nanoseconds: 1_500_000_000) }
                await group.next()
                group.cancelAll()
            }
            self?.place(job, files)
        }
    }

    private func place(_ job: PluginJob, _ files: [ShelfFile]) {
        guard let store else { return }
        for file in files { Thumbnails.shownOnce.insert(file.url.path) }
        store.insertResults(files, nextTo: job.anchorFileID,
                            newestFirst: settings.sortOrder == .newestFirst, replacing: job.replacesOriginal)
        removeJob(job, animated: false)
        NotificationCenter.default.post(name: Thumbnails.didChange, object: nil)
        if let actions {
            let ids = Set(files.map(\.id))
            if actions.isInStack {
                actions.ui.memberSelection = ids.intersection(actions.stackFiles.map(\.id))
            } else {
                actions.ui.selection = Set(store.entries.filter { $0.files.contains { ids.contains($0.id) } }.map(\.id))
            }
        }
    }

    private func removeJob(_ job: PluginJob, animated: Bool = true) {
        if animated {
            withAnimation(.easeOut(duration: 0.2)) { jobs.removeAll { $0.id == job.id } }
        } else {
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) { jobs.removeAll { $0.id == job.id } }
        }
        waiting.removeAll { $0.id == job.id }
    }

    /// Abbrechen auch, solange ein Plugin noch wartet
    func cancel(_ job: PluginJob) {
        if waiting.contains(where: { $0.id == job.id }) {
            removeJob(job)
            return
        }
        job.cancel()
    }

    /// Beim Beenden: laufende Plugins abbrechen
    func cancelAll() {
        waiting.removeAll()
        runtimes.values.forEach { $0.cancel() }
    }

    // MARK: Rückfragen

    /// Zustimmung zum Hinweis des Plugins, einmalig
    func confirmConsent(_ plugin: InstalledPlugin) -> Bool {
        PluginDialogs.confirmConsent(plugin, manager: manager, ui: actions?.ui)
    }

    func allow(_ permission: PluginPermission, for plugin: InstalledPlugin) -> Bool {
        PluginDialogs.allow(permission, for: plugin, ui: actions?.ui)
    }

    func allowDownload(of tool: PluginTool, for plugin: InstalledPlugin) -> Bool {
        PluginDialogs.allowDownload(of: tool, for: plugin, ui: actions?.ui)
    }

    private func showError(_ error: PluginRunError, of plugin: InstalledPlugin) {
        DispatchQueue.main.async { [weak self] in
            PluginDialogs.showError(error.message, of: plugin, ui: self?.actions?.ui)
        }
    }
}
