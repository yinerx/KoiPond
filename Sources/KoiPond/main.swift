import AppKit

// Plain AppKit entry point: the app manages its own windows (pond, wallpaper, config) and a menu-bar item.
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
