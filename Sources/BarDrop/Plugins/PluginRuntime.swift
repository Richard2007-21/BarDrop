import AppKit
import JavaScriptCore

/// Fragen an den Nutzer, die ein laufendes Plugin auslösen kann (immer auf dem Hauptthread).
protocol PluginPrompter: AnyObject {
    /// Ein Plugin möchte ein Recht zum ersten Mal nutzen
    func allow(_ permission: PluginPermission, for plugin: InstalledPlugin) -> Bool
    /// Ein Plugin braucht ein Programm, das erst geladen werden muss
    func allowDownload(of tool: PluginTool, for plugin: InstalledPlugin) -> Bool
}

/// Ein laufendes Plugin: Fortschritt für den Platzhalter in der Ablage, Anhalten,
/// Fortsetzen und Abbrechen über den Rechtsklick.
final class PluginJob: ObservableObject, Identifiable {
    let id = UUID()
    let plugin: InstalledPlugin
    let item: PluginItem
    /// Datei der Ablage, neben der das Ergebnis erscheint
    let anchorFileID: UUID
    let automatic: Bool
    /// 0…1, nil solange das Plugin keinen Fortschritt meldet
    @Published fileprivate(set) var progress: Double?
    @Published fileprivate(set) var label: String?
    @Published fileprivate(set) var paused = false

    fileprivate weak var runtime: PluginRuntime?
    /// Letzte Meldung an die Oberfläche (höchstens alle 100 ms, sonst zeichnet die Ablage zu oft)
    private var lastPublished = Date.distantPast

    init(plugin: InstalledPlugin, item: PluginItem, anchorFileID: UUID, automatic: Bool) {
        self.plugin = plugin
        self.item = item
        self.anchorFileID = anchorFileID
        self.automatic = automatic
    }

    var title: String { plugin.manifest.title }

    /// Läuft schon (sonst wartet es, weil schon drei Plugins laufen)
    @Published fileprivate(set) var isStarted = false

    /// Fortschritt in Prozent für Menüs, nil ohne Angabe
    var percent: Int? { progress.map { Int(($0 * 100).rounded()) } }

    func pause() { runtime?.setPaused(true) }
    func resume() { runtime?.setPaused(false) }
    func cancel() { runtime?.cancel() }

    func report(_ value: Double?, label newLabel: String?, force: Bool = false) {
        let clamped = value.map { min(max($0, 0), 1) }
        let now = Date()
        guard force || now.timeIntervalSince(lastPublished) > 0.1 || clamped == 1 else { return }
        lastPublished = now
        if clamped != progress { progress = clamped }
        // Leerer Text nimmt die Beschriftung zurück (dann steht wieder der Name da)
        if let newLabel {
            let value = newLabel.isEmpty ? nil : newLabel
            if value != label { label = value }
        }
        NotificationCenter.default.post(name: Thumbnails.didChange, object: nil)
    }

    fileprivate func setPausedState(_ value: Bool) {
        paused = value
        NotificationCenter.default.post(name: Thumbnails.didChange, object: nil)
    }
}

enum PluginRunError: Error, Equatable {
    case cancelled
    case script(String)
    case permissionDenied(PluginPermission)

    var message: String {
        switch self {
        case .cancelled: return L("Cancelled", "Abgebrochen")
        case .script(let text): return text
        case .permissionDenied(let p): return L("Not allowed: \(p.title)", "Nicht erlaubt: \(p.title)")
        }
    }
}

/// Führt das Skript eines Plugins in JavaScriptCore aus, in einem eigenen, kurzlebigen
/// Kontext auf einer eigenen Warteschlange. Das Skript sieht nur `bardrop`: Dateien schreibt
/// es nur in seinen Ausgabeordner, alles Weitere (Internet, Programme, Zwischenablage)
/// geht über Rechte, die beim ersten Gebrauch erfragt werden.
///
/// Was am Ende im Ausgabeordner liegt, wird zu neuen Objekten neben dem Original.
final class PluginRuntime {
    let job: PluginJob
    private let plugin: InstalledPlugin
    private let workDirectory: URL
    let outputDirectory: URL
    private let tools: PluginTools
    private weak var prompter: PluginPrompter?
    private let queue: DispatchQueue
    /// Beim Start auf dem Hauptthread festgehalten: Das Skript läuft im Hintergrund und
    /// liest die Verwaltung nicht selbst
    private let settingsValues: [String: Any]
    private var granted: Set<PluginPermission>
    /// Programme, deren Download schon erlaubt ist (gilt auch ohne Rückfrage)
    private var approvedTools: Set<String>
    private let onGrant: (PluginPermission) -> Void
    private let onToolApproved: (String) -> Void
    private let onNotify: (String) -> Void

    private var context: JSContext?
    /// Beim Start festgehalten (Updater gehört dem Hauptthread)
    private let appVersion = Updater.shared.currentVersion
    private var completion: ((Result<[URL], PluginRunError>) -> Void)?

    private let lock = NSLock()
    private var processes: [Process] = []
    private var tasks: [URLSessionTask] = []
    private var _cancelled = false
    private var _paused = false

    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return _cancelled }

    init(job: PluginJob, workDirectory: URL, tools: PluginTools, prompter: PluginPrompter?,
         settingsValues: [String: Any], granted: Set<PluginPermission>, approvedTools: Set<String> = [],
         onGrant: @escaping (PluginPermission) -> Void, onToolApproved: @escaping (String) -> Void = { _ in },
         onNotify: @escaping (String) -> Void) {
        self.job = job
        self.plugin = job.plugin
        self.workDirectory = workDirectory
        self.outputDirectory = workDirectory.appendingPathComponent("Output", isDirectory: true)
        self.tools = tools
        self.prompter = prompter
        self.settingsValues = settingsValues
        self.granted = granted
        self.approvedTools = approvedTools
        self.onGrant = onGrant
        self.onToolApproved = onToolApproved
        self.onNotify = onNotify
        self.queue = DispatchQueue(label: "BarDrop.plugin.\(job.plugin.id)", qos: .userInitiated)
        job.runtime = self
        job.isStarted = true
    }

    // MARK: Start und Ende

    /// Startet das Skript. `completion` kommt auf dem Hauptthread, genau einmal.
    func start(completion: @escaping (Result<[URL], PluginRunError>) -> Void) {
        self.completion = completion
        try? FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        queue.async { [self] in
            let vm = JSVirtualMachine()
            guard let context = JSContext(virtualMachine: vm) else {
                return finish(.failure(.script("JavaScriptCore")))
            }
            self.context = context
            context.name = plugin.manifest.name.text(for: .english)
            context.exceptionHandler = { [weak self] _, exception in
                self?.finish(.failure(.script(PluginRuntime.describe(exception))))
            }
            installAPI(in: context)
            // console.log & Co. landen im Diagnoseprotokoll (JavaScriptCore kennt kein console)
            context.evaluateScript("""
            var console = (function () {
              function line(args) { return Array.prototype.map.call(args, function (a) {
                try { return typeof a === 'string' ? a : JSON.stringify(a); } catch (e) { return String(a); } }).join(' '); }
              return { log: function () { bardrop.log(line(arguments)); },
                       info: function () { bardrop.log(line(arguments)); },
                       warn: function () { bardrop.log('warn: ' + line(arguments)); },
                       error: function () { bardrop.log('error: ' + line(arguments)); } };
            })();
            """)
            context.evaluateScript(plugin.script, withSourceURL: plugin.scriptURL)
            guard self.completion != nil else { return }
            guard context.objectForKeyedSubscript("run")?.isObject == true else {
                return finish(.failure(.script(L("The script has no function “run”.", "Im Skript fehlt die Funktion „run“."))))
            }
            let bootstrap = """
            (function (item) {
              return Promise.resolve().then(function () { return run(item); })
                .then(function () { __bardropDone(); },
                      function (e) { __bardropFail(e); });
            })
            """
            context.evaluateScript(bootstrap)?.call(withArguments: [job.item.scriptValue])
        }
    }

    /// Fehlermeldung eines Skripts: Text, bei Fehlern im Skript mit Datei und Zeile
    /// („TypeError: … (main.js:12)“), damit man die Stelle findet
    static func describe(_ error: JSValue?) -> String {
        guard let error, !error.isUndefined, !error.isNull else { return "Error" }
        guard error.isObject, error.hasProperty("message") else { return error.toString() ?? "Error" }
        let message = error.forProperty("message")?.toString() ?? ""
        let name = error.forProperty("name")?.toString() ?? ""
        var text = name.isEmpty || name == "Error" ? message : "\(name): \(message)"
        if let line = error.forProperty("line"), line.isNumber, line.toInt32() > 0 {
            let source = error.forProperty("sourceURL").flatMap { $0.isString ? URL(string: $0.toString())?.lastPathComponent : nil }
            text += " (\(source ?? "script"):\(line.toInt32()))"
        }
        return text.isEmpty ? "Error" : text
    }

    /// Nur auf `queue`
    private func finish(_ result: Result<[URL], PluginRunError>) {
        guard let completion else { return }
        self.completion = nil
        var final = result
        if isCancelled { final = .failure(.cancelled) }
        if case .success = final {
            final = .success(collectOutput())
        }
        lock.lock()
        let running = processes
        processes = []
        tasks.forEach { $0.cancel() }
        tasks = []
        lock.unlock()
        for process in running where process.isRunning {
            ProcessTree.signal(process.processIdentifier, SIGCONT)
            ProcessTree.signal(process.processIdentifier, SIGTERM)
        }
        // Kontext freigeben, aber nicht mitten in einem eigenen Aufruf
        queue.async { [weak self] in self?.context = nil }
        DispatchQueue.main.async { completion(final) }
    }

    /// Fertige Dateien im Ausgabeordner, ohne versteckte und halb geladene
    private func collectOutput() -> [URL] {
        let partial: Set<String> = ["part", "ytdl", "tmp", "download", "crdownload"]
        let items = (try? FileManager.default.contentsOfDirectory(at: outputDirectory, includingPropertiesForKeys: nil)) ?? []
        return items.filter { !$0.lastPathComponent.hasPrefix(".") && !partial.contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    func cancel() {
        lock.lock()
        guard !_cancelled else { lock.unlock(); return }
        _cancelled = true
        let running = processes
        let open = tasks
        lock.unlock()
        for process in running where process.isRunning {
            let pid = process.processIdentifier
            ProcessTree.signal(pid, SIGCONT)
            ProcessTree.signal(pid, SIGTERM)
        }
        open.forEach { $0.cancel() }
        queue.async { [weak self] in self?.finish(.failure(.cancelled)) }
    }

    /// Anhalten: laufende Programme stehen (SIGSTOP), Downloads pausieren. Fortsetzen
    /// macht an derselben Stelle weiter. Beim Beenden von BarDrop ist beides verloren.
    func setPaused(_ paused: Bool) {
        lock.lock()
        guard _paused != paused, !_cancelled else { lock.unlock(); return }
        _paused = paused
        let running = processes
        let open = tasks
        lock.unlock()
        for process in running where process.isRunning {
            ProcessTree.signal(process.processIdentifier, paused ? SIGSTOP : SIGCONT)
        }
        open.forEach { paused ? $0.suspend() : $0.resume() }
        DispatchQueue.main.async { self.job.setPausedState(paused) }
    }

    // MARK: Schnittstelle für das Skript

    private func installAPI(in context: JSContext) {
        let api = JSValue(newObjectIn: context)!
        let language = AppLanguage.current.resolved == .german ? "de" : "en"

        func set(_ name: String, _ block: Any) {
            api.setObject(block, forKeyedSubscript: name as NSString)
        }

        api.setObject(language, forKeyedSubscript: "language" as NSString)
        api.setObject(appVersion, forKeyedSubscript: "appVersion" as NSString)
        api.setObject(outputDirectory.path, forKeyedSubscript: "outputDirectory" as NSString)
        api.setObject(["id": plugin.id, "version": plugin.manifest.version], forKeyedSubscript: "plugin" as NSString)
        api.setObject(settingsValues, forKeyedSubscript: "settings" as NSString)

        let log: @convention(block) (JSValue) -> Void = { [plugin] value in
            let text = String((value.toString() ?? "").prefix(300))
            DispatchQueue.main.async { Diagnostics.shared.record("plugin", "\(plugin.id): \(text)") }
        }
        set("log", log)

        let progress: @convention(block) (JSValue, JSValue) -> Void = { [weak self] value, label in
            guard let self else { return }
            let fraction: Double? = value.isNumber ? value.toDouble() : nil
            let text: String? = label.isString ? String(label.toString().prefix(60)) : nil
            DispatchQueue.main.async { self.job.report(fraction, label: text) }
        }
        set("progress", progress)

        let cancelled: @convention(block) () -> Bool = { [weak self] in self?.isCancelled ?? true }
        set("isCancelled", cancelled)

        let notify: @convention(block) (JSValue) -> Void = { [weak self] value in
            let text = String(value.toString().prefix(80))
            DispatchQueue.main.async { self?.onNotify(text) }
        }
        set("notify", notify)

        let writeFile: @convention(block) (JSValue, JSValue) -> JSValue = { [weak self] name, contents in
            guard let self, let ctx = JSContext.current() else { return JSValue(undefinedIn: JSContext.current()) }
            guard name.isString, !contents.isUndefined, !contents.isNull else {
                ctx.exception = JSValue(newErrorFromMessage: L("writeFile needs a name and a text.", "writeFile braucht einen Namen und einen Text."), in: ctx)
                return JSValue(undefinedIn: ctx)
            }
            let target = self.newOutputURL(name.toString())
            do {
                try contents.toString().write(to: target, atomically: true, encoding: .utf8)
                return JSValue(object: target.path, in: ctx)
            } catch {
                ctx.exception = JSValue(newErrorFromMessage: error.localizedDescription, in: ctx)
                return JSValue(undefinedIn: ctx)
            }
        }
        set("writeFile", writeFile)

        let createLink: @convention(block) (JSValue, JSValue) -> JSValue = { [weak self] address, title in
            guard let self, let ctx = JSContext.current() else { return JSValue(undefinedIn: JSContext.current()) }
            guard address.isString, let link = URL(string: address.toString()), link.scheme != nil else {
                ctx.exception = JSValue(newErrorFromMessage: L("Invalid web address.", "Ungültige Webadresse."), in: ctx)
                return JSValue(undefinedIn: ctx)
            }
            let name = title.isString ? title.toString()! : (link.host ?? "Link")
            let target = self.newOutputURL(ContentImporter.sanitize(name) + ".webloc")
            let plist = ["URL": link.absoluteString]
            if let data = try? PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0) {
                try? data.write(to: target)
            }
            return JSValue(object: target.path, in: ctx)
        }
        set("createLink", createLink)

        let readFile: @convention(block) (JSValue) -> JSValue = { [weak self] path in
            guard let self, let ctx = JSContext.current() else { return JSValue(undefinedIn: JSContext.current()) }
            // Ohne „/“ am Anfang: relativ zum Ausgabeordner
            guard path.isString else {
                ctx.exception = JSValue(newErrorFromMessage: L("readFile needs a path.", "readFile braucht einen Pfad."), in: ctx)
                return JSValue(undefinedIn: ctx)
            }
            let raw = path.toString() ?? ""
            let url = (raw.hasPrefix("/") ? URL(fileURLWithPath: raw)
                       : self.outputDirectory.appendingPathComponent(raw)).standardizedFileURL
            guard self.mayRead(url) else {
                ctx.exception = JSValue(newErrorFromMessage: L("The plugin may only read the item itself, its output folder and its own files.", "Das Plugin darf nur das Objekt selbst, seinen Ausgabeordner und seine eigenen Dateien lesen."), in: ctx)
                return JSValue(undefinedIn: ctx)
            }
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
            guard size <= 20 * 1024 * 1024, let data = try? Data(contentsOf: url) else {
                ctx.exception = JSValue(newErrorFromMessage: L("The file can’t be read (missing or larger than 20 MB).", "Die Datei lässt sich nicht lesen (fehlt oder ist größer als 20 MB)."), in: ctx)
                return JSValue(undefinedIn: ctx)
            }
            let text = String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
            return JSValue(object: text, in: ctx)
        }
        set("readFile", readFile)

        let clipboard: @convention(block) (JSValue) -> Void = { [weak self] text in
            guard let self, self.require(.clipboard) else { return }
            let string = text.toString() ?? ""
            DispatchQueue.main.async {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(string, forType: .string)
            }
        }
        set("setClipboard", clipboard)

        let fetch: @convention(block) (JSValue, JSValue) -> JSValue = { [weak self] address, options in
            self?.promise { resolve, reject in self?.fetch(address, options, resolve, reject) }
                ?? JSValue(undefinedIn: JSContext.current())
        }
        set("fetch", fetch)

        let download: @convention(block) (JSValue, JSValue) -> JSValue = { [weak self] address, options in
            self?.promise { resolve, reject in self?.download(address, options, resolve, reject) }
                ?? JSValue(undefinedIn: JSContext.current())
        }
        set("download", download)

        let sleep: @convention(block) (JSValue) -> JSValue = { [weak self] ms in
            let seconds = max(0, min(ms.isNumber ? ms.toDouble() / 1000 : 0, 3600))
            return self?.promise { resolve, _ in
                DispatchQueue.global().asyncAfter(deadline: .now() + seconds) { resolve(nil) }
            } ?? JSValue(undefinedIn: JSContext.current())
        }
        set("sleep", sleep)

        let run: @convention(block) (JSValue, JSValue, JSValue) -> JSValue = { [weak self] command, args, options in
            self?.promise { resolve, reject in self?.run(command, args, options, resolve, reject) }
                ?? JSValue(undefinedIn: JSContext.current())
        }
        set("run", run)

        context.setObject(api, forKeyedSubscript: "bardrop" as NSString)

        let done: @convention(block) () -> Void = { [weak self] in self?.finish(.success([])) }
        context.setObject(done, forKeyedSubscript: "__bardropDone" as NSString)
        let fail: @convention(block) (JSValue) -> Void = { [weak self] error in
            self?.finish(.failure(.script(PluginRuntime.describe(error))))
        }
        context.setObject(fail, forKeyedSubscript: "__bardropFail" as NSString)
    }

    /// Ein Versprechen für das Skript. `body` läuft sofort; resolve/reject dürfen später
    /// aus beliebigen Threads kommen und werden auf die Warteschlange des Skripts gelegt.
    private func promise(_ body: @escaping (@escaping (Any?) -> Void, @escaping (String) -> Void) -> Void) -> JSValue? {
        guard let ctx = JSContext.current() else { return nil }
        var resolveFn: JSValue?
        var rejectFn: JSValue?
        let promise = JSValue(newPromiseIn: ctx) { resolve, reject in
            resolveFn = resolve
            rejectFn = reject
        }
        let resolve: (Any?) -> Void = { [weak self] value in
            self?.queue.async {
                guard self?.completion != nil else { return }
                resolveFn?.call(withArguments: value.map { [$0] } ?? [])
                resolveFn = nil
                rejectFn = nil
            }
        }
        let reject: (String) -> Void = { [weak self] message in
            self?.queue.async {
                guard self?.completion != nil, let reject = rejectFn else { return }
                reject.call(withArguments: [JSValue(newErrorFromMessage: message, in: reject.context)!])
                resolveFn = nil
                rejectFn = nil
            }
        }
        body(resolve, reject)
        return promise
    }

    // MARK: Rechte

    /// Darf das Plugin das? Fragt beim ersten Gebrauch (nicht bei automatischen Läufen).
    /// Läuft auf der Warteschlange des Skripts.
    private func require(_ permission: PluginPermission) -> Bool {
        guard plugin.manifest.allPermissions.contains(permission) else {
            if let ctx = JSContext.current() {
                ctx.exception = JSValue(newErrorFromMessage: L("The permission “\(permission.rawValue)” is missing in manifest.json.",
                                                                 "Das Recht „\(permission.rawValue)“ fehlt in der manifest.json."), in: ctx)
            }
            return false
        }
        lock.lock()
        let has = granted.contains(permission)
        lock.unlock()
        if has { return true }
        guard !job.automatic, let prompter else { return false }
        let plugin = plugin
        let allowed = DispatchQueue.main.sync { prompter.allow(permission, for: plugin) }
        if allowed {
            lock.lock(); granted.insert(permission); lock.unlock()
            DispatchQueue.main.async { self.onGrant(permission) }
        }
        return allowed
    }

    private func mayRead(_ url: URL) -> Bool {
        let path = url.path
        let roots = [outputDirectory.standardizedFileURL.path, plugin.directory.standardizedFileURL.path]
        return path == job.item.url.standardizedFileURL.path || roots.contains { path.hasPrefix($0 + "/") }
    }

    /// Neuer Name im Ausgabeordner, ohne etwas zu überschreiben
    private func newOutputURL(_ name: String) -> URL {
        var clean = ContentImporter.sanitize((name as NSString).lastPathComponent)
        if clean.isEmpty { clean = "Item" }
        return ShelfActions.uniqueURL(for: clean, in: outputDirectory)
    }

    private func track(_ task: URLSessionTask) {
        lock.lock()
        tasks.append(task)
        let paused = _paused
        lock.unlock()
        task.resume()
        if paused { task.suspend() }
    }

    /// Fertige Anfragen vergessen
    private func untrackFinished() {
        lock.lock(); tasks.removeAll { $0.state == .completed }; lock.unlock()
    }

    // MARK: Internet

    private func request(_ address: JSValue, _ options: JSValue) -> URLRequest? {
        guard let url = URL(string: address.toString()), url.scheme == "https" || url.scheme == "http" else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 60)
        request.setValue("BarDrop/\(appVersion)", forHTTPHeaderField: "User-Agent")
        if options.isObject {
            if let method = options.forProperty("method"), method.isString { request.httpMethod = method.toString() }
            if let headers = options.forProperty("headers")?.toDictionary() as? [String: Any] {
                for (key, value) in headers { request.setValue("\(value)", forHTTPHeaderField: key) }
            }
            if let body = options.forProperty("body"), body.isString { request.httpBody = Data(body.toString().utf8) }
        }
        return request
    }

    private func fetch(_ address: JSValue, _ options: JSValue,
                       _ resolve: @escaping (Any?) -> Void, _ reject: @escaping (String) -> Void) {
        guard require(.network) else { return reject(L("Internet access isn’t allowed.", "Der Zugriff aufs Internet ist nicht erlaubt.")) }
        guard let request = request(address, options) else { return reject(L("Invalid web address.", "Ungültige Webadresse.")) }
        let task = URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            self?.untrackFinished()
            if let error { return reject(error.localizedDescription) }
            let http = response as? HTTPURLResponse
            let limited = (data ?? Data()).prefix(20 * 1024 * 1024)
            var headers: [String: String] = [:]
            for (key, value) in http?.allHeaderFields ?? [:] { headers["\(key)".lowercased()] = "\(value)" }
            resolve(["status": http?.statusCode ?? 0,
                     "url": response?.url?.absoluteString ?? "",
                     "headers": headers,
                     "text": String(data: limited, encoding: .utf8) ?? String(decoding: limited, as: UTF8.self)])
        }
        track(task)
    }

    private func download(_ address: JSValue, _ options: JSValue,
                          _ resolve: @escaping (Any?) -> Void, _ reject: @escaping (String) -> Void) {
        guard require(.network) else { return reject(L("Internet access isn’t allowed.", "Der Zugriff aufs Internet ist nicht erlaubt.")) }
        guard let request = request(address, options) else { return reject(L("Invalid web address.", "Ungültige Webadresse.")) }
        let wanted = options.isObject ? options.forProperty("name").flatMap { $0.isString ? $0.toString() : nil } : nil
        let observation = ObservationHolder()
        let task = URLSession.shared.downloadTask(with: request) { [weak self] file, response, error in
            observation.invalidate()
            guard let self else { return }
            self.untrackFinished()
            if let error { return reject(error.localizedDescription) }
            guard let file, let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                return reject(L("The server answered with status \((response as? HTTPURLResponse)?.statusCode ?? 0).",
                                 "Der Server antwortete mit Status \((response as? HTTPURLResponse)?.statusCode ?? 0)."))
            }
            let name = wanted ?? response?.suggestedFilename ?? request.url?.lastPathComponent ?? "Download"
            let target = self.newOutputURL(name)
            do {
                try FileManager.default.moveItem(at: file, to: target)
                resolve(target.path)
            } catch {
                reject(error.localizedDescription)
            }
        }
        observation.set(task.progress.observe(\.fractionCompleted) { [weak self] progress, _ in
            let value = progress.fractionCompleted
            DispatchQueue.main.async { self?.job.report(value, label: nil) }
        })
        track(task)
    }

    // MARK: Programme

    /// Orte für Programme ohne Pfad: System und Homebrew
    private static let searchPaths = ["/usr/bin", "/bin", "/usr/sbin", "/sbin", "/opt/homebrew/bin", "/usr/local/bin"]

    private func run(_ command: JSValue, _ args: JSValue, _ options: JSValue,
                     _ resolve: @escaping (Any?) -> Void, _ reject: @escaping (String) -> Void) {
        guard require(.run) else { return reject(L("Running programs isn’t allowed.", "Programme auszuführen ist nicht erlaubt.")) }
        let name = command.toString() ?? ""
        let arguments = (args.toArray() ?? []).map { "\($0)" }
        let onOutput: JSValue? = options.isObject ? options.forProperty("onOutput").flatMap { $0.isObject ? $0 : nil } : nil
        let automatic = job.automatic
        let plugin = plugin
        // Werkzeuge erst laden (kann dauern), nicht auf der Warteschlange des Skripts
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let executable: URL
            do {
                executable = try self.resolveExecutable(name, automatic: automatic, plugin: plugin)
            } catch let error as PluginTools.ToolError {
                return reject(error.message)
            } catch let error as PluginRunError {
                return reject(error.message)
            } catch {
                return reject(error.localizedDescription)
            }
            self.launch(executable, arguments, onOutput: onOutput, resolve, reject)
        }
    }

    private func resolveExecutable(_ name: String, automatic: Bool, plugin: InstalledPlugin) throws -> URL {
        if let tool = plugin.manifest.tools?.first(where: { $0.id == name }) {
            // Muss erst geladen werden: am Platzhalter zeigen, was gerade passiert
            let loading = tools.installed(tool) == nil
            if loading {
                DispatchQueue.main.async { self.job.report(nil, label: L("Loading \(tool.name)", "Lädt \(tool.name)"), force: true) }
            }
            defer {
                if loading { DispatchQueue.main.async { self.job.report(nil, label: "", force: true) } }
            }
            return try tools.ensure(tool, ask: {
                self.lock.lock()
                let approved = self.approvedTools.contains(tool.id)
                self.lock.unlock()
                if approved { return true }
                guard !automatic, let prompter = self.prompter else { return false }
                let allowed = DispatchQueue.main.sync { prompter.allowDownload(of: tool, for: plugin) }
                if allowed {
                    self.lock.lock(); self.approvedTools.insert(tool.id); self.lock.unlock()
                    DispatchQueue.main.async { self.onToolApproved(tool.id) }
                }
                return allowed
            }, cancelled: { self.isCancelled })
        }
        if name.hasPrefix("/") {
            guard FileManager.default.isExecutableFile(atPath: name) else {
                throw PluginRunError.script(L("Program not found: \(name)", "Programm nicht gefunden: \(name)"))
            }
            return URL(fileURLWithPath: name)
        }
        guard !name.contains("/"),
              let path = Self.searchPaths.map({ $0 + "/" + name }).first(where: FileManager.default.isExecutableFile) else {
            throw PluginRunError.script(L("Program not found: \(name)", "Programm nicht gefunden: \(name)"))
        }
        return URL(fileURLWithPath: path)
    }

    private func launch(_ executable: URL, _ arguments: [String], onOutput: JSValue?,
                        _ resolve: @escaping (Any?) -> Void, _ reject: @escaping (String) -> Void) {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = outputDirectory
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = ([tools.directory.path] + Self.searchPaths).joined(separator: ":")
        environment["BARDROP_OUTPUT"] = outputDirectory.path
        process.environment = environment
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        process.standardInput = FileHandle.nullDevice

        let collected = OutputCollector()
        let lineHandler: (String) -> Void = { [weak self] line in
            guard let self, let onOutput else { return }
            self.queue.async {
                guard self.completion != nil else { return }
                onOutput.call(withArguments: [line])
            }
        }
        out.fileHandleForReading.readabilityHandler = { handle in
            collected.add(handle.availableData, stderr: false, lines: lineHandler)
        }
        err.fileHandleForReading.readabilityHandler = { handle in
            collected.add(handle.availableData, stderr: true, lines: lineHandler)
        }
        process.terminationHandler = { [weak self] finished in
            out.fileHandleForReading.readabilityHandler = nil
            err.fileHandleForReading.readabilityHandler = nil
            collected.add(out.fileHandleForReading.readDataToEndOfFile(), stderr: false, lines: lineHandler)
            collected.add(err.fileHandleForReading.readDataToEndOfFile(), stderr: true, lines: lineHandler)
            collected.flush(lines: lineHandler)
            if let self {
                self.lock.lock(); self.processes.removeAll { $0 === finished }; self.lock.unlock()
            }
            let result = collected.result
            resolve(["code": Int(finished.terminationStatus), "stdout": result.stdout, "stderr": result.stderr])
        }
        lock.lock()
        guard !_cancelled else { lock.unlock(); return reject(L("Cancelled", "Abgebrochen")) }
        processes.append(process)
        let paused = _paused
        lock.unlock()
        do {
            try process.run()
            if paused { kill(process.processIdentifier, SIGSTOP) }
        } catch {
            lock.lock(); processes.removeAll { $0 === process }; lock.unlock()
            reject(error.localizedDescription)
        }
    }
}

/// Sammelt die Ausgabe eines Programms (höchstens 1 MB je Kanal) und meldet sie
/// zeilenweise, getrennt nach stdout und stderr. Zeilen enden auch an \r, damit
/// Fortschrittsanzeigen ankommen. Sehr lange Zeilen werden nach 64 KB weitergereicht.
private final class OutputCollector {
    private let lock = NSLock()
    private var stdout = Data()
    private var stderr = Data()
    private var pendingOut = Data()
    private var pendingErr = Data()
    private let limit = 1024 * 1024
    private let maxLine = 64 * 1024

    func add(_ data: Data, stderr isErr: Bool, lines: (String) -> Void) {
        guard !data.isEmpty else { return }
        lock.lock()
        var pending: Data
        if isErr {
            if stderr.count < limit { stderr.append(data.prefix(limit - stderr.count)) }
            pending = pendingErr
        } else {
            if stdout.count < limit { stdout.append(data.prefix(limit - stdout.count)) }
            pending = pendingOut
        }
        pending.append(data)
        var found: [String] = []
        while let index = pending.firstIndex(where: { $0 == 10 || $0 == 13 }) {
            let line = pending[pending.startIndex..<index]
            pending = Data(pending[pending.index(after: index)...])
            if !line.isEmpty { found.append(String(decoding: line, as: UTF8.self)) }
        }
        if pending.count > maxLine {
            found.append(String(decoding: pending, as: UTF8.self))
            pending = Data()
        }
        if isErr { pendingErr = pending } else { pendingOut = pending }
        lock.unlock()
        found.forEach(lines)
    }

    func flush(lines: (String) -> Void) {
        lock.lock()
        let rest = [pendingOut, pendingErr]
        pendingOut = Data()
        pendingErr = Data()
        lock.unlock()
        for data in rest where !data.isEmpty { lines(String(decoding: data, as: UTF8.self)) }
    }

    var result: (stdout: String, stderr: String) {
        lock.lock(); defer { lock.unlock() }
        return (String(decoding: stdout, as: UTF8.self), String(decoding: stderr, as: UTF8.self))
    }
}

/// Signale an ein Programm und alle Programme, die es selbst gestartet hat (z. B. ein
/// Werkzeug, das ffmpeg startet): Anhalten und Abbrechen wirken auf den ganzen Baum.
enum ProcessTree {
    static func descendants(of pid: pid_t) -> [pid_t] {
        var result: [pid_t] = []
        var queue = [pid]
        while let current = queue.popLast(), result.count < 256 {
            let count = proc_listchildpids(current, nil, 0)
            guard count > 0 else { continue }
            var buffer = [pid_t](repeating: 0, count: Int(count) + 8)
            let filled = proc_listchildpids(current, &buffer, Int32(buffer.count * MemoryLayout<pid_t>.size))
            guard filled > 0 else { continue }
            let children = buffer.prefix(Int(filled)).filter { $0 > 0 }
            result += children
            queue += children
        }
        return result
    }

    /// Erst die Nachkommen, dann das Programm selbst
    static func signal(_ pid: pid_t, _ sig: Int32) {
        for child in descendants(of: pid).reversed() { kill(child, sig) }
        kill(pid, sig)
    }
}

/// Hält die Beobachtung des Fortschritts eines Downloads, bis er fertig ist
private final class ObservationHolder: @unchecked Sendable {
    private let lock = NSLock()
    private var observation: NSKeyValueObservation?

    func set(_ value: NSKeyValueObservation) {
        lock.lock(); observation = value; lock.unlock()
    }

    func invalidate() {
        lock.lock(); let o = observation; observation = nil; lock.unlock()
        o?.invalidate()
    }
}
