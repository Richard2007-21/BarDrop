import Foundation

/// Dateien aus iCloud Drive, die nur in der Cloud liegen, erst herunterladen
/// (nach perch, CloudDownload.swift).
///
/// Eine solche Datei lässt sich nicht kopieren, solange ihre Daten nicht auf dem
/// Mac sind. Gewartet wird im Hintergrund und abseits der Kopier-Warteschlange,
/// damit ein langer Download keine anderen Objekte aufhält.
enum CloudFiles {
    private static let queue = DispatchQueue(label: "BarDrop.cloud", qos: .userInitiated)
    static let timeout: TimeInterval = 120
    private static let pollInterval: TimeInterval = 0.25

    /// Werte ohne den Zwischenspeicher, den `URL` sonst hält: Sonst sähe eine Datei,
    /// die längst geladen ist, bis zum Ende der Wartezeit noch „nicht geladen“ aus.
    private static func freshValues(_ url: URL, _ keys: Set<URLResourceKey>) -> URLResourceValues? {
        var url = url
        url.removeAllCachedResourceValues()
        return try? url.resourceValues(forKeys: keys)
    }

    /// Liegt die Datei in iCloud, ohne dass ihre Daten auf dem Mac sind?
    static func needsDownload(_ url: URL) -> Bool {
        guard let values = freshValues(url, [.isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey]),
              values.isUbiquitousItem == true else { return false }
        return values.ubiquitousItemDownloadingStatus != .current
    }

    /// Bittet iCloud, die Datei zu laden, ohne darauf zu warten.
    static func requestDownload(_ url: URL) {
        queue.async {
            guard needsDownload(url) else { return }
            try? FileManager.default.startDownloadingUbiquitousItem(at: url)
        }
    }

    /// Ruft `completion` (im Hintergrund) auf, sobald die Datei geladen ist.
    /// `false`: nach der Wartezeit noch nicht geladen oder Fehler.
    static func whenDownloaded(_ url: URL, completion: @escaping (Bool) -> Void) {
        queue.async {
            guard needsDownload(url) else {
                completion(true)
                return
            }
            Log.importing.info("Warte auf iCloud-Download")
            do {
                try FileManager.default.startDownloadingUbiquitousItem(at: url)
            } catch {
                Log.importing.error("iCloud-Download nicht möglich: \(error.localizedDescription, privacy: .public)")
                completion(false)
                return
            }
            poll(url, deadline: Date().addingTimeInterval(timeout), completion: completion)
        }
    }

    private static func poll(_ url: URL, deadline: Date, completion: @escaping (Bool) -> Void) {
        let values = freshValues(url, [.ubiquitousItemDownloadingStatusKey, .ubiquitousItemDownloadingErrorKey])
        if values?.ubiquitousItemDownloadingError != nil {
            Log.importing.error("iCloud meldet einen Fehler beim Laden")
            completion(false)
            return
        }
        let status = values?.ubiquitousItemDownloadingStatus
        if status == .current || status == .downloaded {
            completion(true)
            return
        }
        guard Date() < deadline else {
            Log.importing.error("iCloud-Download nicht rechtzeitig fertig")
            completion(false)
            return
        }
        queue.asyncAfter(deadline: .now() + pollInterval) {
            poll(url, deadline: deadline, completion: completion)
        }
    }
}
