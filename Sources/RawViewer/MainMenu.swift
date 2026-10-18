import AppKit

/// Menu bar. Key equivalents match the ones macOS users know from Preview: ⌘0 actual size, ⌘9 zoom to fit,
/// ⌘L/⌘R rotate, ⌘I inspector, ⌥⌘S sidebar, ⌥⌘↑/↓ previous/next.
enum MainMenu {
    static func build() -> NSMenu {
        let main = NSMenu()
        let name = ProcessInfo.processInfo.processName

        main.addItem(submenu("", [
            item("About \(name)", #selector(NSApplication.orderFrontStandardAboutPanel(_:))),
            .separator(),
            item("Hide \(name)", #selector(NSApplication.hide(_:)), "h"),
            item("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]),
            item("Show All", #selector(NSApplication.unhideAllApplications(_:))),
            .separator(),
            item("Quit \(name)", #selector(NSApplication.terminate(_:)), "q"),
        ]))

        // ⌫ moves to Trash (with confirmation); ⌘⌫ does the same, as in Finder.
        let backspace = String(Character(UnicodeScalar(NSBackspaceCharacter)!))
        let trashAlt = item("Move to Trash…", #selector(BrowserWindowController.moveToTrash(_:)), backspace, .command)
        trashAlt.isHidden = true
        trashAlt.allowsKeyEquivalentWhenHidden = true

        main.addItem(submenu("File", [
            item("Open…", #selector(AppDelegate.openDocument(_:)), "o"),
            .separator(),
            item("Close", #selector(NSWindow.performClose(_:)), "w"),
            .separator(),
            item("Move to Trash…", #selector(BrowserWindowController.moveToTrash(_:)), backspace, []),
            trashAlt,
            item("Delete Immediately…", #selector(BrowserWindowController.deleteImmediately(_:)), backspace, [.command, .option]),
            .separator(),
            item("Show in Finder", #selector(BrowserWindowController.showInFinder(_:)), "r", [.command, .shift, .option]),
        ]))

        main.addItem(submenu("Edit", [
            item("Copy", #selector(BrowserWindowController.copy(_:)), "c"),
            item("Select All", #selector(NSResponder.selectAll(_:)), "a"),
        ]))

        let zoomInAlt = item("Zoom In", #selector(BrowserWindowController.zoomIn(_:)), "=")
        zoomInAlt.isHidden = true
        zoomInAlt.allowsKeyEquivalentWhenHidden = true
        main.addItem(submenu("View", [
            item("Hide Sidebar", #selector(NSSplitViewController.toggleSidebar(_:)), "s", [.command, .option]),
            .separator(),
            item("Actual Size", #selector(BrowserWindowController.zoomToActualSize(_:)), "0"),
            item("Zoom to Fit", #selector(BrowserWindowController.zoomToFit(_:)), "9"),
            item("Zoom In", #selector(BrowserWindowController.zoomIn(_:)), "+"),
            zoomInAlt,
            item("Zoom Out", #selector(BrowserWindowController.zoomOut(_:)), "-"),
            .separator(),
            item("Develop RAW", #selector(BrowserWindowController.toggleDevelopRAW(_:)), "r", [.command, .shift]),
            .separator(),
            item("Enter Full Screen", #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control]),
        ]))

        let up = String(Character(UnicodeScalar(NSUpArrowFunctionKey)!))
        let down = String(Character(UnicodeScalar(NSDownArrowFunctionKey)!))
        main.addItem(submenu("Go", [
            item("Previous", #selector(BrowserWindowController.goPrevious(_:)), up, [.command, .option]),
            item("Next", #selector(BrowserWindowController.goNext(_:)), down, [.command, .option]),
            .separator(),
            item("First", #selector(BrowserWindowController.goFirst(_:)), "\u{F729}", [.command, .option]),
            item("Last", #selector(BrowserWindowController.goLast(_:)), "\u{F72B}", [.command, .option]),
        ]))

        main.addItem(submenu("Tools", [
            item("Rotate Left", #selector(BrowserWindowController.rotateLeft(_:)), "l"),
            item("Rotate Right", #selector(BrowserWindowController.rotateRight(_:)), "r"),
            .separator(),
            item("Show Info", #selector(BrowserWindowController.toggleInfoPanel(_:)), "i"),
        ]))

        let window = submenu("Window", [
            item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"),
            item("Zoom", #selector(NSWindow.performZoom(_:))),
            .separator(),
            item("Bring All to Front", #selector(NSApplication.arrangeInFront(_:))),
        ])
        main.addItem(window)
        NSApp.windowsMenu = window.submenu
        return main
    }

    private static func submenu(_ title: String, _ items: [NSMenuItem]) -> NSMenuItem {
        let menu = NSMenu(title: title)
        items.forEach(menu.addItem)
        let holder = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        holder.submenu = menu
        return holder
    }

    private static func item(_ title: String, _ action: Selector, _ key: String = "",
                             _ mods: NSEvent.ModifierFlags = .command) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = mods
        return item
    }
}
