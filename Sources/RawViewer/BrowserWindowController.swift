import AppKit

private extension NSToolbarItem.Identifier {
    static let viewMenu = Self("view")
    static let zoom = Self("zoom_and_actual")
    static let rotate = Self("rotate")
    static let developRAW = Self("develop_raw")
    static let inspector = Self("inspector")
    static let share = Self("share")
}

/// One window per open action: thumbnail sidebar, image, Info panel.
/// Toolbar: View menu | zoom out / actual / zoom in | rotate | develop RAW | info | share.
final class BrowserWindowController: NSWindowController, NSWindowDelegate, NSToolbarDelegate,
    NSSharingServicePickerToolbarItemDelegate, NSMenuItemValidation {

    static let infoShownKey = "InfoPanelShown"

    private(set) var urls: [URL]
    private(set) var index = -1
    private let split = NSSplitViewController()
    let sidebar: SidebarViewController
    let viewer = ImageViewController()
    private let info = InfoViewController()
    private(set) var sidebarItem: NSSplitViewItem!
    private var infoItem: NSSplitViewItem!
    private var isDeleting = false
    /// The open confirmation sheet, exposed for the self-test.
    private(set) var pendingAlert: NSAlert?
    var onClose: (() -> Void)?

    init(urls: [URL]) {
        self.urls = urls
        sidebar = SidebarViewController(urls: urls)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1320, height: 820),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        super.init(window: window)
        shouldCascadeWindows = true
        UserDefaults.standard.register(defaults: [Self.infoShownKey: true])

        sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebar)
        sidebarItem.minimumThickness = 150
        sidebarItem.maximumThickness = 360
        sidebarItem.canCollapse = true
        // A plain pane: the inspector-style item floats over the image on macOS 26+
        // and clipped the panel's left edge.
        infoItem = NSSplitViewItem(viewController: info)
        infoItem.minimumThickness = 250
        infoItem.maximumThickness = 520
        infoItem.canCollapse = true
        infoItem.holdingPriority = NSLayoutConstraint.Priority(270)
        split.addSplitViewItem(sidebarItem)
        split.addSplitViewItem(NSSplitViewItem(viewController: viewer))
        split.addSplitViewItem(infoItem)

        window.contentViewController = split
        window.setContentSize(NSSize(width: 1320, height: 820))
        window.minSize = NSSize(width: 560, height: 360)
        window.delegate = self
        window.toolbarStyle = .unified
        window.tabbingMode = .preferred
        let toolbar = NSToolbar(identifier: "RawViewerToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = true
        toolbar.autosavesConfiguration = true
        window.toolbar = toolbar
        if !window.setFrameAutosaveName("RawViewerWindow") || window.frame.origin == .zero {
            window.center()
        }
        // A single image opens without the sidebar.
        sidebarItem.isCollapsed = urls.count < 2
        infoItem.isCollapsed = !UserDefaults.standard.bool(forKey: Self.infoShownKey)

        sidebar.onSelect = { [weak self] in self?.show(index: $0) }
        sidebar.onSelectionChange = { [weak self] in self?.updateSubtitle() }
        viewer.onNavigate = { [weak self] in self?.step($0) }
        viewer.onDrop = { urls in (NSApp.delegate as? AppDelegate)?.open(urls) }
        viewer.onStatusChange = { [weak self] in self?.updateSubtitle() }
        show(index: 0)
        window.makeFirstResponder(viewer.canvas)
        SelfTest.start(self)
    }
    required init?(coder: NSCoder) { fatalError() }

    var currentURL: URL? { urls.indices.contains(index) ? urls[index] : nil }

    // MARK: Navigation

    func show(index i: Int) {
        guard urls.indices.contains(i) else { return }
        index = i
        let url = urls[i]
        window?.title = url.lastPathComponent
        window?.representedURL = url
        sidebar.show(i)
        viewer.display(url: url)
        if !infoItem.isCollapsed { info.show(url: url) }
        updateSubtitle()
        prefetchNeighbours()
    }

    /// Next two and previous one, decoded before they are asked for.
    private func prefetchNeighbours() {
        let around = [index + 1, index - 1, index + 2].filter(urls.indices.contains).map { urls[$0] }
        ImageLoader.prefetch(around, develop: viewer.developRAW)
    }

    func step(_ delta: Int) {
        let target = min(max(index + delta, 0), urls.count - 1)
        guard target != index else { return }
        sidebar.selectOnly(target)
        show(index: target)
    }

    private func updateSubtitle() {
        var parts: [String] = []
        if urls.count > 1 { parts.append("\(index + 1) of \(urls.count)") }
        let selected = sidebar.selectedIndexes.count
        if selected > 1, !sidebarItem.isCollapsed { parts.append("\(selected) selected") }
        if let current = viewer.current, let url = currentURL, ImageLoader.isRAW(url) {
            parts.append(current.isEmbeddedPreview ? "Camera JPEG" : "Developed RAW")
        }
        if viewer.info != nil { parts.append("\(viewer.zoomPercent)%") }
        window?.subtitle = parts.joined(separator: " · ")
    }

    @objc func goNext(_ sender: Any?) { step(1) }
    @objc func goPrevious(_ sender: Any?) { step(-1) }
    @objc func goFirst(_ sender: Any?) { step(-index) }
    @objc func goLast(_ sender: Any?) { step(urls.count - 1 - index) }

    override func selectAll(_ sender: Any?) {
        sidebarItem.animator().isCollapsed = false
        sidebar.selectAllImages()
        updateSubtitle()
    }

    // MARK: View commands

    @objc func zoomIn(_ sender: Any?) { viewer.zoomIn(); updateSubtitle() }
    @objc func zoomOut(_ sender: Any?) { viewer.zoomOut(); updateSubtitle() }
    @objc func zoomToActualSize(_ sender: Any?) { viewer.zoomToActualSize(); updateSubtitle() }
    @objc func zoomToFit(_ sender: Any?) { viewer.zoomToFit(); updateSubtitle() }
    @objc func rotateLeft(_ sender: Any?) { viewer.rotate(by: 1) }
    @objc func rotateRight(_ sender: Any?) { viewer.rotate(by: -1) }

    @objc func toggleInfoPanel(_ sender: Any?) {
        let show = infoItem.isCollapsed
        infoItem.animator().isCollapsed = !show
        UserDefaults.standard.set(show, forKey: Self.infoShownKey)
        if show { info.show(url: currentURL) }
    }

    @objc func toggleDevelopRAW(_ sender: Any?) {
        viewer.developRAW.toggle()
        prefetchNeighbours()
        window?.toolbar?.items.first { $0.itemIdentifier == .developRAW }.map {
            ($0.view as? NSButton)?.state = viewer.developRAW ? .on : .off
        }
    }

    @objc func zoomSegment(_ sender: NSToolbarItemGroup) {
        switch sender.selectedIndex {
        case 0: zoomOut(sender)
        case 1: zoomToActualSize(sender)
        default: zoomIn(sender)
        }
    }

    @objc func showInFinder(_ sender: Any?) {
        let selected = deletionTargets.map { urls[$0] }
        if !selected.isEmpty { NSWorkspace.shared.activateFileViewerSelecting(selected) }
    }

    @objc func copy(_ sender: Any?) {
        guard let url = currentURL else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        var objects: [NSPasteboardWriting] = [url as NSURL]
        if let cg = viewer.displayedImage {
            objects.insert(NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height)), at: 0)
        }
        pb.writeObjects(objects)
    }

    // MARK: Deletion

    /// The sidebar selection when several images are selected, otherwise the shown image.
    private var deletionTargets: IndexSet {
        let selected = sidebar.selectedIndexes.filteredIndexSet { urls.indices.contains($0) }
        if !sidebarItem.isCollapsed, selected.count > 1 { return selected }
        return urls.indices.contains(index) ? IndexSet(integer: index) : []
    }

    @objc func moveToTrash(_ sender: Any?) { confirmDeletion(permanently: false) }
    @objc func deleteImmediately(_ sender: Any?) { confirmDeletion(permanently: true) }

    private func confirmDeletion(permanently: Bool) {
        guard !isDeleting, let window, window.attachedSheet == nil else { return }
        let targets = deletionTargets
        guard !targets.isEmpty else { return }
        let files = targets.map { urls[$0] }
        let sidecarCount = files.reduce(0) { $0 + FileDeletion.sidecars(for: $1).count }

        let alert = NSAlert()
        alert.alertStyle = permanently ? .critical : .warning
        let what = files.count == 1 ? "“\(files[0].lastPathComponent)”" : "\(files.count) images"
        alert.messageText = permanently ? "Permanently delete \(what)?" : "Move \(what) to the Trash?"
        var lines: [String] = []
        if files.count > 1 {
            let names = files.prefix(6).map(\.lastPathComponent).joined(separator: ", ")
            lines.append(files.count > 6 ? "\(names) and \(files.count - 6) more." : names + ".")
        }
        if sidecarCount > 0 {
            lines.append("\(sidecarCount) matching .xmp sidecar file\(sidecarCount == 1 ? "" : "s") will be \(permanently ? "deleted" : "moved") too.")
        }
        lines.append(permanently ? "This can't be undone."
                     : "You can put \(files.count == 1 ? "it" : "them") back from the Trash in Finder.")
        alert.informativeText = lines.joined(separator: "\n\n")

        if permanently {
            let delete = alert.addButton(withTitle: "Delete")
            delete.hasDestructiveAction = true
            delete.keyEquivalent = ""
            let cancel = alert.addButton(withTitle: "Cancel")
            cancel.keyEquivalent = "\r"
        } else {
            alert.addButton(withTitle: "Move to Trash")
            alert.addButton(withTitle: "Cancel")
        }

        pendingAlert = alert
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            self.pendingAlert = nil
            guard response == .alertFirstButtonReturn else { return }
            self.performDeletion(of: files, permanently: permanently)
        }
    }

    private func performDeletion(of files: [URL], permanently: Bool) {
        isDeleting = true
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = FileDeletion.delete(files, permanently: permanently)
            DispatchQueue.main.async {
                guard let self else { return }
                self.isDeleting = false
                self.removeFromList(result.removed)
                if !result.failed.isEmpty { self.reportFailures(result.failed) }
            }
        }
    }

    private func removeFromList(_ removed: [URL]) {
        guard !removed.isEmpty else { return }
        let gone = Set(removed)
        let indexes = IndexSet(urls.indices.filter { gone.contains(urls[$0]) })
        let shown = currentURL
        let firstRemoved = indexes.first ?? 0
        for i in indexes.reversed() { urls.remove(at: i) }
        removed.forEach(ImageLoader.forget)
        sidebar.remove(indexes)
        info.reset()
        guard !urls.isEmpty else {
            window?.close()
            return
        }
        let next = shown.flatMap { urls.firstIndex(of: $0) } ?? min(firstRemoved, urls.count - 1)
        sidebar.selectOnly(next)
        show(index: next)
    }

    private func reportFailures(_ failures: [(url: URL, error: Error)]) {
        guard let window else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = failures.count == 1
            ? "“\(failures[0].url.lastPathComponent)” couldn't be deleted."
            : "\(failures.count) files couldn't be deleted."
        alert.informativeText = failures.prefix(5)
            .map { "\($0.url.lastPathComponent): \($0.error.localizedDescription)" }
            .joined(separator: "\n")
        alert.beginSheetModal(for: window)
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(goNext(_:)), #selector(goLast(_:)): return index < urls.count - 1
        case #selector(goPrevious(_:)), #selector(goFirst(_:)): return index > 0
        case #selector(moveToTrash(_:)), #selector(deleteImmediately(_:)):
            let n = deletionTargets.count
            let permanent = item.action == #selector(deleteImmediately(_:))
            item.title = permanent
                ? (n > 1 ? "Delete \(n) Images Immediately…" : "Delete Immediately…")
                : (n > 1 ? "Move \(n) Images to Trash…" : "Move to Trash…")
            return !isDeleting && n > 0 && window?.attachedSheet == nil
        case #selector(toggleDevelopRAW(_:)):
            item.state = viewer.developRAW ? .on : .off
            return true
        case #selector(toggleInfoPanel(_:)):
            item.title = infoItem.isCollapsed ? "Show Info" : "Hide Info"
            return true
        default: return true
        }
    }

    // MARK: Window

    func windowWillClose(_ notification: Notification) { onClose?() }
    func windowDidBecomeKey(_ notification: Notification) { sidebar.refreshSelectionAppearance() }
    func windowDidResignKey(_ notification: Notification) { sidebar.refreshSelectionAppearance() }

    // MARK: Toolbar

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        // No sidebar tracking separator: items pinned to the sidebar section vanish
        // into the overflow menu while the sidebar is collapsed.
        [.viewMenu, .zoom, .flexibleSpace, .rotate, .developRAW, .flexibleSpace, .inspector, .share]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar) + [.space, .flexibleSpace, .toggleSidebar, .sidebarTrackingSeparator]
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        func symbol(_ name: String, _ label: String) -> NSImage {
            NSImage(systemSymbolName: name, accessibilityDescription: label) ?? NSImage()
        }
        switch id {
        case .viewMenu:
            let item = NSMenuToolbarItem(itemIdentifier: id)
            item.image = symbol("sidebar.leading", "View")
            item.label = "View"
            item.toolTip = "View Menu"
            let menu = NSMenu()
            menu.addItem(NSMenuItem(title: "Hide Sidebar", action: #selector(NSSplitViewController.toggleSidebar(_:)), keyEquivalent: ""))
            menu.addItem(NSMenuItem(title: "Show Info", action: #selector(toggleInfoPanel(_:)), keyEquivalent: ""))
            menu.addItem(.separator())
            menu.addItem(NSMenuItem(title: "Zoom to Fit", action: #selector(zoomToFit(_:)), keyEquivalent: ""))
            menu.addItem(NSMenuItem(title: "Actual Size", action: #selector(zoomToActualSize(_:)), keyEquivalent: ""))
            item.menu = menu
            return item
        case .zoom:
            let group = NSToolbarItemGroup(
                itemIdentifier: id,
                images: [symbol("minus.magnifyingglass", "Zoom Out"),
                         symbol("1.magnifyingglass", "Actual Size"),
                         symbol("plus.magnifyingglass", "Zoom In")],
                selectionMode: .momentary,
                labels: ["Zoom Out", "Actual Size", "Zoom In"],
                target: self, action: #selector(zoomSegment(_:)))
            group.label = "Zoom"
            return group
        case .rotate:
            return button(id, "Rotate", "rotate.left", #selector(rotateLeft(_:)), "Rotate Left")
        case .inspector:
            return button(id, "Info", "info.circle", #selector(toggleInfoPanel(_:)), "Show or hide the Info panel")
        case .developRAW:
            let item = NSToolbarItem(itemIdentifier: id)
            let b = NSButton(image: symbol("camera.aperture", "Develop RAW"), target: self, action: #selector(toggleDevelopRAW(_:)))
            b.setButtonType(.pushOnPushOff)
            b.bezelStyle = .texturedRounded
            b.state = viewer.developRAW ? .on : .off
            item.view = b
            item.label = "Develop RAW"
            item.toolTip = "Off: show the camera's embedded JPEG (instant). On: develop every RAW file."
            return item
        case .share:
            let item = NSSharingServicePickerToolbarItem(itemIdentifier: id)
            item.delegate = self
            item.label = "Share"
            return item
        default:
            return nil
        }
    }

    private func button(_ id: NSToolbarItem.Identifier, _ label: String, _ symbolName: String,
                        _ action: Selector, _ tip: String) -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: id)
        item.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: label)
        item.label = label
        item.toolTip = tip
        item.target = self
        item.action = action
        item.isBordered = true
        return item
    }

    func items(for pickerToolbarItem: NSSharingServicePickerToolbarItem) -> [Any] {
        deletionTargets.map { urls[$0] }
    }
}
