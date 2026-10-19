import AppKit
import SwiftUI

/// Rückfragen rund um Plugins, im Stil der übrigen Dialoge von BarDrop.
enum PluginDialogs {
    static func makeAlert(_ manifest: PluginManifest) -> NSAlert {
        let alert = NSAlert()
        if let image = PluginIconView.image(manifest.icon, size: 64) { alert.icon = image }
        return alert
    }

    /// Die Ablage bleibt offen, solange eine Frage steht
    @discardableResult
    static func run(_ alert: NSAlert, ui: ShelfUIModel?) -> NSApplication.ModalResponse {
        ui?.menuOpen = true
        NSApp.activate(ignoringOtherApps: true)
        let answer = alert.runModal()
        ui?.menuOpen = false
        return answer
    }

    /// Zustimmung zum Hinweis des Plugins (`consent`), einmalig
    static func confirmConsent(_ plugin: InstalledPlugin, manager: PluginManager, ui: ShelfUIModel?) -> Bool {
        guard let consent = plugin.manifest.consent, !manager.state(plugin.id).consented else { return true }
        let alert = makeAlert(plugin.manifest)
        alert.messageText = L("Use “\(plugin.manifest.name.text)”?", "„\(plugin.manifest.name.text)“ verwenden?")
        alert.informativeText = consent.text
        alert.addButton(withTitle: L("Agree", "Zustimmen"))
        alert.addButton(withTitle: L("Cancel", "Abbrechen"))
        guard run(alert, ui: ui) == .alertFirstButtonReturn else { return false }
        manager.update(plugin.id) { $0.consented = true }
        return true
    }

    static func allow(_ permission: PluginPermission, for plugin: InstalledPlugin, ui: ShelfUIModel?) -> Bool {
        let alert = makeAlert(plugin.manifest)
        alert.messageText = permission.question(for: plugin.manifest.name.text)
        alert.informativeText = permission.explanation
        alert.addButton(withTitle: L("Allow", "Erlauben"))
        alert.addButton(withTitle: L("Don’t Allow", "Nicht erlauben"))
        if permission == .run { alert.alertStyle = .warning }
        return run(alert, ui: ui) == .alertFirstButtonReturn
    }

    static func allowDownload(of tool: PluginTool, for plugin: InstalledPlugin, ui: ShelfUIModel?) -> Bool {
        let alert = makeAlert(plugin.manifest)
        let host = URL(string: tool.resolvedURL)?.host ?? tool.resolvedURL
        alert.messageText = L("Download “\(tool.name)”?", "„\(tool.name)“ herunterladen?")
        var text = L("“\(plugin.manifest.name.text)” needs the program “\(tool.name)”. BarDrop downloads it from \(host), checks its checksum and keeps it for all plugins. The program isn’t part of BarDrop and runs with the same rights as the plugin.",
                     "„\(plugin.manifest.name.text)“ braucht das Programm „\(tool.name)“. BarDrop lädt es von \(host), prüft seine Prüfsumme und hebt es für alle Plugins auf. Das Programm gehört nicht zu BarDrop und läuft mit denselben Rechten wie das Plugin.")
        if let days = tool.refreshDays {
            text += " " + L("It is downloaded again after \(days) days.", "Nach \(days) Tagen wird es neu geladen.")
        }
        if let license = tool.license { text += "\n\n" + L("License: \(license)", "Lizenz: \(license)") }
        alert.informativeText = text
        alert.addButton(withTitle: L("Download", "Laden"))
        alert.addButton(withTitle: L("Cancel", "Abbrechen"))
        return run(alert, ui: ui) == .alertFirstButtonReturn
    }

    static func showError(_ message: String, of plugin: InstalledPlugin, ui: ShelfUIModel?) {
        let alert = makeAlert(plugin.manifest)
        alert.messageText = L("“\(plugin.manifest.name.text)” didn’t work", "„\(plugin.manifest.name.text)“ hat nicht geklappt")
        alert.informativeText = String(message.prefix(600))
        alert.addButton(withTitle: "OK")
        run(alert, ui: ui)
    }

    /// Einschalten von „Automatisch beim Ablegen“ und „Erlauben“ in den Einstellungen:
    /// Zustimmung, alle Rechte und alle Programme jetzt erfragen, damit beim Ablegen
    /// später keine Frage aufspringt.
    static func prepareAutomatic(_ plugin: InstalledPlugin, manager: PluginManager) -> Bool {
        guard confirmConsent(plugin, manager: manager, ui: nil) else { return false }
        for permission in plugin.manifest.allPermissions where !manager.isGranted(permission, for: plugin) {
            guard allow(permission, for: plugin, ui: nil) else { return false }
            manager.grant(permission, for: plugin)
        }
        // Programme, die das Plugin laden muss: jetzt erlauben, beim Ablegen fragt niemand
        for tool in plugin.manifest.tools ?? [] where !manager.state(plugin.id).approvedTools.contains(tool.id) {
            guard allowDownload(of: tool, for: plugin, ui: nil) else { return false }
            manager.update(plugin.id) { $0.approvedTools.append(tool.id) }
        }
        return true
    }
}

// MARK: Import

/// Import einer .bdrop-Datei: prüfen, zeigen, was das Plugin kann und darf, und erst nach
/// Bestätigung installieren. Ein Doppelklick installiert also nie still.
enum PluginImporter {
    /// Liefert das installierte Plugin, nil bei Abbruch oder Fehler (dann mit Meldung)
    @discardableResult
    static func importFile(_ url: URL, parent: NSWindow?, manager: PluginManager = .shared) -> InstalledPlugin? {
        let unpacked: PluginPackage.Unpacked
        do {
            unpacked = try manager.inspect(url)
        } catch let error as PluginManager.InstallError {
            showFailure(error.message, file: url)
            return nil
        } catch {
            showFailure(error.localizedDescription, file: url)
            return nil
        }
        let manifest = unpacked.manifest
        if manager.plugin(manifest.id)?.isStandard == true {
            try? FileManager.default.removeItem(at: unpacked.directory)
            showFailure(PluginManager.InstallError.standardExists.message, file: url)
            return nil
        }
        let existing = manager.plugin(manifest.id)
        let alert = PluginDialogs.makeAlert(manifest)
        if existing != nil {
            alert.messageText = L("Update “\(manifest.name.text)”?", "„\(manifest.name.text)“ aktualisieren?")
        } else {
            alert.messageText = L("Install “\(manifest.name.text)”?", "„\(manifest.name.text)“ installieren?")
        }
        var lines: [String] = []
        if let existing {
            lines.append(L("Installed: \(existing.manifest.version), new: \(manifest.version)",
                           "Installiert: \(existing.manifest.version), neu: \(manifest.version)"))
        }
        if let description = manifest.description?.text, !description.isEmpty { lines.append(description) }
        lines.append(L("This plugin isn’t from the BarDrop catalog. Only install plugins from people you trust. You can look at its script below.",
                       "Dieses Plugin stammt nicht aus dem Katalog von BarDrop. Installiere nur Plugins von Menschen, denen du vertraust. Das Skript kannst du dir unten ansehen."))
        alert.informativeText = lines.joined(separator: "\n\n")
        alert.alertStyle = .warning
        let accessory = NSHostingView(rootView: ImportDetails(manifest: manifest, script: unpacked.script))
        accessory.frame = NSRect(x: 0, y: 0, width: 420, height: 250)
        alert.accessoryView = accessory
        alert.addButton(withTitle: existing == nil ? L("Install", "Installieren") : L("Update", "Aktualisieren"))
        alert.addButton(withTitle: L("Cancel", "Abbrechen"))
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else {
            try? FileManager.default.removeItem(at: unpacked.directory)
            return nil
        }
        do {
            let installed = try manager.install(unpacked, standard: false)
            // Plugins einschalten, sonst wäre das neue Plugin nirgends zu sehen
            if !AppSettings.shared.pluginsEnabled { AppSettings.shared.pluginsEnabled = true }
            return installed
        } catch let error as PluginManager.InstallError {
            showFailure(error.message, file: url)
        } catch {
            showFailure(error.localizedDescription, file: url)
        }
        return nil
    }

    /// Dateiauswahl für „Plugin importieren“
    static func chooseAndImport() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [PluginPackage.contentType]
        panel.prompt = L("Import", "Importieren")
        panel.message = L("Choose a BarDrop plugin (.bdrop)", "BarDrop-Plugin auswählen (.bdrop)")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        importFile(url, parent: nil)
    }

    private static func showFailure(_ message: String, file: URL) {
        let alert = NSAlert()
        alert.messageText = L("“\(file.lastPathComponent)” can’t be installed", "„\(file.lastPathComponent)“ lässt sich nicht installieren")
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}

/// Unter der Frage beim Import: Rechte, Programme und das Skript zum Nachlesen
private struct ImportDetails: View {
    let manifest: PluginManifest
    let script: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !manifest.allPermissions.isEmpty || !(manifest.tools ?? []).isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(manifest.allPermissions) { permission in
                        Label(permission.title, systemImage: permission.symbol)
                            .font(.system(size: 12))
                    }
                    ForEach(manifest.tools ?? []) { tool in
                        Label(L("Downloads “\(tool.name)” from \(URL(string: tool.resolvedURL)?.host ?? tool.resolvedURL)",
                                "Lädt „\(tool.name)“ von \(URL(string: tool.resolvedURL)?.host ?? tool.resolvedURL)"),
                              systemImage: "arrow.down.circle")
                            .font(.system(size: 12))
                    }
                }
            }
            ScriptText(script: script, fontSize: 11)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.black.opacity(0.85)))
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .frame(width: 420, height: 250)
    }
}

// MARK: Skript ansehen

/// Skript eines Plugins zum Lesen, mit Syntaxfarben. Bearbeitet wird im eigenen Editor
/// („Im Editor öffnen“); geänderter Code verliert seine Rechte.
enum ScriptViewer {
    private static var windows: [String: NSWindow] = [:]

    static func show(_ plugin: InstalledPlugin) {
        if let window = windows[plugin.id] {
            window.contentView = NSHostingView(rootView: ScriptViewerView(plugin: plugin))
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 520),
                              styleMask: [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.title = plugin.manifest.name.text + " · " + plugin.manifest.script
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 420, height: 300)
        window.contentView = NSHostingView(rootView: ScriptViewerView(plugin: plugin))
        window.center()
        windows[plugin.id] = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
}

private struct ScriptViewerView: View {
    let plugin: InstalledPlugin

    var body: some View {
        VStack(spacing: 0) {
            ScriptText(script: plugin.script, fontSize: 12.5)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            HStack(spacing: 8) {
                PluginIconView(icon: plugin.manifest.icon, size: 20)
                Text("\(plugin.manifest.name.text) \(plugin.manifest.version)")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer()
                Button(L("Copy", "Kopieren")) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(plugin.script, forType: .string)
                }
                .buttonStyle(KlackButtonStyle())
                Button(L("Show in Finder", "Im Finder zeigen")) {
                    NSWorkspace.shared.activateFileViewerSelecting([plugin.scriptURL])
                }
                .buttonStyle(KlackButtonStyle())
                if !plugin.isStandard {
                    Button(L("Open in Editor", "Im Editor öffnen")) {
                        NSWorkspace.shared.open(plugin.scriptURL)
                    }
                    .buttonStyle(KlackButtonStyle(prominent: true))
                    .help(L("After a change, the plugin asks for its permissions again.",
                            "Nach einer Änderung fragt das Plugin erneut nach seinen Rechten."))
                }
            }
            .padding(12)
            .background(SettingsTheme.contentBackdrop)
        }
        .background(Color.black)
        .environment(\.colorScheme, .dark)
    }
}

/// Schreibgeschützte Ansicht eines Skripts in einer festen Schrift, mit einfachen
/// Syntaxfarben (Schlüsselwörter, Texte, Zahlen, Kommentare)
struct ScriptText: View {
    let script: String
    var fontSize: CGFloat = 12

    var body: some View {
        ScrollView([.vertical, .horizontal]) {
            Text(ScriptHighlighter.highlight(script, size: fontSize))
                .textSelection(.enabled)
                .fixedSize(horizontal: true, vertical: true)
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .padding(12)
        }
    }
}

enum ScriptHighlighter {
    private static let keywords = ["async", "await", "break", "case", "catch", "class", "const", "continue", "default",
                                   "do", "else", "export", "false", "finally", "for", "function", "if", "import", "in",
                                   "let", "new", "null", "of", "return", "switch", "this", "throw", "true", "try",
                                   "typeof", "undefined", "var", "while"]

    /// Höchstens so viele Zeichen einfärben: sehr lange Skripte bleiben flüssig
    private static let limit = 200_000

    static func highlight(_ script: String, size: CGFloat) -> AttributedString {
        var text = AttributedString(script)
        text.font = .system(size: size, design: .monospaced)
        text.foregroundColor = Color(white: 0.88)
        guard script.count <= limit else { return text }
        func paint(_ pattern: String, _ color: Color, options: NSRegularExpression.Options = []) {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else { return }
            let ns = script as NSString
            for match in regex.matches(in: script, range: NSRange(location: 0, length: ns.length)) {
                guard let range = Range(match.range, in: script),
                      let lower = AttributedString.Index(range.lowerBound, within: text),
                      let upper = AttributedString.Index(range.upperBound, within: text) else { continue }
                text[lower..<upper].foregroundColor = color
            }
        }
        paint(#"\b\d+(\.\d+)?\b"#, Color(red: 0.82, green: 0.75, blue: 0.5))
        paint(#"\b(" + keywords.joined(separator: "|") + #")\b"#, Color(red: 0.99, green: 0.37, blue: 0.64))
        paint(#"\bbardrop\b"#, Color(red: 0.4, green: 0.8, blue: 0.95))
        paint(#"(["'`])(?:\\.|(?!\1).)*\1"#, Color(red: 0.99, green: 0.42, blue: 0.36))
        paint(#"//[^\n]*|/\*[\s\S]*?\*/"#, Color(white: 0.5))
        return text
    }
}
