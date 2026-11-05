import AppKit

/// Menu-bar presence for the agent app: a visible sign of life and the only
/// in-app way to quit (there is no Dock icon or main menu).
final class StatusItemController {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

    func install() {
        if let button = statusItem.button {
            let image = NSImage(systemSymbolName: "rectangle.stack", accessibilityDescription: "Alter")
            image?.isTemplate = true
            button.image = image
            button.toolTip = "Alter window switcher (\u{2325}\u{21E5} / \u{2325}`)"
        }
        let menu = NSMenu()
        let status = NSMenuItem(title: "Alter is running", action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)
        menu.addItem(.separator())
        let settings = NSMenuItem(title: "Settings…", action: #selector(showSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)
        let quit = NSMenuItem(title: "Quit Alter", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.target = NSApp
        menu.addItem(quit)
        statusItem.menu = menu
    }

    @objc private func showSettings() {
        AppDelegate.openSettings()
    }
}
