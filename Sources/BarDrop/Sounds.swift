import AppKit

/// Klänge wie im Finder.
enum Sounds {
    private static let systemSounds = "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/"

    /// In den Papierkorb (⌘⌫, Aktion Papierkorb): der Klang von macOS beim Ziehen auf den
    /// Papierkorb. Fehlt er, bleibt es still.
    private static let trashSound: NSSound? =
        NSSound(contentsOf: URL(fileURLWithPath: systemSounds + "dock/drag to trash.aif"), byReference: true)

    /// Aus der Ablage entfernen (⌫, Entfernen, Alle entfernen): der Klang des Finders
    /// „move to trash“, den BarDrop bis 1.30.0 Beta 14 für alles verwendet hat
    private static let removeSound: NSSound? =
        NSSound(contentsOf: URL(fileURLWithPath: systemSounds + "finder/move to trash.aif"), byReference: true)

    /// Klang beim Ablegen in einen Ordner der Aktionsleiste (macOS: „Volume Mount“)
    private static let folderSound: NSSound? =
        NSSound(contentsOf: URL(fileURLWithPath: systemSounds + "system/Volume Mount.aif"), byReference: true)

    /// Nach dem Verschieben oder Kopieren in einen Ordner der Aktionsleiste
    static func folder() { play(folderSound) }

    /// In den Papierkorb gelegt. Wie der Finder nur, wenn unter Systemeinstellungen → Ton
    /// „Toneffekte der Benutzeroberfläche“ an ist (gilt für alle Klänge hier).
    static func trash() { play(trashSound) }

    /// Aus der Ablage entfernt (die Datei bleibt, wo sie ist)
    static func remove() { play(removeSound) }

    private static func play(_ sound: NSSound?) {
        guard interfaceSoundsEnabled, let sound else { return }
        if sound.isPlaying { sound.stop() }
        sound.play()
    }

    /// „Toneffekte der Benutzeroberfläche abspielen“ (ohne Eintrag: an, wie bei macOS)
    static var interfaceSoundsEnabled: Bool {
        let value = UserDefaults(suiteName: "com.apple.systemsound")?.object(forKey: "com.apple.sound.uiaudio.enabled")
        return (value as? NSNumber)?.boolValue ?? true
    }
}
