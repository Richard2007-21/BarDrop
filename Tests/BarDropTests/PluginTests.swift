import XCTest
import AppKit
import UniformTypeIdentifiers
@testable import BarDrop

/// Plugins: Manifest, Erkennung, .bdrop-Pakete, Verwaltung, Ausführung und Ergebnisse.
final class PluginTests: XCTestCase {
    private var base: URL!

    override func setUp() {
        super.setUp()
        base = FileManager.default.temporaryDirectory.appendingPathComponent("BarDropPlugins-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: base)
        super.tearDown()
    }

    // MARK: Hilfen

    private func manifestJSON(id: String = "io.github.test.sample", version: String = "1.0.0",
                              permissions: [String] = [], extra: String = "") -> String {
        """
        {
          "id": "\(id)",
          "name": {"en": "Sample", "de": "Beispiel"},
          "version": "\(version)",
          "icon": {"symbol": "wand.and.stars", "color": "#FF9500"},
          "match": {"extensions": ["txt"], "types": ["public.image"], "links": {"hosts": ["example.com"]}},
          "permissions": [\(permissions.map { "\"\($0)\"" }.joined(separator: ", "))]\(extra)
        }
        """
    }

    /// Plugin-Ordner mit Manifest und Skript
    private func makePluginFolder(id: String = "io.github.test.sample", version: String = "1.0.0",
                                  permissions: [String] = [], script: String, extra: String = "") -> URL {
        let dir = base.appendingPathComponent("src-\(UUID().uuidString)/plugin", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? manifestJSON(id: id, version: version, permissions: permissions, extra: extra)
            .write(to: dir.appendingPathComponent("manifest.json"), atomically: true, encoding: .utf8)
        try? script.write(to: dir.appendingPathComponent("main.js"), atomically: true, encoding: .utf8)
        return dir
    }

    private func makeFile(_ name: String, _ text: String = "hello") -> URL {
        let url = base.appendingPathComponent("in-\(UUID().uuidString)").appendingPathComponent(name)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    // MARK: Manifest

    func testManifestDecodesLocalizedTextAndValidates() throws {
        let manifest = try JSONDecoder().decode(PluginManifest.self, from: Data(manifestJSON(permissions: ["network"]).utf8))
        XCTAssertEqual(manifest.name.text(for: .english), "Sample")
        XCTAssertEqual(manifest.name.text(for: .german), "Beispiel")
        XCTAssertEqual(manifest.allPermissions, [.network])
        XCTAssertNoThrow(try manifest.validate(appVersion: "1.31.0"))
        XCTAssertTrue(manifest.needsSensitivePermissions)
        // Einfacher Text gilt für beide Sprachen
        let single = try JSONDecoder().decode(LocalizedText.self, from: Data("\"Only\"".utf8))
        XCTAssertEqual(single.text(for: .german), "Only")
    }

    func testManifestRejectsUnknownPermissionAndNewerApp() throws {
        let unknown = try JSONDecoder().decode(PluginManifest.self, from: Data(manifestJSON(permissions: ["camera"]).utf8))
        XCTAssertThrowsError(try unknown.validate(appVersion: "1.31.0")) { error in
            XCTAssertEqual(error as? PluginManifest.ValidationError, .unknownPermission("camera"))
        }
        let newer = try JSONDecoder().decode(PluginManifest.self,
                                             from: Data(manifestJSON(extra: ", \"minAppVersion\": \"9.0.0\"").utf8))
        XCTAssertThrowsError(try newer.validate(appVersion: "1.31.0-beta.1"))
        let badID = try JSONDecoder().decode(PluginManifest.self, from: Data(manifestJSON(id: "../evil").utf8))
        XCTAssertThrowsError(try badID.validate(appVersion: "1.31.0"))
    }

    func testAutomaticDefaultNeedsHarmlessPlugin() throws {
        let harmless = try JSONDecoder().decode(PluginManifest.self,
                                                from: Data(manifestJSON(extra: ", \"automaticByDefault\": true").utf8))
        XCTAssertTrue(harmless.automaticDefault)
        let network = try JSONDecoder().decode(PluginManifest.self,
                                               from: Data(manifestJSON(permissions: ["network"], extra: ", \"automaticByDefault\": true").utf8))
        XCTAssertFalse(network.automaticDefault)
    }

    // MARK: Erkennung

    func testMatcherUsesExtensionTypeAndLinks() throws {
        let manifest = try JSONDecoder().decode(PluginManifest.self, from: Data(manifestJSON().utf8))
        XCTAssertTrue(PluginMatcher.matches(manifest.match, PluginItem(url: makeFile("note.TXT"))))
        // PNG ist ein public.image
        XCTAssertTrue(PluginMatcher.matches(manifest.match, PluginItem(url: makeFile("photo.png"))))
        XCTAssertFalse(PluginMatcher.matches(manifest.match, PluginItem(url: makeFile("doc.pdf"))))

        let webloc = makeFile("Link.webloc")
        let plist = try PropertyListSerialization.data(fromPropertyList: ["URL": "https://www.example.com/a"], format: .xml, options: 0)
        try plist.write(to: webloc)
        let link = PluginItem(url: webloc)
        XCTAssertEqual(link.kind, .link)
        XCTAssertEqual(link.link?.host, "www.example.com")
        XCTAssertTrue(PluginMatcher.matches(manifest.match, link))

        let other = makeFile("Other.webloc")
        try PropertyListSerialization.data(fromPropertyList: ["URL": "https://notexample.com"], format: .xml, options: 0).write(to: other)
        XCTAssertFalse(PluginMatcher.matches(manifest.match, PluginItem(url: other)))
        XCTAssertTrue(PluginMatcher.matchesPattern(URL(string: "https://a.org/watch?v=1")!, [#"/watch\?v="#]))
    }

    // MARK: Pakete

    func testPackAndUnpackBdrop() throws {
        let folder = makePluginFolder(script: "function run(item) {}")
        let file = base.appendingPathComponent("Sample.bdrop")
        try PluginPackage.pack(folder, to: file)
        let unpacked = try PluginPackage.unpack(file, into: base.appendingPathComponent("scratch"), appVersion: "1.31.0")
        XCTAssertEqual(unpacked.manifest.id, "io.github.test.sample")
        XCTAssertEqual(unpacked.script, "function run(item) {}")
    }

    func testUnpackRejectsArchiveWithoutManifest() throws {
        let dir = base.appendingPathComponent("empty", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try "x".write(to: dir.appendingPathComponent("readme.txt"), atomically: true, encoding: .utf8)
        let file = base.appendingPathComponent("Broken.bdrop")
        try PluginPackage.pack(dir, to: file)
        XCTAssertThrowsError(try PluginPackage.unpack(file, into: base.appendingPathComponent("scratch"), appVersion: "1.31.0")) {
            XCTAssertEqual($0 as? PluginPackage.PackageError, .missingManifest)
        }
    }

    func testChecksumListParsing() {
        let list = """
        \(String(repeating: "a", count: 64))  tool_linux
        \(String(repeating: "b", count: 64)) *tool_macos
        """
        XCTAssertEqual(PluginTools.checksum(in: list, for: "tool_macos"), String(repeating: "b", count: 64))
        XCTAssertNil(PluginTools.checksum(in: list, for: "tool_windows"))
    }

    // MARK: Verwaltung

    private func installed(_ manager: PluginManager, permissions: [String] = [], script: String) throws -> InstalledPlugin {
        let file = base.appendingPathComponent("p-\(UUID().uuidString).bdrop")
        try PluginPackage.pack(makePluginFolder(permissions: permissions, script: script), to: file)
        return try manager.install(try manager.inspect(file), standard: false)
    }

    func testInstallRemoveAndPermissionsResetAfterEdit() throws {
        let manager = PluginManager(baseDirectory: base.appendingPathComponent("support"), appVersion: "1.31.0")
        let plugin = try installed(manager, permissions: ["network"], script: "function run(item) {}")
        XCTAssertEqual(manager.plugins.map(\.id), [plugin.id])
        manager.grant(.network, for: plugin)
        XCTAssertTrue(manager.isGranted(.network, for: plugin))

        // Skript geändert: Rechte gelten nicht mehr
        try "function run(item) { bardrop.log('x') }".write(to: plugin.scriptURL, atomically: true, encoding: .utf8)
        let edited = try XCTUnwrap(manager.refreshed(plugin.id))
        XCTAssertNotEqual(edited.fingerprint, plugin.fingerprint)
        XCTAssertFalse(manager.isGranted(.network, for: edited))

        // Neu geöffnet: Zustand bleibt erhalten
        manager.update(plugin.id) { $0.enabled = true }
        let reopened = PluginManager(baseDirectory: base.appendingPathComponent("support"), appVersion: "1.31.0")
        XCTAssertTrue(reopened.state(plugin.id).enabled)

        manager.remove(plugin.id)
        XCTAssertTrue(manager.plugins.isEmpty)
    }

    // MARK: Ausführung

    private final class Prompter: PluginPrompter {
        var answer = true
        var asked: [PluginPermission] = []
        func allow(_ permission: PluginPermission, for plugin: InstalledPlugin) -> Bool {
            asked.append(permission)
            return answer
        }
        func allowDownload(of tool: PluginTool, for plugin: InstalledPlugin) -> Bool { answer }
    }

    private func run(_ plugin: InstalledPlugin, on input: URL, automatic: Bool = false,
                     granted: Set<PluginPermission> = [], prompter: Prompter? = nil,
                     timeout: TimeInterval = 15, while running: ((PluginJob) -> Void)? = nil) -> Result<[URL], PluginRunError> {
        let job = PluginJob(plugin: plugin, item: PluginItem(url: input), anchorFileID: UUID(), automatic: automatic)
        let runtime = PluginRuntime(job: job, workDirectory: base.appendingPathComponent("work-\(UUID().uuidString)"),
                                    tools: PluginTools(directory: base.appendingPathComponent("tools")),
                                    prompter: prompter, settingsValues: ["greeting": "Hi"], granted: granted,
                                    onGrant: { _ in }, onNotify: { _ in })
        let done = expectation(description: "Plugin")
        var result: Result<[URL], PluginRunError> = .failure(.cancelled)
        runtime.start { r in
            result = r
            done.fulfill()
        }
        running?(job)
        wait(for: [done], timeout: timeout)
        return result
    }

    func testScriptWritesResultFile() throws {
        let manager = PluginManager(baseDirectory: base.appendingPathComponent("support"), appVersion: "1.31.0")
        let plugin = try installed(manager, script: """
        function run(item) {
          var text = bardrop.readFile(item.path);
          bardrop.progress(0.5, "Halb");
          bardrop.writeFile(item.name.replace('.txt', '') + ' upper.txt', bardrop.settings.greeting + ' ' + text.toUpperCase());
        }
        """)
        let result = run(plugin, on: makeFile("note.txt", "hello"))
        let urls = try result.get()
        XCTAssertEqual(urls.map(\.lastPathComponent), ["note upper.txt"])
        XCTAssertEqual(try String(contentsOf: urls[0], encoding: .utf8), "Hi HELLO")
    }

    func testAsyncScriptAndErrors() throws {
        let manager = PluginManager(baseDirectory: base.appendingPathComponent("support"), appVersion: "1.31.0")
        let failing = try installed(manager, script: "async function run(item) { await Promise.resolve(); throw new Error('nope'); }")
        guard case .failure(.script(let message)) = run(failing, on: makeFile("a.txt")) else { return XCTFail("muss scheitern") }
        XCTAssertTrue(message.contains("nope"))
        XCTAssertFalse(message.contains("main.js"), "eigene Meldungen ohne Ort")

        let noRun = try installed(manager, script: "var x = 1;")
        guard case .failure(.script) = run(noRun, on: makeFile("a.txt")) else { return XCTFail("ohne run") }
    }

    func testReadingOtherFilesIsNotAllowed() throws {
        let manager = PluginManager(baseDirectory: base.appendingPathComponent("support"), appVersion: "1.31.0")
        let plugin = try installed(manager, script: "function run(item) { bardrop.readFile('/etc/hosts'); }")
        guard case .failure = run(plugin, on: makeFile("a.txt")) else { return XCTFail("darf nicht lesen") }
    }

    func testPermissionAskedOnFirstUseAndNeverWhenAutomatic() throws {
        let manager = PluginManager(baseDirectory: base.appendingPathComponent("support"), appVersion: "1.31.0")
        let plugin = try installed(manager, permissions: ["run"], script: """
        async function run(item) {
          var r = await bardrop.run('/bin/echo', ['done']);
          bardrop.writeFile('out.txt', r.stdout.trim() + ' ' + r.code);
        }
        """)
        let prompter = Prompter()
        let urls = try run(plugin, on: makeFile("a.txt"), prompter: prompter).get()
        XCTAssertEqual(prompter.asked, [.run])
        XCTAssertEqual(try String(contentsOf: urls[0], encoding: .utf8), "done 0")

        // Automatisch: keine Frage, ohne Erlaubnis scheitert es
        let silent = Prompter()
        guard case .failure = run(plugin, on: makeFile("a.txt"), automatic: true, prompter: silent) else {
            return XCTFail("ohne Erlaubnis")
        }
        XCTAssertTrue(silent.asked.isEmpty)

        // Undeklariertes Recht: scheitert ohne Frage
        let undeclared = try installed(manager, script: "async function run(item) { await bardrop.fetch('https://example.com'); }")
        let other = Prompter()
        guard case .failure = run(undeclared, on: makeFile("a.txt"), prompter: other) else { return XCTFail("undeklariert") }
        XCTAssertTrue(other.asked.isEmpty)
    }

    func testCancelStopsRunningProgram() throws {
        let manager = PluginManager(baseDirectory: base.appendingPathComponent("support"), appVersion: "1.31.0")
        let plugin = try installed(manager, permissions: ["run"], script: """
        async function run(item) { await bardrop.run('/bin/sleep', ['30']); bardrop.writeFile('late.txt', 'x'); }
        """)
        let started = Date()
        let result = run(plugin, on: makeFile("a.txt"), granted: [.run], timeout: 10) { job in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                job.pause()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    XCTAssertTrue(job.paused)
                    job.resume()
                    job.cancel()
                }
            }
        }
        XCTAssertEqual(result, .failure(.cancelled))
        XCTAssertLessThan(Date().timeIntervalSince(started), 8)
    }

    // MARK: Ergebnisse in der Ablage

    func testResultsLandNextToOriginal() throws {
        let store = ShelfStore(baseDirectory: base.appendingPathComponent("shelf"))
        let files = (1...3).map { ShelfFile(url: makeFile("f\($0).txt"), owned: false) }
        AppSettings.shared.stackMultiple = false
        store.add(files)          // gespeichert: f1, f2, f3
        let order = store.entries.map { $0.files[0].url.lastPathComponent }
        let middle = store.entries[1].files[0]

        let added = store.adoptResults([makeFile("result.txt")])
        XCTAssertEqual(added.count, 1)
        XCTAssertTrue(added[0].owned)
        store.insertResults(added, nextTo: middle.id, newestFirst: true, replacing: false)
        XCTAssertEqual(store.entries.map { $0.files[0].url.lastPathComponent },
                       [order[0], order[1], "result.txt", order[2]])

        // Älteste zuerst: in der Anzeige ebenfalls direkt dahinter
        store.insertResults(store.adoptResults([makeFile("second.txt")]), nextTo: middle.id, newestFirst: false, replacing: false)
        let shown = store.entries.reversed().map { $0.files[0].url.lastPathComponent }
        let index = try XCTUnwrap(shown.firstIndex(of: middle.url.lastPathComponent))
        XCTAssertEqual(shown[index + 1], "second.txt")

        // Ersetzen nimmt das Original aus der Ablage
        store.insertResults(store.adoptResults([makeFile("third.txt")]), nextTo: middle.id, newestFirst: true, replacing: true)
        XCTAssertFalse(store.entries.flatMap(\.files).contains { $0.id == middle.id })
        XCTAssertTrue(FileManager.default.fileExists(atPath: middle.url.path))
        AppSettings.shared.stackMultiple = true
    }

    // MARK: Fehlerfälle aus 1.31.0 Beta 1

    /// Gespeicherter Zustand einer älteren Fassung (ohne neue Schlüssel) bleibt lesbar
    func testOlderPluginStateStillDecodes() throws {
        let old = #"{"enabled": true, "replaceOriginal": false, "values": {}, "granted": ["run"], "consented": true, "isStandard": false}"#
        let state = try JSONDecoder().decode(PluginState.self, from: Data(old.utf8))
        XCTAssertTrue(state.enabled)
        XCTAssertEqual(state.granted, [.run])
        XCTAssertTrue(state.approvedTools.isEmpty)
    }

    /// Link aus dem Browser mit Vorschaubild: Ist ein Plugin für den Link zuständig, wird
    /// der Link übernommen, nicht das Bild
    func testLinkWantedByPluginBeatsThumbnail() throws {
        let png = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 4, pixelsHigh: 4, bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                   bytesPerRow: 0, bitsPerPixel: 0)!.representation(using: .png, properties: [:])!
        func importDrag() -> [ShelfFile] {
            let pb = NSPasteboard(name: NSPasteboard.Name("BarDropPlugin-\(UUID().uuidString)"))
            defer { pb.releaseGlobally() }
            pb.clearContents()
            let item = NSPasteboardItem()
            item.setString("https://www.example.com/watch?v=abc", forType: .URL)
            item.setString("Beispiel", forType: NSPasteboard.PasteboardType("public.url-name"))
            item.setData(png, forType: NSPasteboard.PasteboardType("public.png"))
            pb.writeObjects([item])
            let importer = ContentImporter(storage: base.appendingPathComponent("items"), convertImages: true)
            let done = expectation(description: "Import")
            var result: [ShelfFile] = []
            importer.importContent(of: pb) { files in
                result = files
                done.fulfill()
            }
            wait(for: [done], timeout: 10)
            return result
        }
        defer { PasteboardSnapshot.linkWanted = nil }
        PasteboardSnapshot.linkWanted = { $0.host == "www.example.com" }
        let wanted = importDrag()
        XCTAssertEqual(wanted.first?.url.pathExtension, "webloc")
        XCTAssertEqual(PluginItem.readWebloc(try XCTUnwrap(wanted.first?.url))?.absoluteString, "https://www.example.com/watch?v=abc")

        PasteboardSnapshot.linkWanted = { _ in false }
        XCTAssertEqual(importDrag().first?.url.pathExtension, "png")
    }

    func testConsoleLogDoesNotFail() throws {
        let manager = PluginManager(baseDirectory: base.appendingPathComponent("support"), appVersion: "1.31.0")
        let plugin = try installed(manager, script: "function run(item) { console.log('hi', {a: 1}); bardrop.writeFile('ok.txt', 'ok'); }")
        XCTAssertEqual(try run(plugin, on: makeFile("a.txt")).get().map(\.lastPathComponent), ["ok.txt"])
    }

    // MARK: Programme im Archiv, Plugin-Protokoll

    func testToolArchiveAndArchitectureRules() throws {
        let ok = try JSONDecoder().decode(PluginManifest.self, from: Data(manifestJSON(permissions: ["run"], extra: #"""
        , "tools": [{"id": "tool", "name": "Tool", "url": "https://example.com/tool-{arch}.zip",
                     "checksums": "https://example.com/tool-{arch}.zip.sha256", "archive": "zip", "executable": "tool"}]
        """#).utf8))
        XCTAssertNoThrow(try ok.validate(appVersion: "1.31.0"))
        let tool = try XCTUnwrap(ok.tools?.first)
        XCTAssertFalse(tool.resolvedURL.contains("{arch}"))
        XCTAssertTrue(tool.resolvedURL.contains(PluginTool.architecture))
        XCTAssertTrue(["aarch64", "x86_64"].contains(PluginTool.architecture))

        let noExecutable = try JSONDecoder().decode(PluginManifest.self, from: Data(manifestJSON(permissions: ["run"], extra: #"""
        , "tools": [{"id": "tool", "name": "Tool", "url": "https://example.com/tool.zip", "sha256": "\#(String(repeating: "a", count: 64))", "archive": "zip"}]
        """#).utf8))
        XCTAssertThrowsError(try noExecutable.validate(appVersion: "1.31.0"))
        let escape = try JSONDecoder().decode(PluginManifest.self, from: Data(manifestJSON(permissions: ["run"], extra: #"""
        , "tools": [{"id": "x", "name": "X", "url": "https://example.com/x.zip", "sha256": "\#(String(repeating: "a", count: 64))", "archive": "zip", "executable": "../evil"}]
        """#).utf8))
        XCTAssertThrowsError(try escape.validate(appVersion: "1.31.0"))
    }

    func testPluginLogOnlyWritesWhenEnabled() throws {
        let log = PluginLog(directory: base.appendingPathComponent("logs"))
        log.record("io.github.test.a", "start", "off")
        log.flush()
        XCTAssertFalse(FileManager.default.fileExists(atPath: log.logURL.path))
        log.isEnabled = true
        log.record("io.github.test.a", "fehler", "line one\nline two")
        log.flush()
        let text = try String(contentsOf: log.logURL, encoding: .utf8)
        XCTAssertTrue(text.contains("io.github.test.a  [fehler]  line one ⏎ line two"))
        XCTAssertFalse(text.contains("off"))
        log.clear()
        XCTAssertFalse(FileManager.default.fileExists(atPath: log.logURL.path))
    }
}
