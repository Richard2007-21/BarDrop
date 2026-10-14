import AppKit
import SwiftUI
import Carbon
import Combine

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let settings = AppSettings.shared
    private var store: ShelfStore!
    private var ui: ShelfUIModel!
    private var controller: EdgeController!
    private var statusItem: NSStatusItem?
    private var menuBarObserver: AnyCancellable?
    private var hotKeyObserver: AnyCancellable?
    private var settingsWindow: NSWindow?
    private var hotKey: HotKey?
    private var onboarding: OnboardingController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        endOtherInstances()
        store = ShelfStore()
        ui = ShelfUIModel()
        controller = EdgeController(store: store, ui: ui, settings: settings)
        controller.actions.openSettings = { [weak self] in self?.showSettings() }
        controller.keepAppActive = { [weak self] in
            self?.settingsWindow?.isVisible == true || self?.onboarding?.isVisible == true
        }
        // Herausziehen fehlgeschlagen: Objekt zurück in die Ablage
        DragExporter.shared.onFailed = { [weak self] url in self?.store.restore(url) }

        // Symbol in der Menüleiste nur auf Wunsch. Ohne Symbol erreicht man alles über
        // einen Rechtsklick in die Ablage oder durch erneutes Öffnen von BarDrop.
        menuBarObserver = settings.$showMenuBarIcon
            .removeDuplicates()
            .sink { [weak self] show in
                if show { self?.setupStatusItem() } else { self?.removeStatusItem() }
            }

        // Kurzbefehl, neu registriert, sobald er in den Einstellungen geändert wird
        hotKeyObserver = settings.$hotKeyCode.combineLatest(settings.$hotKeyModifiers)
            .removeDuplicates { $0 == $1 }
            .sink { [weak self] code, modifiers in self?.registerHotKey(code: code, modifiers: modifiers) }

        Updater.shared.start()

        if !settings.didLaunchBefore {
            settings.didLaunchBefore = true
            showOnboarding()
        }
    }

    private func registerHotKey(code: Int, modifiers: Int) {
        hotKey = nil
        let key = HotKey(keyCode: UInt32(code), modifiers: UInt32(modifiers)) { [weak self] in
            self?.controller.toggle()
            self?.onboarding?.hotKeyPressed()
        }
        hotKey = key
        HotKeyStatus.shared.available = key.registered
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Widerrufen ist nach dem Beenden nicht mehr möglich: aufgehobene Dateien löschen
        store?.discardUndoHistory()
    }

    // MARK: Einführung

    func showOnboarding() {
        if onboarding == nil {
            let onboarding = OnboardingController(store: store, ui: ui, settings: settings)
            onboarding.onClose = { [weak self] in self?.onboarding = nil }
            onboarding.wakeShelf = { [weak self] in self?.controller.wake() }
            onboarding.openSettings = { [weak self] in
                DispatchQueue.main.async { self?.showSettings() }
            }
            self.onboarding = onboarding
        }
        onboarding?.show()
    }

    /// Läuft BarDrop schon (z. B. eine ältere Version aus dem DMG), wird diese beendet.
    /// Zwei Ablagen am selben Rand würden sich gegenseitig stören (nach perch).
    private func endOtherInstances() {
        guard let id = Bundle.main.bundleIdentifier else { return }
        let me = ProcessInfo.processInfo.processIdentifier
        for app in NSRunningApplication.runningApplications(withBundleIdentifier: id)
        where app.processIdentifier != me {
            Log.edge.info("Andere BarDrop-Instanz wird beendet")
            app.terminate()
        }
    }

    // MARK: Menüleiste

    private func removeStatusItem() {
        if let statusItem { NSStatusBar.system.removeStatusItem(statusItem) }
        statusItem = nil
    }

    private func setupStatusItem() {
        guard statusItem == nil else { return }
        let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        self.statusItem = statusItem
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "tray.and.arrow.down", accessibilityDescription: "BarDrop")
            button.image?.isTemplate = true
        }
        let menu = NSMenu()
        menu.addItem(ClosureMenuItem("Ablage öffnen", symbol: "sidebar.right") { [weak self] in
            self?.controller.toggle()
        })
        menu.addItem(ClosureMenuItem("Aus Zwischenablage einfügen", symbol: "doc.on.clipboard") { [weak self] in
            self?.store.pasteFromClipboard()
            self?.controller.toggle()
        })
        menu.addItem(ClosureMenuItem("Alle Objekte entfernen", symbol: "xmark.circle") { [weak self] in
            guard let self else { return }
            let count = self.store.entries.reduce(0) { $0 + $1.files.count }
            if ShelfActions.confirmRemovingAll(count) { self.store.removeAll() }
        })
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem("Einstellungen", symbol: "gearshape", key: ",") { [weak self] in
            self?.showSettings()
        })
        menu.addItem(ClosureMenuItem("BarDrop beenden", symbol: "power", key: "q") {
            NSApp.terminate(nil)
        })
        statusItem.menu = menu
    }

    // MARK: Einstellungen

    func showSettings() {
        if settingsWindow == nil {
            let window = SettingsWindowFactory.make(settings: settings, store: store) { [weak self] in
                DispatchQueue.main.async { self?.showOnboarding() }
            }
            window.delegate = self
            settingsWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        if (notification.object as? NSWindow) === settingsWindow {
            DispatchQueue.main.async { NSApp.deactivate() }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showSettings()
        return true
    }
}
