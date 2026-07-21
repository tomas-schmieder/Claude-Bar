import AppKit

@main
enum ClaudeBarMain {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusController: StatusItemController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let controller = StatusItemController()
        controller.start()
        self.statusController = controller
    }

    func applicationWillTerminate(_ notification: Notification) {
        self.statusController?.stop()
    }
}
