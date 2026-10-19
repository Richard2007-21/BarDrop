import Foundation

/// Programme, die Plugins brauchen (im Manifest unter `tools`). BarDrop bringt keines
/// davon mit: Sie werden erst nach Zustimmung geladen, geprüft und unter
/// ~/Library/Application Support/BarDrop/Tools abgelegt, wo alle Plugins sie nutzen können.
final class PluginTools {
    let directory: URL

    private let loadLock = NSLock()

    init(directory: URL) {
        self.directory = directory
    }

    private struct Meta: Codable {
        var url: String
        var sha256: String
        var fetched: Date
    }

    enum ToolError: Error {
        case declined
        case download(String)
        case checksum

        var message: String {
            switch self {
            case .declined: return L("The program wasn’t loaded.", "Das Programm wurde nicht geladen.")
            case .download(let text): return L("Loading the program didn’t work: \(text)", "Das Programm ließ sich nicht laden: \(text)")
            case .checksum: return L("The loaded program didn’t match its checksum and was deleted.",
                                     "Das geladene Programm passte nicht zu seiner Prüfsumme und wurde gelöscht.")
            }
        }
    }

    private func folder(_ tool: PluginTool) -> URL {
        directory.appendingPathComponent(PluginTools.safeName(tool.id), isDirectory: true)
    }

    private func binary(_ tool: PluginTool) -> URL {
        folder(tool).appendingPathComponent(PluginTools.safeName(tool.id))
    }

    static func safeName(_ text: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        let cleaned = String(text.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" })
        return cleaned.hasPrefix(".") ? "tool" + cleaned : cleaned
    }

    /// Schon geladen und noch gültig?
    func installed(_ tool: PluginTool) -> URL? {
        let url = binary(tool)
        guard FileManager.default.isExecutableFile(atPath: url.path),
              let data = try? Data(contentsOf: folder(tool).appendingPathComponent("meta.json")),
              let meta = try? JSONDecoder().decode(Meta.self, from: data),
              meta.url == tool.url else { return nil }
        if let pinned = tool.sha256, pinned.lowercased() != meta.sha256 { return nil }
        if let days = tool.refreshDays, Date().timeIntervalSince(meta.fetched) > Double(days) * 86_400 { return nil }
        return url
    }

    /// Liefert das Programm; lädt es beim ersten Mal nach Zustimmung (`ask`, auf dem
    /// Hauptthread gezeigt). Blockiert den aufrufenden (Hintergrund-)Thread.
    func ensure(_ tool: PluginTool, ask: () -> Bool, cancelled: () -> Bool) throws -> URL {
        // Mehrere Plugins gleichzeitig (z. B. zwei abgelegte Links): nur einer lädt, die
        // anderen warten und nehmen dann die fertige Datei
        loadLock.lock()
        defer { loadLock.unlock() }
        if let url = installed(tool) { return url }
        // Ein veraltetes, aber vorhandenes Programm wird ohne erneute Frage aktualisiert
        let hadVersion = FileManager.default.fileExists(atPath: binary(tool).path)
        guard hadVersion || ask() else { throw ToolError.declined }
        let expected = try expectedChecksum(tool)
        let file = try fetch(URL(string: tool.url)!, cancelled: cancelled)
        defer { try? FileManager.default.removeItem(at: file) }
        guard PluginPackage.sha256(of: file)?.lowercased() == expected else { throw ToolError.checksum }
        let fm = FileManager.default
        try? fm.createDirectory(at: folder(tool), withIntermediateDirectories: true)
        let target = binary(tool)
        try? fm.removeItem(at: target)
        try fm.moveItem(at: file, to: target)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: target.path)
        removexattr(target.path, "com.apple.quarantine", 0)
        let meta = Meta(url: tool.url, sha256: expected, fetched: Date())
        try JSONEncoder().encode(meta).write(to: folder(tool).appendingPathComponent("meta.json"))
        return target
    }

    private func expectedChecksum(_ tool: PluginTool) throws -> String {
        if let pinned = tool.sha256 { return pinned.lowercased() }
        guard let source = tool.checksums.flatMap(URL.init(string:)) else { throw ToolError.checksum }
        let semaphore = DispatchSemaphore(value: 0)
        var text: String?
        URLSession.shared.dataTask(with: source) { data, response, _ in
            if (response as? HTTPURLResponse)?.statusCode == 200 { text = data.flatMap { String(data: $0, encoding: .utf8) } }
            semaphore.signal()
        }.resume()
        semaphore.wait()
        let name = URL(string: tool.url)?.lastPathComponent ?? ""
        guard let text, let sum = Self.checksum(in: text, for: name) else { throw ToolError.checksum }
        return sum
    }

    /// Zeile „<sha256>  <Dateiname>“ (oder „<sha256> *<Dateiname>“) für die Datei
    static func checksum(in list: String, for name: String) -> String? {
        for line in list.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            guard parts.count >= 2 else { continue }
            var file = String(parts[1])
            if file.hasPrefix("*") { file.removeFirst() }
            let sum = parts[0].lowercased()
            if file == name, sum.count == 64, sum.allSatisfy(\.isHexDigit) { return sum }
        }
        return nil
    }

    private func fetch(_ url: URL, cancelled: () -> Bool) throws -> URL {
        let semaphore = DispatchSemaphore(value: 0)
        var result: Result<URL, Error> = .failure(ToolError.download(""))
        let task = URLSession.shared.downloadTask(with: url) { file, response, error in
            if let file, (response as? HTTPURLResponse)?.statusCode == 200 {
                let kept = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                do {
                    try FileManager.default.moveItem(at: file, to: kept)
                    result = .success(kept)
                } catch {
                    result = .failure(ToolError.download(error.localizedDescription))
                }
            } else {
                result = .failure(ToolError.download(error?.localizedDescription ?? "HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)"))
            }
            semaphore.signal()
        }
        task.resume()
        while semaphore.wait(timeout: .now() + 0.5) == .timedOut {
            if cancelled() { task.cancel() }
        }
        return try result.get()
    }
}
