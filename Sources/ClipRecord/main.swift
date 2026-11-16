import AppKit

// AppKit owns menu-bar/window lifetime; all user interfaces are native SwiftUI views.
MainActor.assumeIsolated {
    let application = NSApplication.shared
    let delegate = AppDelegate()
    application.delegate = delegate
    withExtendedLifetime(delegate) { application.run() }
}
