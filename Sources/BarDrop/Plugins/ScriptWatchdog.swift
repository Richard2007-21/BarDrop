import Foundation
import JavaScriptCore
import Darwin

/// Beendet ein Skript, das nicht mehr laufen soll, auch mitten in einer Endlosschleife.
///
/// JavaScriptCore kann ein laufendes Skript in festen Abständen fragen lassen, ob es
/// weiterrechnen darf (`JSContextGroupSetExecutionTimeLimit`). Die Antwort kommt aus
/// `StopFlag`: Nach „Abbrechen“ (oder einem anderen Ende des Laufs) heißt sie „nein“, und
/// JavaScriptCore beendet das Skript mit einer Ausnahme, die es nicht abfangen kann.
/// Solange der Lauf gewollt ist, rechnet das Skript ungestört weiter, wie lange auch immer.
///
/// Die Funktion ist in JavaScriptCore vorhanden, aber nicht öffentlich dokumentiert. Sie
/// wird deshalb zur Laufzeit gesucht: Fehlt sie, läuft alles wie bisher, nur ohne hartes Ende.
enum ScriptWatchdog {
    /// Wie oft nachgefragt wird (Sekunden Rechenzeit am Stück)
    static let interval: Double = 0.25

    final class StopFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var stop = false
        /// Gruppe (virtuelle Maschine) des Skripts, für das Neustellen des Zeitgebers
        fileprivate var group: JSContextGroupRef?
        var shouldStop: Bool { lock.lock(); defer { lock.unlock() }; return stop }
        func set() { lock.lock(); stop = true; lock.unlock() }
    }

    private typealias ShouldTerminate = @convention(c) (JSContextRef?, UnsafeMutableRawPointer?) -> Bool
    private typealias SetLimit = @convention(c) (JSContextGroupRef?, Double, ShouldTerminate?, UnsafeMutableRawPointer?) -> Void

    private static let setLimit: SetLimit? = {
        // RTLD_DEFAULT: in allen geladenen Bibliotheken suchen (JavaScriptCore ist geladen)
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "JSContextGroupSetExecutionTimeLimit") else { return nil }
        return unsafeBitCast(symbol, to: SetLimit.self)
    }()

    /// Wie oft JavaScriptCore nachgefragt hat und wie oft die Antwort „beenden“ war (Diagnose, Tests)
    private static let countLock = NSLock()
    private static var _asked = 0, _stopped = 0
    static var counts: (asked: Int, stopped: Int) { countLock.lock(); defer { countLock.unlock() }; return (_asked, _stopped) }
    fileprivate static func count(stop: Bool) {
        countLock.lock(); _asked += 1; if stop { _stopped += 1 }; countLock.unlock()
    }

    /// Gibt es den Wächter auf diesem System?
    static var isAvailable: Bool { setLimit != nil }

    /// Wächter für alle Skripte der virtuellen Maschine von `context` einrichten. `flag`
    /// muss so lange leben wie der Kontext (der Lauf hält es fest).
    @discardableResult
    static func install(on context: JSContext, flag: StopFlag) -> Bool {
        guard let setLimit, let group = JSContextGetGroup(context.jsGlobalContextRef) else { return false }
        flag.group = group
        setLimit(group, interval, callback, Unmanaged.passUnretained(flag).toOpaque())
        return true
    }

    /// Antwort an JavaScriptCore. Bei „weiterrechnen“ wird der Zeitgeber neu gestellt: Laut
    /// Test fragte JavaScriptCore sonst nach zwei Antworten „weiter“ nie wieder nach, und ein
    /// später abgebrochenes Skript lief weiter.
    private static let callback: ShouldTerminate = { _, info in
        guard let info else { return false }
        let flag = Unmanaged<StopFlag>.fromOpaque(info).takeUnretainedValue()
        let stop = flag.shouldStop
        ScriptWatchdog.count(stop: stop)
        if !stop, let setLimit = ScriptWatchdog.setLimit, let group = flag.group {
            setLimit(group, ScriptWatchdog.interval, ScriptWatchdog.callback, info)
        }
        return stop
    }
}
