import AppKit

/// Diagnose (nur mit eingeschaltetem Diagnoseprotokoll): Bilder der Ablage, genau so, wie
/// sie gerade auf dem Bildschirm steht, in ~/Library/Logs/BarDrop/Bilder. Für Fehler, die
/// nur zu sehen sind (Kacheln, die nicht erscheinen, Symbole, die springen): Das Protokoll
/// sagt, was die App weiß, die Bilder, was davon gezeigt wird. Die Bilder bleiben auf
/// diesem Mac; beim Ausschalten des Protokolls werden sie gelöscht.
enum ShelfSnapshots {
    static let directory: URL = {
        FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs/BarDrop/Bilder", isDirectory: true)
    }()

    private static let keep = 60
    private static var counter = 0

    /// Das Fenster jetzt und nach den angegebenen Verzögerungen aufnehmen
    static func capture(_ window: NSWindow?, _ reason: String, after delays: [TimeInterval] = [0, 0.3, 1]) {
        guard Diagnostics.shared.isEnabled, let window else { return }
        for delay in delays {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                save(window, "\(reason)+\(Int(delay * 1000))ms")
            }
        }
    }

    /// Bild des Fensters, wie es der Bildschirm zeigt (eigene Fenster brauchen dafür keine
    /// Erlaubnis). Über dlsym: Die Funktion ist im SDK als veraltet markiert, läuft aber.
    private typealias CreateImage = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
    private static let createImage: CreateImage? = {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage") else { return nil }
        return unsafeBitCast(symbol, to: CreateImage.self)
    }()

    private static func save(_ window: NSWindow, _ name: String) {
        guard window.isVisible, let createImage else { return }
        // kCGWindowListOptionIncludingWindow = 8, kCGWindowImageBoundsIgnoreFraming = 1
        guard let image = createImage(.null, 8, UInt32(window.windowNumber), 1)?.takeRetainedValue() else {
            Diagnostics.shared.record("shot", "\(name) nicht möglich")
            return
        }
        let rep = NSBitmapImageRep(cgImage: image)
        guard let data = rep.representation(using: .png, properties: [:]) else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        counter += 1
        let stamp = ISO8601DateFormatter.string(from: Date(), timeZone: .current,
                                                formatOptions: [.withTime, .withColonSeparatorInTime])
        let file = directory.appendingPathComponent(String(format: "%@ %03d %@.png", stamp, counter % 1000, name)
            .replacingOccurrences(of: ":", with: "-"))
        try? data.write(to: file)
        Diagnostics.shared.record("shot", file.lastPathComponent)
        prune()
    }

    private static func prune() {
        let files = ((try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "png" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        for file in files.dropLast(keep) { try? FileManager.default.removeItem(at: file) }
    }

    static func clear() {
        try? FileManager.default.removeItem(at: directory)
    }
}
