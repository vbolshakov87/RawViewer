import AppKit
import UniformTypeIdentifiers

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var windowControllers: [BrowserWindowController] = []

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = MainMenu.build()
        if let screen = NSScreen.main {
            let side = max(screen.frame.width, screen.frame.height) * screen.backingScaleFactor
            ImageLoader.previewMaxPixel = Int(side)
        }
        ImageLoader.warmUp()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Paths passed on the command line (`RawViewer file.NEF folder/`).
        let paths = CommandLine.arguments.dropFirst().filter { FileManager.default.fileExists(atPath: $0) }
        if !paths.isEmpty {
            open(paths.map { URL(fileURLWithPath: $0) })
        } else if windowControllers.isEmpty {
            openDocument(nil)
        }
        NSApp.activate()
    }

    /// Finder "Open With", drops on the Dock icon, `open -a`.
    func application(_ application: NSApplication, open urls: [URL]) {
        open(urls)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { openDocument(nil) }
        return true
    }

    @objc func openDocument(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.image, .folder]
        panel.message = "Choose images or a folder of images"
        panel.begin { [weak self] response in
            if response == .OK { self?.open(panel.urls) }
        }
    }

    func open(_ urls: [URL]) {
        let items = ImageLoader.expand(urls)
        guard !items.isEmpty else {
            let alert = NSAlert()
            alert.messageText = "No images found"
            alert.informativeText = urls.map(\.lastPathComponent).joined(separator: ", ")
            alert.runModal()
            return
        }
        let controller = BrowserWindowController(urls: items)
        controller.onClose = { [weak self, weak controller] in
            self?.windowControllers.removeAll { $0 === controller }
        }
        windowControllers.append(controller)
        controller.showWindow(nil)
    }
}
