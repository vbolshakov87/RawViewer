import AppKit
import ScreenCaptureKit

/// Development aid, inactive unless RAWVIEWER_SELFTEST is set to an output folder.
/// Runs RAWVIEWER_ACTIONS (comma-separated) one step at a time and writes PNGs
/// of the window after each step, plus timing lines on stderr.
///
/// Actions: next, prev, zoomin, actual, fit, rotate, develop, info, sidebar,
/// sidebarwide, selectall, shiftnext, trash, delete, confirm, cancel, wait.
enum SelfTest {
    static let folder = ProcessInfo.processInfo.environment["RAWVIEWER_SELFTEST"]
    static var enabled: Bool { folder != nil }

    static func log(_ s: String) {
        guard enabled else { return }
        FileHandle.standardError.write(("[selftest] " + s + "\n").data(using: .utf8)!)
    }

    static func start(_ wc: BrowserWindowController) {
        guard let folder else { return }
        let actions = (ProcessInfo.processInfo.environment["RAWVIEWER_ACTIONS"] ?? "")
            .split(separator: ",").map(String.init)
        func run(_ i: Int) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.3) {
                snapshot(wc, to: "\(folder)/step\(i).png")
                if let split = wc.window?.contentViewController as? NSSplitViewController {
                    let panes = split.splitViewItems.map { "\($0.isCollapsed ? "collapsed" : "open") \(NSStringFromRect($0.viewController.view.frame))" }
                    log("panes: " + panes.joined(separator: " | ") + " window=\(NSStringFromRect(wc.window?.frame ?? .zero))")
                }
                log("step \(i) title=\(wc.window?.title ?? "") subtitle=\(wc.window?.subtitle ?? "") count=\(wc.urls.count)")
                guard i < actions.count else {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { NSApp.terminate(nil) }
                    return
                }
                log("action \(actions[i])")
                let table = wc.sidebar.table
                switch actions[i] {
                case "next": wc.goNext(nil)
                case "prev": wc.goPrevious(nil)
                case "zoomin": wc.zoomIn(nil)
                case "actual": wc.zoomToActualSize(nil)
                case "fit": wc.zoomToFit(nil)
                case "rotate": wc.rotateLeft(nil)
                case "develop": wc.toggleDevelopRAW(nil)
                case "info": wc.toggleInfoPanel(nil)
                case "sidebar": NSApp.sendAction(#selector(NSSplitViewController.toggleSidebar(_:)), to: nil, from: nil)
                case "sidebarwide":
                    (wc.window?.contentViewController as? NSSplitViewController)?.splitView.setPosition(330, ofDividerAt: 0)
                case "selectall": wc.selectAll(nil)
                case "shiftnext":
                    let next = (table.selectedRowIndexes.last ?? 0) + 1
                    if next < table.numberOfRows { table.selectRowIndexes(IndexSet(integer: next), byExtendingSelection: true) }
                case "trash":
                    wc.window?.makeFirstResponder(table)
                    let backspace = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                                     windowNumber: wc.window?.windowNumber ?? 0, context: nil,
                                                     characters: "\u{7F}", charactersIgnoringModifiers: "\u{7F}",
                                                     isARepeat: false, keyCode: 51)!
                    if NSApp.mainMenu?.performKeyEquivalent(with: backspace) != true { table.keyDown(with: backspace) }
                case "delete": wc.deleteImmediately(nil)
                case "confirm", "cancel":
                    if let alert = wc.pendingAlert {
                        log("alert: \(alert.messageText) | \(alert.informativeText.replacingOccurrences(of: "\n", with: " "))")
                        let button = actions[i] == "confirm" ? alert.buttons[0] : alert.buttons[1]
                        button.performClick(nil)
                    } else {
                        log("no alert open")
                    }
                default: break
                }
                run(i + 1)
            }
        }
        run(0)
    }

    static func snapshot(_ wc: BrowserWindowController, to path: String) {
        guard let window = wc.window else { return }
        if let content = window.contentView, let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds) {
            content.cacheDisplay(in: content.bounds, to: bitmap)
            try? bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        }
        capture(window, to: path.replacingOccurrences(of: ".png", with: "-real.png"))
        if let sheet = window.attachedSheet {
            capture(sheet, to: path.replacingOccurrences(of: ".png", with: "-sheet.png"))
        }
    }

    /// The window as the window server composites it: glass, transparency, traffic lights.
    static func capture(_ window: NSWindow, to out: String) {
        if #available(macOS 14.4, *) {
            let id = CGWindowID(window.windowNumber)
            Task {
                do {
                    let content = try await SCShareableContent.currentProcess
                    guard let scWindow = content.windows.first(where: { $0.windowID == id }) else {
                        log("capture: window not found"); return
                    }
                    let filter = SCContentFilter(desktopIndependentWindow: scWindow)
                    let config = SCStreamConfiguration()
                    config.width = Int(filter.contentRect.width * CGFloat(filter.pointPixelScale))
                    config.height = Int(filter.contentRect.height * CGFloat(filter.pointPixelScale))
                    config.showsCursor = false
                    config.ignoreShadowsSingleWindow = true
                    let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
                    try NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?
                        .write(to: URL(fileURLWithPath: out))
                } catch {
                    log("capture failed: \(error.localizedDescription)")
                }
            }
        }
    }
}
