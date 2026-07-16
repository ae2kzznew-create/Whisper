import AppKit
import VoxLocalCore

@main
struct VoxLocalMain {
    // @MainActor instead of MainActor.assumeIsolated: the entry point runs on
    // the main thread, and this spelling also compiles against the macOS 13
    // SDK / Swift 5.8, where assumeIsolated is unavailable.
    @MainActor
    static func main() {
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
