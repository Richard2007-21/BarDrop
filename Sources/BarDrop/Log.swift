import Foundation
import os

/// Protokoll in der Konsole-App (Unterbereich „com.zzuuuiii.bardrop“).
///
/// Nach dem Muster von perch: Fehler beim Aufnehmen und Herausziehen werden mit
/// Ursache festgehalten, damit sie sich nachvollziehen lassen. Dateinamen und
/// Pfade gelten als privat und erscheinen nur auf diesem Mac im Klartext.
enum Log {
    private static let subsystem = Bundle.main.bundleIdentifier ?? "com.zzuuuiii.bardrop"

    /// Aufnehmen: Dateien, Datei-Versprechen, Bilder, Links, Text
    static let importing = Logger(subsystem: subsystem, category: "import")
    /// Herausziehen in andere Programme
    static let export = Logger(subsystem: subsystem, category: "export")
    /// Liste der Ablage laden und speichern
    static let store = Logger(subsystem: subsystem, category: "store")
    /// Erkennung am Rand, Bildschirme
    static let edge = Logger(subsystem: subsystem, category: "edge")
}
