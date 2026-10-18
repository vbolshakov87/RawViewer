import AppKit

/// Keeps the image centred when it is smaller than the visible area.
final class CenteringClipView: NSClipView {
    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var rect = super.constrainBoundsRect(proposedBounds)
        guard let doc = documentView else { return rect }
        if rect.width > doc.frame.width { rect.origin.x = (doc.frame.width - rect.width) / 2 }
        if rect.height > doc.frame.height { rect.origin.y = (doc.frame.height - rect.height) / 2 }
        return rect
    }
}

/// Draws a CGImage through its layer, so the GPU does all scaling.
/// One view point equals one image pixel; "Actual Size" compensates for Retina.
final class ImageCanvasView: NSView {
    var image: CGImage? { didSet { layer?.contents = image } }
    var onKeyDown: ((NSEvent) -> Bool)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        layer?.contentsGravity = .resize
        layer?.minificationFilter = .trilinear
        layer?.magnificationFilter = .linear
    }
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() { layer?.contents = image }
    override func mouseDown(with event: NSEvent) { window?.makeFirstResponder(self) }
    override func keyDown(with event: NSEvent) {
        if onKeyDown?(event) != true { super.keyDown(with: event) }
    }
}

/// Root of the image area. Paints an opaque background all the way up under
/// the toolbar (otherwise the glass titlebar shows whatever is behind the
/// window) and accepts dropped files and folders.
final class DropView: NSView {
    var onDrop: (([URL]) -> Void)?
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        registerForDraggedTypes([.fileURL])
    }
    required init?(coder: NSCoder) { fatalError() }
    override var wantsUpdateLayer: Bool { true }
    override var isOpaque: Bool { true }
    override func updateLayer() {
        layer?.backgroundColor = NSColor.underPageBackgroundColor.cgColor
    }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { .copy }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        guard !urls.isEmpty else { return false }
        onDrop?(urls)
        return true
    }
}

final class ImageViewController: NSViewController {
    let scrollView = NSScrollView()
    let canvas = ImageCanvasView(frame: .zero)
    private let spinner = NSProgressIndicator()
    private let badge = NSTextField(labelWithString: "")

    private(set) var currentURL: URL?
    private(set) var info: ImageInfo?
    /// Unrotated image currently shown, and whether it came from the camera JPEG.
    private(set) var current: Decoded?
    private var loadToken = 0
    private var upgradeInFlight = 0
    private var quarterTurns: [URL: Int] = [:]
    private var fitMode = true

    /// When on, every RAW is developed instead of showing the embedded JPEG.
    var developRAW = false {
        didSet { if developRAW { requestResolution(max(screenLongSide, zoomNeed)) } }
    }

    var onNavigate: ((Int) -> Void)?
    var onDrop: (([URL]) -> Void)?
    var onStatusChange: (() -> Void)?

    override func loadView() {
        let root = DropView(frame: NSRect(x: 0, y: 0, width: 900, height: 640))
        root.onDrop = { [weak self] in self?.onDrop?($0) }

        scrollView.contentView = CenteringClipView()
        scrollView.documentView = canvas
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.allowsMagnification = true
        scrollView.minMagnification = 0.01
        scrollView.maxMagnification = 32
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .underPageBackgroundColor
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.postsFrameChangedNotifications = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(scrollView)

        spinner.style = .spinning
        spinner.controlSize = .regular
        spinner.isDisplayedWhenStopped = false
        spinner.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(spinner)

        badge.font = .systemFont(ofSize: 11, weight: .medium)
        badge.textColor = .white
        badge.drawsBackground = false
        badge.wantsLayer = true
        badge.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.55).cgColor
        badge.layer?.cornerRadius = 6
        badge.alignment = .center
        badge.isHidden = true
        badge.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(badge)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: root.safeAreaLayoutGuide.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            spinner.centerXAnchor.constraint(equalTo: scrollView.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor),
            badge.centerXAnchor.constraint(equalTo: scrollView.centerXAnchor),
            badge.bottomAnchor.constraint(equalTo: scrollView.bottomAnchor, constant: -14),
            badge.widthAnchor.constraint(greaterThanOrEqualToConstant: 120),
            badge.heightAnchor.constraint(equalToConstant: 22),
        ])

        canvas.onKeyDown = { [weak self] event in self?.handleKey(event) ?? false }

        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(liveMagnifyEnded), name: NSScrollView.didEndLiveMagnifyNotification, object: scrollView)
        nc.addObserver(self, selector: #selector(frameChanged), name: NSView.frameDidChangeNotification, object: scrollView)
        view = root
    }

    // MARK: Loading

    func display(url: URL) {
        guard url != currentURL else { return }
        currentURL = url
        loadToken += 1
        upgradeInFlight = 0
        let token = loadToken
        let started = DispatchTime.now().uptimeNanoseconds
        fitMode = true
        setBadge(nil)

        // Cached (prefetched) images and their sizes show synchronously: no flash.
        if let cached = ImageLoader.previewCache.object(forKey: url as NSURL),
           let info = ImageLoader.infoCache.object(forKey: url as NSURL)?.info {
            apply(info: info, decoded: cached)
            SelfTest.log("show \(url.lastPathComponent): from prefetch cache \(cached.image.width)x\(cached.image.height)")
            return
        }

        canvas.image = nil
        current = nil
        spinner.startAnimation(nil)
        ImageLoader.decodeQueue.async { [weak self] in
            let info = ImageLoader.info(url)
            let decoded = ImageLoader.preview(url)
            DispatchQueue.main.async {
                guard let self, token == self.loadToken else { return }
                self.spinner.stopAnimation(nil)
                guard let info, let decoded else {
                    self.info = nil
                    self.current = nil
                    self.setBadge("Can't open this file")
                    self.onStatusChange?()
                    return
                }
                self.apply(info: info, decoded: decoded)
                SelfTest.log(String(format: "show %@: decoded %dx%d in %.1f ms", url.lastPathComponent, decoded.image.width, decoded.image.height, Double(DispatchTime.now().uptimeNanoseconds - started) / 1e6))
            }
        }
    }

    private func apply(info: ImageInfo, decoded: Decoded) {
        self.info = info
        current = decoded
        layoutCanvas()
        onStatusChange?()
        // Embedded JPEG much smaller than the screen (e.g. some drones): develop at screen size.
        let need = min(screenLongSide, info.longSide)
        if decoded.longSide * 2 < need || (developRAW && decoded.isEmbeddedPreview) {
            requestResolution(developRAW ? max(screenLongSide, zoomNeed) : need)
        }
    }

    /// Decode at least `wanted` pixels on the long side, in the background.
    private func requestResolution(_ wanted: Int) {
        guard let url = currentURL, let info, let current else { return }
        let target = min(max(wanted, 1), info.longSide, ImageLoader.maxTextureSide)
        let replacingEmbedded = developRAW && current.isEmbeddedPreview && ImageLoader.isRAW(url)
        guard replacingEmbedded || target > Int(Double(current.longSide) * 1.05) else { return }
        guard target > upgradeInFlight else { return }
        upgradeInFlight = target
        let token = loadToken
        setBadge(ImageLoader.isRAW(url) ? "Developing RAW…" : "Decoding full size…")
        let started = DispatchTime.now().uptimeNanoseconds
        ImageLoader.decodeQueue.async { [weak self] in
            let image = ImageLoader.decode(url, longSide: target)
            SelfTest.log(String(format: "upgrade %@ to %d px: %dx%d in %.1f ms", url.lastPathComponent, target, image?.width ?? 0, image?.height ?? 0, Double(DispatchTime.now().uptimeNanoseconds - started) / 1e6))
            DispatchQueue.main.async {
                guard let self, token == self.loadToken else { return }
                self.upgradeInFlight = 0
                self.setBadge(nil)
                guard let image else { return }
                let full = max(image.width, image.height) >= info.longSide
                let decoded = Decoded(image: image, isReduced: !full, isEmbeddedPreview: false)
                ImageLoader.remember(decoded, for: url)
                self.current = decoded
                self.refreshCanvasImage()
                self.onStatusChange?()
            }
        }
    }

    // MARK: Layout

    private var turns: Int { currentURL.map { quarterTurns[$0] ?? 0 } ?? 0 }

    private var displaySize: CGSize {
        guard let info else { return .zero }
        return turns % 2 == 0 ? info.pixelSize : CGSize(width: info.pixelSize.height, height: info.pixelSize.width)
    }

    private func layoutCanvas() {
        canvas.frame = NSRect(origin: .zero, size: displaySize)
        refreshCanvasImage()
        if fitMode { fit(allowUpscale: false) }
    }

    private func refreshCanvasImage() {
        guard let current else { canvas.image = nil; return }
        canvas.image = ImageLoader.rotate(current.image, quarterTurns: turns)
    }

    private var backingScale: CGFloat { view.window?.backingScaleFactor ?? 2 }

    /// Pixels on the long side that the current zoom level can actually show.
    private var zoomNeed: Int {
        guard let info else { return 0 }
        let ratio = min(1, scrollView.magnification * backingScale)
        return Int((Double(info.longSide) * ratio).rounded(.up))
    }
    private var screenLongSide: Int { ImageLoader.previewMaxPixel }

    private func fit(allowUpscale: Bool) {
        let clip = scrollView.contentView.frame.size
        let doc = canvas.frame.size
        guard doc.width > 0, doc.height > 0, clip.width > 0, clip.height > 0 else { return }
        var m = min(clip.width / doc.width, clip.height / doc.height)
        if !allowUpscale { m = min(m, 1 / backingScale) }
        scrollView.magnification = m
        scrollView.contentView.scroll(to: scrollView.contentView.constrainBoundsRect(scrollView.contentView.bounds).origin)
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    @objc private func frameChanged() {
        if fitMode { fit(allowUpscale: false) }
    }

    @objc private func liveMagnifyEnded() {
        fitMode = false
        zoomChanged()
    }

    /// After any zoom: if the screen now needs more pixels than we hold, decode more.
    private func zoomChanged() {
        guard let current, let info else { return }
        let devicePixelsPerImagePixel = scrollView.magnification * backingScale
        let held = Double(current.longSide) / Double(max(info.longSide, 1))
        if devicePixelsPerImagePixel > held * 1.05 {
            requestResolution(info.longSide)
        }
        onStatusChange?()
    }

    // MARK: Commands

    func zoomIn() { zoom(by: 1.5) }
    func zoomOut() { zoom(by: 1 / 1.5) }

    private func zoom(by factor: CGFloat) {
        fitMode = false
        let clip = scrollView.contentView.bounds
        scrollView.setMagnification(scrollView.magnification * factor, centeredAt: NSPoint(x: clip.midX, y: clip.midY))
        zoomChanged()
    }

    func zoomToActualSize() {
        fitMode = false
        let clip = scrollView.contentView.bounds
        scrollView.setMagnification(1 / backingScale, centeredAt: NSPoint(x: clip.midX, y: clip.midY))
        zoomChanged()
    }

    func zoomToFit() {
        fitMode = true
        fit(allowUpscale: true)
        onStatusChange?()
    }

    func rotate(by delta: Int) {
        guard let url = currentURL, current != nil else { return }
        quarterTurns[url] = ((quarterTurns[url] ?? 0) + delta) % 4
        canvas.frame = NSRect(origin: .zero, size: displaySize)
        refreshCanvasImage()
        fit(allowUpscale: false)
        fitMode = true
    }

    var displayedImage: CGImage? { canvas.image }
    var zoomPercent: Int { Int((scrollView.magnification * backingScale * 100).rounded()) }

    private func handleKey(_ event: NSEvent) -> Bool {
        if let action = FileDeletion.action(for: event) {
            return canvas.tryToPerform(action, with: canvas)
        }
        guard let key = event.charactersIgnoringModifiers?.unicodeScalars.first?.value else { return false }
        switch Int(key) {
        case NSLeftArrowFunctionKey, NSUpArrowFunctionKey: onNavigate?(-1); return true
        case NSRightArrowFunctionKey, NSDownArrowFunctionKey, 0x20: onNavigate?(1); return true
        default: return false
        }
    }

    private func setBadge(_ text: String?) {
        badge.stringValue = text.map { "  \($0)  " } ?? ""
        badge.isHidden = text == nil
    }
}
