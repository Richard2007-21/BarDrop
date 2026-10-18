import AppKit

/// Klänge wie im Finder.
enum Sounds {
    private static let systemSounds = "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/"

    /// Klang von macOS beim Ziehen auf den Papierkorb und bei ⌘⌫ (kurz, aus dem Dock).
    /// Der längere „move to trash“ des Finders ist nur der Rückfall, falls er fehlt;
    /// fehlen beide, bleibt es still.
    private static let trashSound: NSSound? = ["dock/drag to trash.aif", "finder/move to trash.aif"]
        .lazy
        .compactMap { NSSound(contentsOf: URL(fileURLWithPath: systemSounds + $0), byReference: true) }
        .first

    /// Klang beim Ablegen in einen Ordner der Aktionsleiste (macOS: „Volume Mount“)
    private static let folderSound: NSSound? =
        NSSound(contentsOf: URL(fileURLWithPath: systemSounds + "system/Volume Mount.aif"), byReference: true)

    /// Nach dem Verschieben oder Kopieren in einen Ordner der Aktionsleiste
    static func folder() {
        guard interfaceSoundsEnabled, let sound = folderSound else { return }
        if sound.isPlaying { sound.stop() }
        sound.play()
    }

    /// Beim Entfernen aus der Ablage und beim Bewegen in den Papierkorb. Wie der Finder nur,
    /// wenn unter Systemeinstellungen → Ton „Toneffekte der Benutzeroberfläche“ an ist.
    static func trash() {
        guard interfaceSoundsEnabled, let sound = trashSound else { return }
        if sound.isPlaying { sound.stop() }
        sound.play()
    }

    /// „Toneffekte der Benutzeroberfläche abspielen“ (ohne Eintrag: an, wie bei macOS)
    static var interfaceSoundsEnabled: Bool {
        let value = UserDefaults(suiteName: "com.apple.systemsound")?.object(forKey: "com.apple.sound.uiaudio.enabled")
        return (value as? NSNumber)?.boolValue ?? true
    }
}
