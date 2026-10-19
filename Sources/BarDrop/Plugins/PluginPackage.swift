import Foundation
import CryptoKit
import UniformTypeIdentifiers

/// Eine .bdrop-Datei: ein ZIP-Archiv mit `manifest.json`, dem Skript und optional
/// weiteren Dateien (Texte, Vorlagen). Die Dateien liegen direkt im Archiv oder in
/// genau einem Ordner darin (so entsteht es beim Komprimieren im Finder).
enum PluginPackage {
    static let fileExtension = "bdrop"
    static let typeIdentifier = "io.github.zzuuuiii.bardrop.plugin"
    /// Höchstgröße einer .bdrop-Datei: Plugins sind Skripte, keine Programme
    static let maxPackageSize = 5 * 1024 * 1024
    static let maxScriptSize = 1024 * 1024

    static var contentType: UTType {
        UTType(typeIdentifier) ?? UTType(filenameExtension: fileExtension) ?? .zip
    }

    enum PackageError: Error, Equatable {
        case unreadable
        case tooLarge
        case notAnArchive
        case missingManifest
        case invalidManifest(String)
        case missingScript
        case invalid(PluginManifest.ValidationError)
    }

    /// Ein entpacktes, geprüftes Plugin
    struct Unpacked {
        let manifest: PluginManifest
        /// Ordner mit manifest.json
        let directory: URL
        let script: String
    }

    /// Entpackt eine .bdrop-Datei in einen neuen Ordner unter `scratch` und prüft sie.
    static func unpack(_ file: URL, into scratch: URL, appVersion: String) throws -> Unpacked {
        let size = (try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        guard size > 0 else { throw PackageError.unreadable }
        guard size <= maxPackageSize else { throw PackageError.tooLarge }
        let target = scratch.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try extract(file, to: target)
        return try read(directory: locateRoot(in: target), appVersion: appVersion)
    }

    /// Liest ein schon entpacktes Plugin (installierte Plugins).
    static func read(directory: URL, appVersion: String) throws -> Unpacked {
        let manifestURL = directory.appendingPathComponent("manifest.json")
        guard let data = try? Data(contentsOf: manifestURL) else { throw PackageError.missingManifest }
        let manifest: PluginManifest
        do {
            manifest = try JSONDecoder().decode(PluginManifest.self, from: data)
        } catch {
            throw PackageError.invalidManifest(Self.describe(error))
        }
        do {
            try manifest.validate(appVersion: appVersion)
        } catch let error as PluginManifest.ValidationError {
            throw PackageError.invalid(error)
        }
        let scriptURL = directory.appendingPathComponent(manifest.script)
        guard let scriptData = try? Data(contentsOf: scriptURL), scriptData.count <= maxScriptSize,
              let script = String(data: scriptData, encoding: .utf8) else { throw PackageError.missingScript }
        return Unpacked(manifest: manifest, directory: directory, script: script)
    }

    /// Ordner mit manifest.json: direkt im Archiv oder in seinem einzigen Ordner
    static func locateRoot(in directory: URL) throws -> URL {
        let fm = FileManager.default
        if fm.fileExists(atPath: directory.appendingPathComponent("manifest.json").path) { return directory }
        let children = ((try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey])) ?? [])
            .filter { !$0.lastPathComponent.hasPrefix(".") && $0.lastPathComponent != "__MACOSX" }
        if children.count == 1, let only = children.first,
           fm.fileExists(atPath: only.appendingPathComponent("manifest.json").path) {
            return only
        }
        throw PackageError.missingManifest
    }

    /// Entpackt mit `ditto` (gehört zu macOS). Pfade außerhalb des Ziels und Verweise
    /// werden danach entfernt.
    static func extract(_ archive: URL, to target: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-x", "-k", "--norsrc", archive.path, target.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            throw PackageError.unreadable
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw PackageError.notAnArchive }
        removeLinks(in: target)
    }

    /// Plugins brauchen keine symbolischen Verweise: Sie könnten aus dem Ordner hinauszeigen
    private static func removeLinks(in directory: URL) {
        let fm = FileManager.default
        guard let walker = fm.enumerator(at: directory, includingPropertiesForKeys: [.isSymbolicLinkKey]) else { return }
        for case let url as URL in walker {
            if (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true {
                try? fm.removeItem(at: url)
            }
        }
    }

    /// Packt einen Plugin-Ordner als .bdrop (Teilen, Tests)
    static func pack(_ directory: URL, to file: URL) throws {
        try? FileManager.default.removeItem(at: file)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-c", "-k", "--norsrc", "--noextattr", directory.path, file.path]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw PackageError.unreadable }
    }

    /// Prüfsumme über Manifest und Skript: ändert sich der Code, gelten erteilte Rechte nicht mehr
    static func fingerprint(manifest: Data, script: String) -> String {
        var hasher = SHA256()
        hasher.update(data: manifest)
        hasher.update(data: Data(script.utf8))
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func sha256(of file: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try? handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func describe(_ error: Error) -> String {
        if case DecodingError.keyNotFound(let key, _) = error { return key.stringValue }
        if case DecodingError.typeMismatch(_, let context) = error { return context.codingPath.map(\.stringValue).joined(separator: ".") }
        if case DecodingError.dataCorrupted(let context) = error { return context.debugDescription }
        return error.localizedDescription
    }
}

extension PluginPackage.PackageError {
    var message: String {
        switch self {
        case .unreadable:
            return L("The file can’t be read.", "Die Datei lässt sich nicht lesen.")
        case .tooLarge:
            return L("The file is too large for a plugin (at most 5 MB).", "Die Datei ist zu groß für ein Plugin (höchstens 5 MB).")
        case .notAnArchive:
            return L("The file isn’t a BarDrop plugin.", "Die Datei ist kein BarDrop-Plugin.")
        case .missingManifest:
            return L("The plugin has no manifest.json.", "Im Plugin fehlt die Datei manifest.json.")
        case .invalidManifest(let detail):
            return L("The manifest.json can’t be read (\(detail)).", "Die manifest.json lässt sich nicht lesen (\(detail)).")
        case .missingScript:
            return L("The plugin’s script is missing or too large.", "Das Skript des Plugins fehlt oder ist zu groß.")
        case .invalid(let error):
            return error.message
        }
    }
}
