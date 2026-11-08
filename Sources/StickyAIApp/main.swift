import AppKit
#if canImport(StickyAICore)
import StickyAICore
#endif

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controller: StickyAppController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let env = ProcessInfo.processInfo.environment

        let configDir = env["STICKY_AI_USER_DATA_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }
        let configStore = ConfigStore(directoryURL: configDir)

        let urlString = env["STICKY_AI_URL"] ?? StickyConstants.defaultGeminiURL
        let initialURL = URL(string: urlString) ?? URL(string: StickyConstants.defaultGeminiURL)!

        let appController = StickyAppController(
            configStore: configStore,
            initialURL: initialURL,
            enableStatusItem: true,
            registerGlobalHotKey: true
        )
        self.controller = appController
        appController.start()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        controller?.showAndFocusWindow(focusInput: true)
        return true
    }
}

let app = NSApplication.shared
if ProcessInfo.processInfo.environment["STICKY_AI_SHOW_DOCK"] != "1" {
    app.setActivationPolicy(.accessory)
} else {
    app.setActivationPolicy(.regular)
}

let delegate = AppDelegate()
app.delegate = delegate
app.run()
