import AppKit
import VoxLocalCore

@main
struct VoxLocalMain {
    static func main() {
        // The process entry point always runs on the main thread.
        MainActor.assumeIsolated {
            let app = NSApplication.shared
            let delegate = AppDelegate()
            app.delegate = delegate
            // Menu-bar app: no Dock icon, no app switcher entry. LSUIElement
            // in Info.plist covers the packaged app; this covers `swift run`.
            app.setActivationPolicy(.accessory)
            withExtendedLifetime(delegate) {
                app.run()
            }
        }
    }
}
