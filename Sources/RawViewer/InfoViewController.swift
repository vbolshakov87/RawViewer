import AppKit
import ImageIO
import UniformTypeIdentifiers

/// Right-hand panel with file and EXIF information, docked in the window.
final class InfoViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    struct Row { let key: String; let value: String; let isHeader: Bool }

    private var rows: [Row] = []
    private let table = FullWidthTableView()
    private var url: URL?

    override func loadView() {
        let root = PaneBackgroundView(frame: NSRect(x: 0, y: 0, width: 300, height: 600))
        let scroll = NSScrollView(frame: root.bounds)
        scroll.autoresizingMask = [.width, .height]
        root.addSubview(scroll)
        let keyColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("key"))
        keyColumn.width = 112
        keyColumn.resizingMask = []
        let valueColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("value"))
        valueColumn.minWidth = 80
        valueColumn.resizingMask = .autoresizingMask
        table.addTableColumn(keyColumn)
        table.addTableColumn(valueColumn)
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.headerView = nil
        table.style = .plain
        table.selectionHighlightStyle = .none
        table.floatsGroupRows = false
        table.usesAutomaticRowHeights = true
        table.intercellSpacing = NSSize(width: 10, height: 3)
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
        view = root
    }

    @objc private func clipResized() { table.fitColumn() }

    override func viewDidLayout() {
        super.viewDidLayout()
        table.fitColumn()
    }

    func show(url: URL?) {
        guard url != self.url else { return }
        self.url = url
        guard let url else {
            rows = []
            table.reloadData()
            return
        }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let rows = Self.rows(for: url)
            DispatchQueue.main.async {
                guard let self, self.url == url else { return }
                self.rows = rows
                self.table.reloadData()
                self.table.scrollRowToVisible(0)
            }
        }
    }

    /// Forget the current file so the next `show` reloads (e.g. after deletion).
    func reset() { url = nil }

    // MARK: Content

    private static func rows(for url: URL) -> [Row] {
        var out: [Row] = []
        func header(_ title: String) { out.append(Row(key: title, value: "", isHeader: true)) }
        func add(_ key: String, _ value: String?) {
            if let value, !value.isEmpty { out.append(Row(key: key, value: value, isHeader: false)) }
        }

        let dates = DateFormatter()
        dates.dateStyle = .medium
        dates.timeStyle = .short
        let res = try? url.resolvingSymlinksInPath()
            .resourceValues(forKeys: [.fileSizeKey, .creationDateKey, .contentModificationDateKey])

        header("General")
        add("Name", url.lastPathComponent)
        add("Kind", ImageLoader.type(of: url)?.localizedDescription ?? url.pathExtension.uppercased())
        add("File Size", res?.fileSize.map { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file) })
        add("Created", res?.creationDate.map(dates.string))
        add("Modified", res?.contentModificationDate.map(dates.string))
        add("Folder", url.deletingLastPathComponent().path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
        guard let info = ImageLoader.info(url) else { return out }
        let p = info.properties
        let w = Int(info.pixelSize.width), h = Int(info.pixelSize.height)
        add("Dimensions", "\(w) × \(h)  (\(String(format: "%.1f", Double(w * h) / 1e6)) MP)")
        add("Color Model", p[kCGImagePropertyColorModel as String] as? String)
        add("Color Profile", p[kCGImagePropertyProfileName as String] as? String)
        add("Bit Depth", (p[kCGImagePropertyDepth as String] as? Int).map { "\($0) bit" })

        let exif = p[kCGImagePropertyExifDictionary as String] as? [String: Any] ?? [:]
        let tiff = p[kCGImagePropertyTIFFDictionary as String] as? [String: Any] ?? [:]
        let aux = p[kCGImagePropertyExifAuxDictionary as String] as? [String: Any] ?? [:]
        let gps = p[kCGImagePropertyGPSDictionary as String] as? [String: Any] ?? [:]

        header("Camera")
        add("Camera", cameraName(make: tiff[kCGImagePropertyTIFFMake as String] as? String,
                                 model: tiff[kCGImagePropertyTIFFModel as String] as? String))
        add("Lens", (exif[kCGImagePropertyExifLensModel as String] ?? aux[kCGImagePropertyExifAuxLensModel as String]) as? String)
        add("Shutter", (exif[kCGImagePropertyExifExposureTime as String] as? Double).map(shutter))
        add("Aperture", (exif[kCGImagePropertyExifFNumber as String] as? Double).map { String(format: "ƒ/%g", ($0 * 10).rounded() / 10) })
        add("ISO", (exif[kCGImagePropertyExifISOSpeedRatings as String] as? [Int])?.first.map(String.init))
        add("Focal Length", (exif[kCGImagePropertyExifFocalLength as String] as? Double).map { String(format: "%g mm", $0.rounded()) })
        add("35mm Equiv.", (exif[kCGImagePropertyExifFocalLenIn35mmFilm as String] as? Int).map { "\($0) mm" })
        add("Exposure Bias", (exif[kCGImagePropertyExifExposureBiasValue as String] as? Double).map { String(format: "%+.1f EV", $0) })
        add("Exposure Program", (exif[kCGImagePropertyExifExposureProgram as String] as? Int).map(exposureProgram))
        add("Metering", (exif[kCGImagePropertyExifMeteringMode as String] as? Int).map(metering))
        add("White Balance", (exif[kCGImagePropertyExifWhiteBalance as String] as? Int).map { $0 == 0 ? "Auto" : "Manual" })
        add("Flash", (exif[kCGImagePropertyExifFlash as String] as? Int).map { $0 & 1 == 1 ? "Fired" : "Did not fire" })
        add("Taken", (exif[kCGImagePropertyExifDateTimeOriginal as String] as? String).map { exifDate($0, dates) })
        add("Shutter Count", (aux[kCGImagePropertyExifAuxImageNumber as String] as? Int).map(String.init))
        add("Body Serial", (exif[kCGImagePropertyExifBodySerialNumber as String] ?? aux[kCGImagePropertyExifAuxSerialNumber as String]) as? String)
        add("Artist", tiff[kCGImagePropertyTIFFArtist as String] as? String)
        add("Software", tiff[kCGImagePropertyTIFFSoftware as String] as? String)
        if out.last?.isHeader == true { out.removeLast() }

        if let lat = gps[kCGImagePropertyGPSLatitude as String] as? Double,
           let lon = gps[kCGImagePropertyGPSLongitude as String] as? Double {
            header("Location")
            let ns = (gps[kCGImagePropertyGPSLatitudeRef as String] as? String) ?? "N"
            let ew = (gps[kCGImagePropertyGPSLongitudeRef as String] as? String) ?? "E"
            add("Coordinates", String(format: "%.5f° %@, %.5f° %@", lat, ns, lon, ew))
            add("Altitude", (gps[kCGImagePropertyGPSAltitude as String] as? Double).map { String(format: "%.0f m", $0) })
        }

        // Every metadata dictionary, as stored in the file.
        for (section, value) in p.sorted(by: { $0.key < $1.key }) {
            guard let dict = value as? [String: Any], !dict.isEmpty else { continue }
            header(section.trimmingCharacters(in: CharacterSet(charactersIn: "{}")))
            for (k, v) in dict.sorted(by: { $0.key < $1.key }) where !(v is [String: Any]) {
                add(k, format(k, v))
            }
        }
        return out
    }

    /// "NIKON CORPORATION" + "NIKON Z6_3" → "NIKON Z6_3".
    private static func cameraName(make: String?, model: String?) -> String? {
        let make = make?.trimmingCharacters(in: .whitespaces) ?? ""
        let model = model?.trimmingCharacters(in: .whitespaces) ?? ""
        if model.isEmpty { return make.isEmpty ? nil : make }
        let brand = make.split(separator: " ").first.map(String.init) ?? ""
        if brand.isEmpty || model.uppercased().hasPrefix(brand.uppercased()) { return model }
        return "\(make) \(model)"
    }

    private static func shutter(_ t: Double) -> String {
        if t >= 0.3 { return String(format: "%g s", (t * 10).rounded() / 10) }
        return "1/\(Int((1 / t).rounded())) s"
    }

    private static func exifDate(_ s: String, _ f: DateFormatter) -> String {
        let parser = DateFormatter()
        parser.locale = Locale(identifier: "en_US_POSIX")
        parser.dateFormat = "yyyy:MM:dd HH:mm:ss"
        return parser.date(from: s).map(f.string) ?? s
    }

    private static func exposureProgram(_ v: Int) -> String {
        ["Not defined", "Manual", "Program", "Aperture priority", "Shutter priority",
         "Creative", "Action", "Portrait", "Landscape"][safe: v] ?? "\(v)"
    }

    private static func metering(_ v: Int) -> String {
        [0: "Unknown", 1: "Average", 2: "Center-weighted", 3: "Spot", 4: "Multi-spot",
         5: "Matrix", 6: "Partial", 255: "Other"][v] ?? "\(v)"
    }

    private static func format(_ key: String, _ v: Any) -> String {
        if key == "ColorSpace", let n = v as? Int { return n == 1 ? "sRGB" : n == 65535 ? "Uncalibrated" : "\(n)" }
        switch v {
        case let a as [Any]:
            let parts = a.prefix(16).map { format("", $0) }
            return parts.joined(separator: ", ") + (a.count > 16 ? ", …" : "")
        case let d as Double where d != d.rounded(): return String(format: "%.4g", d)
        default: return "\(v)"
        }
    }

    // MARK: Table

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }
    func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool { rows[row].isHeader }
    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { false }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let r = rows[row]
        let cell = NSTableCellView()
        let field: NSTextField
        if r.isHeader {
            field = NSTextField(labelWithString: r.key)
            field.font = .systemFont(ofSize: 12, weight: .semibold)
        } else if tableColumn?.identifier.rawValue == "key" {
            field = NSTextField(labelWithString: r.key)
            field.font = .systemFont(ofSize: 11)
            field.textColor = .secondaryLabelColor
            field.alignment = .right
            field.lineBreakMode = .byTruncatingTail
        } else {
            field = NSTextField(wrappingLabelWithString: r.value)
            field.font = .systemFont(ofSize: 11)
            field.isSelectable = true
        }
        field.translatesAutoresizingMaskIntoConstraints = false
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        cell.addSubview(field)
        cell.textField = field
        let top: CGFloat = r.isHeader ? 12 : 1
        NSLayoutConstraint.activate([
            field.topAnchor.constraint(equalTo: cell.topAnchor, constant: top),
            field.bottomAnchor.constraint(equalTo: cell.bottomAnchor, constant: -1),
            field.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: r.isHeader ? 12 : 0),
            field.trailingAnchor.constraint(equalTo: cell.trailingAnchor),
        ])
        return cell
    }
}

/// Opaque pane background, also under the toolbar.
final class PaneBackgroundView: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
    }
    required init?(coder: NSCoder) { fatalError() }
    override var wantsUpdateLayer: Bool { true }
    override var isOpaque: Bool { true }
    override func updateLayer() { layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor }
}

private extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}
