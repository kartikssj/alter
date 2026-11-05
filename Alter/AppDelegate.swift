import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    let settingsStore = SettingsStore()
    private var coordinator: SwitcherCoordinator?
    private let statusItem = StatusItemController()
    private var settingsWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Regular app: Dock icon + menu bar while running. The switcher panel
        // itself is non-activating, so this never steals focus.
        NSApp.setActivationPolicy(.regular)
        installMainMenu()
        statusItem.install()
        let coordinator = SwitcherCoordinator(settings: settingsStore)
        coordinator.start()
        self.coordinator = coordinator
    }

    /// Clicking the Dock icon (or `open`-ing the app again) opens Settings.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        Self.openSettings()
        return true
    }

    static func openSettings() {
        (NSApp.delegate as? AppDelegate)?.showSettings()
    }

    @objc func showSettings() {
        if let settingsWindow {
            settingsWindow.makeKeyAndOrderFront(nil)
            NSApp.activate()
            return
        }
        let hostingView = NSHostingView(rootView: SettingsView(settings: settingsStore))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 420),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Alter Settings"
        window.contentView = hostingView
        let fitting = hostingView.fittingSize
        if fitting.width > 10, fitting.height > 10 {
            window.setContentSize(fitting)
        }
        window.center()
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
        settingsWindow = window
    }

    /// No nib/storyboard: build the app menu by hand.
    private func installMainMenu() {
        let mainMenu = NSMenu()
        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)

        let appMenu = NSMenu()
        let about = NSMenuItem(title: "About Alter", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        about.target = NSApp
        appMenu.addItem(about)
        appMenu.addItem(.separator())
        let settings = NSMenuItem(title: "Settings…", action: #selector(showSettings), keyEquivalent: ",")
        settings.target = self
        appMenu.addItem(settings)
        appMenu.addItem(.separator())
        let hide = NSMenuItem(title: "Hide Alter", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        hide.target = NSApp
        appMenu.addItem(hide)
        appMenu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit Alter", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.target = NSApp
        appMenu.addItem(quit)

        appMenuItem.submenu = appMenu
        NSApp.mainMenu = mainMenu
    }
}
