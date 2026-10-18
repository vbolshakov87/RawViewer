import AppKit

/// A table whose last column always spans the visible width, so cells can
/// centre their content however wide the sidebar or panel is dragged.
final class FullWidthTableView: NSTableView {
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        fitColumn()
    }

    /// ⌫ / ⌘⌫ move the selection to the Trash, ⌥⌘⌫ deletes it; both ask first.
    override func keyDown(with event: NSEvent) {
        if let action = FileDeletion.action(for: event), tryToPerform(action, with: self) { return }
        super.keyDown(with: event)
    }

    func fitColumn() {
        guard let last = tableColumns.last else { return }
        let available = enclosingScrollView?.contentView.bounds.width ?? bounds.width
        let others = tableColumns.dropLast().reduce(CGFloat(0)) { $0 + $1.width + intercellSpacing.width }
        let width = max(available - others - intercellSpacing.width, last.minWidth)
        if abs(last.width - width) > 0.5 { last.width = width }
    }
}

/// Thumbnail with the file name below. Selection looks like Preview and Finder:
/// a rounded box behind the image and a capsule behind the name.
final class ThumbnailCell: NSView {
    static let identifier = NSUserInterfaceItemIdentifier("ThumbnailCell")
    private let selectionBox = NSView()
    private let thumb = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private(set) var url: URL?

    var isSelected = false { didSet { if isSelected != oldValue { updateSelection() } } }
    var isEmphasized = true { didSet { if isEmphasized != oldValue { updateSelection() } } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        identifier = Self.identifier
        selectionBox.wantsLayer = true
        selectionBox.layer?.cornerRadius = 8
        thumb.imageScaling = .scaleAxesIndependently
        thumb.wantsLayer = true
        thumb.layer?.shadowOpacity = 0.3
        thumb.layer?.shadowRadius = 2
        thumb.layer?.shadowOffset = .zero
        label.font = .systemFont(ofSize: 11)
        label.alignment = .center
        label.lineBreakMode = .byTruncatingMiddle
        label.wantsLayer = true
        label.layer?.cornerRadius = 8
        for v in [selectionBox, thumb, label] as [NSView] { addSubview(v) }
    }
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        let labelHeight: CGFloat = 16
        let box = NSRect(x: 16, y: 10, width: max(bounds.width - 32, 10), height: max(bounds.height - labelHeight - 26, 10))
        var rect = box
        if let size = thumb.image?.size, size.width > 0, size.height > 0 {
            let scale = min(box.width / size.width, box.height / size.height)
            let w = size.width * scale, h = size.height * scale
            rect = NSRect(x: box.midX - w / 2, y: box.maxY - h, width: w, height: h)
        }
        thumb.frame = rect.integral
        selectionBox.frame = rect.insetBy(dx: -6, dy: -6).integral
        let textWidth = min(label.attributedStringValue.size().width + 14, bounds.width - 12)
        label.frame = NSRect(x: (bounds.width - textWidth) / 2, y: box.maxY + 8, width: textWidth, height: labelHeight).integral
    }

    func configure(url: URL) {
        self.url = url
        label.stringValue = url.lastPathComponent
        needsLayout = true
        if let cached = ImageLoader.thumbCache.object(forKey: url as NSURL) {
            thumb.image = cached
            return
        }
        thumb.image = nil
        ImageLoader.thumbQueue.addOperation { [weak self] in
            guard let cg = ImageLoader.sidebarThumbnail(url) else { return }
            let image = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
            ImageLoader.thumbCache.setObject(image, forKey: url as NSURL)
            DispatchQueue.main.async {
                guard let self, self.url == url else { return }
                self.thumb.image = image
                self.needsLayout = true
            }
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateSelection()
    }

    private func updateSelection() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            selectionBox.layer?.backgroundColor = isSelected
                ? NSColor.unemphasizedSelectedContentBackgroundColor.cgColor : NSColor.clear.cgColor
            if isSelected && isEmphasized {
                label.layer?.backgroundColor = NSColor.selectedContentBackgroundColor.cgColor
                label.textColor = .alternateSelectedControlTextColor
            } else if isSelected {
                label.layer?.backgroundColor = NSColor.unemphasizedSelectedContentBackgroundColor.cgColor
                label.textColor = .labelColor
            } else {
                label.layer?.backgroundColor = NSColor.clear.cgColor
                label.textColor = .labelColor
            }
        }
    }
}

/// Row view that leaves selection drawing to the cell.
final class SidebarRowView: NSTableRowView {
    override func drawSelection(in dirtyRect: NSRect) {}
    override var isSelected: Bool { didSet { syncCell() } }
    override var isEmphasized: Bool { didSet { syncCell() } }
    override func didAddSubview(_ subview: NSView) {
        super.didAddSubview(subview)
        syncCell()
    }
    private func syncCell() {
        for case let cell as ThumbnailCell in subviews {
            cell.isSelected = isSelected
            cell.isEmphasized = isEmphasized
        }
    }
}

final class SidebarViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    private(set) var urls: [URL]
    let table = FullWidthTableView()
    /// Called with the image the user wants to see.
    var onSelect: ((Int) -> Void)?
    /// Called after any selection change (for the "n selected" subtitle).
    var onSelectionChange: (() -> Void)?
    /// The image the main view shows; kept in sync by the window controller.
    private(set) var shownIndex = 0
    private var selectingProgrammatically = false
    private var lastSelection = IndexSet()

    init(urls: [URL]) {
        self.urls = urls
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 190, height: 600))
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("thumb"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        table.headerView = nil
        table.style = .plain
        table.rowHeight = 150
        table.intercellSpacing = NSSize(width: 0, height: 2)
        table.allowsMultipleSelection = true
        table.allowsEmptySelection = false
        table.backgroundColor = .clear
        table.dataSource = self
        table.delegate = self
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.drawsBackground = false
        scroll.contentView.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(clipResized),
                                               name: NSView.frameDidChangeNotification, object: scroll.contentView)
        view = scroll
    }

    @objc private func clipResized() { table.fitColumn() }

    override func viewDidLayout() {
        super.viewDidLayout()
        table.fitColumn()
    }

    func numberOfRows(in tableView: NSTableView) -> Int { urls.count }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { SidebarRowView() }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = tableView.makeView(withIdentifier: ThumbnailCell.identifier, owner: nil) as? ThumbnailCell
            ?? ThumbnailCell(frame: .zero)
        cell.configure(url: urls[row])
        cell.isSelected = tableView.isRowSelected(row)
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        let selection = table.selectedRowIndexes
        defer {
            lastSelection = selection
            refreshSelectionAppearance()
            onSelectionChange?()
        }
        guard !selectingProgrammatically, !selection.isEmpty else { return }
        let added = selection.subtracting(lastSelection)
        var primary: Int?
        let selectedAll = selection.count == urls.count && selection.contains(shownIndex)
        if let clicked = clickedRow(), selection.contains(clicked) {
            primary = clicked
        } else if added.count == 1, !selectedAll {
            primary = added.first
        } else if !selection.contains(shownIndex) {
            primary = selection.first
        }
        if let primary, primary != shownIndex { onSelect?(primary) }
    }

    /// Row under the mouse when the change came from a click (shift-click ranges included).
    private func clickedRow() -> Int? {
        guard let event = NSApp.currentEvent, event.window === table.window,
              event.type == .leftMouseDown || event.type == .leftMouseUp else { return nil }
        let row = table.row(at: table.convert(event.locationInWindow, from: nil))
        return row >= 0 ? row : nil
    }

    var selectedIndexes: IndexSet { table.selectedRowIndexes }

    /// Push selection and focus state into the visible cells.
    func refreshSelectionAppearance() {
        let emphasized = table.window?.isKeyWindow == true
        table.enumerateAvailableRowViews { rowView, row in
            guard let cell = rowView.view(atColumn: 0) as? ThumbnailCell else { return }
            cell.isSelected = self.table.isRowSelected(row)
            cell.isEmphasized = emphasized
        }
    }

    /// Mark `index` as shown. A multiple selection that already includes it is kept.
    func show(_ index: Int) {
        guard urls.indices.contains(index) else { return }
        shownIndex = index
        if !table.selectedRowIndexes.contains(index) { selectOnly(index) }
        table.scrollRowToVisible(index)
    }

    func selectOnly(_ index: Int) {
        guard urls.indices.contains(index) else { return }
        shownIndex = index
        selectingProgrammatically = true
        table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        selectingProgrammatically = false
        lastSelection = table.selectedRowIndexes
        refreshSelectionAppearance()
    }

    func selectAllImages() {
        table.selectAll(nil)
    }

    /// Drop rows for files that no longer exist.
    func remove(_ indexes: IndexSet) {
        for i in indexes.reversed() { urls.remove(at: i) }
        selectingProgrammatically = true
        table.removeRows(at: indexes, withAnimation: .effectFade)
        selectingProgrammatically = false
        lastSelection = table.selectedRowIndexes
        refreshSelectionAppearance()
    }
}
