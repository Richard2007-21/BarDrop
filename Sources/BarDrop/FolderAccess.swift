import AppKit
import Combine

/// Ordner, die BarDrop von selbst beobachtet (Bildschirmfotos, AirDrop), und ob macOS das
/// Lesen erlaubt. Schreibtisch, Dokumente und Downloads sind durch „Dateien und Ordner“
/// geschützt; nach einem Update von BarDrop kann diese Erlaubnis fehlen. Die Einstellungen
/// zeigen dann, welcher Ordner betroffen ist, und führen zur passenden Stelle.
final class FolderAccess: ObservableObject {
    static let shared = FolderAccess()

    /// Ordner ohne Lesezugriff
    @Published private(set) var denied: [URL] = []

    /// Inhalt eines Ordners, nil ohne Zugriff (dann vermerkt und einmal protokolliert)
    func contents(of folder: URL, keys: [URLResourceKey], area: String) -> [URL]? {
        do {
            let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys,
                                                                    options: [.skipsHiddenFiles])
            setDenied(folder, false, area: area, error: nil)
            return files
        } catch {
            setDenied(folder, true, area: area, error: error as NSError)
            return nil
        }
    }

    /// Ordner wird nicht mehr beobachtet: kein Hinweis mehr dazu
    func forget(_ folder: URL) {
        let key = folder.standardizedFileURL
        if denied.contains(key) { denied.removeAll { $0 == key } }
    }

    func isDenied(_ folder: URL) -> Bool { denied.contains(folder.standardizedFileURL) }

    private func setDenied(_ folder: URL, _ isDenied: Bool, area: String, error: NSError?) {
        let key = folder.standardizedFileURL
        guard denied.contains(key) != isDenied else { return }
        if isDenied {
            denied.append(key)
            let code = error.map { "\($0.domain) \($0.code)" } ?? "-"
            Diagnostics.shared.failure(area, "Ordner nicht lesbar \(Diagnostics.anon(folder)) \(code)")
        } else {
            denied.removeAll { $0 == key }
            Diagnostics.shared.record(area, "Ordner wieder lesbar \(Diagnostics.anon(folder))")
        }
    }

    /// Name des Ordners, wie ihn der Finder zeigt („Schreibtisch“)
    static func displayName(_ folder: URL) -> String {
        FileManager.default.displayName(atPath: folder.path)
    }

    /// Systemeinstellungen → Datenschutz & Sicherheit → Dateien und Ordner
    static func openPrivacySettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_FilesAndFolders")!
        NSWorkspace.shared.open(url)
    }
}
