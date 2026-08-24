import Cocoa

// MARK: - ClipApp

@main
struct ClipApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var mainViewModel = MainViewModel()
    @StateObject private var downloadViewModel = DownloadViewModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(mainViewModel)
                .environmentObject(downloadViewModel)
                .frame(minWidth: 620, minHeight: 640)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)

        Settings {
            SettingsView()
                .environmentObject(mainViewModel)
                .frame(width: 420)
        }
    }
}

// MARK: - AppDelegate

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var clipboardMonitor: ClipboardMonitor?
    private var menuBarController: MenuBarController?
    private var windowCloseInterceptor: WindowCloseInterceptor?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)

        // Tag the main window for TranslucentWindowBackground lookup.
        if let window = NSApp.windows.first(where: { $0.isVisible }) {
            window.identifier = NSUserInterfaceItemIdentifier("ClipMainWindow")
            windowCloseInterceptor = WindowCloseInterceptor()
            window.delegate = windowCloseInterceptor
            window.isReleasedWhenClosed = false
        }

        clipboardMonitor = ClipboardMonitor()
        clipboardMonitor?.start()

        menuBarController = MenuBarController(
            onOpenWindow: { [weak self] in self?.showMainWindow() },
            onPasteAndAnalyze: { [weak self] in self?.pasteIntoMainWindow() }
        )
        menuBarController?.install()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false // close = hide (WindowCloseInterceptor), app stays in Dock/menu bar
    }

    @objc func showMainWindow() {
        for window in NSApp.windows where window.identifier?.rawValue == "ClipMainWindow" {
            window.makeKeyAndOrderFront(nil)
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    private func pasteIntoMainWindow() {
        showMainWindow()
        NotificationCenter.default.post(name: .clipPasteRequested, object: nil)
    }
}

// MARK: - Notifications

extension Notification.Name {
    static let clipPasteRequested = Notification.Name("clipPasteRequested")
}
