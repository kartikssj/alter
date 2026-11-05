import AppKit

// Plain AppKit bootstrap (no SwiftUI App lifecycle / scene magic).
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
