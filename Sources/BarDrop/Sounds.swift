import AppKit

/// Klänge wie im Finder.
enum Sounds {
    /// Klang des Finders beim Bewegen in den Papierkorb. Liegt bei macOS; fehlt er, bleibt
    /// es still.
    private static let trashURL = URL(fileURLWithPath:
        "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/finder/move to trash.aif")

    private static let trashSound: NSSound? = NSSound(contentsOf: trashURL, byReference: true)

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
