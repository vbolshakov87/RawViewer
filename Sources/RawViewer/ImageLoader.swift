import AppKit
import CoreImage
import ImageIO
import UniformTypeIdentifiers

/// A decoded image plus whether it is smaller than the file's full resolution.
final class Decoded {
    let image: CGImage
    let isReduced: Bool
    /// True when this is the JPEG the camera embedded, not a develop of the RAW data.
    let isEmbeddedPreview: Bool
    init(image: CGImage, isReduced: Bool, isEmbeddedPreview: Bool) {
        self.image = image
        self.isReduced = isReduced
        self.isEmbeddedPreview = isEmbeddedPreview
    }
    var cost: Int { image.bytesPerRow * image.height }
    var longSide: Int { max(image.width, image.height) }
}

struct ImageInfo {
    /// Pixel size after applying the EXIF orientation.
    let pixelSize: CGSize
    let properties: [String: Any]
    var longSide: Int { Int(max(pixelSize.width, pixelSize.height)) }
}

/// Decoding strategy, built on ImageIO's CGImageSource for every format and
/// Core Image's RAW filters for camera RAW.
///
/// 1. First paint: CGImageSourceCreateThumbnailAtIndex *without*
///    kCGImageSourceCreateThumbnailFromImageAlways. For camera RAW this returns
///    the JPEG the camera embedded in the file, so nothing is demosaiced.
///    It is requested at its native size: resampling a 24 MP JPEG down to
///    screen size costs more than decoding it as-is.
/// 2. Developed RAW: CIRAWFilter on the GPU, only when the embedded JPEG is too
///    small for the current zoom, or when the user turns on "Develop RAW".
enum ImageLoader {
    static var previewMaxPixel = 3456
    static let thumbMaxPixel = 256
    static let maxTextureSide = 16384

    static let decodeQueue = DispatchQueue(label: "rawviewer.decode", qos: .userInitiated, attributes: .concurrent)
    static let prefetchQueue: OperationQueue = {
        let q = OperationQueue()
        q.name = "rawviewer.prefetch"
        q.maxConcurrentOperationCount = 2
        q.qualityOfService = .utility
        return q
    }()
    static let thumbQueue: OperationQueue = {
        let q = OperationQueue()
        q.name = "rawviewer.thumbs"
        q.maxConcurrentOperationCount = max(2, ProcessInfo.processInfo.activeProcessorCount / 2)
        q.qualityOfService = .utility
        return q
    }()

    static let previewCache: NSCache<NSURL, Decoded> = {
        let c = NSCache<NSURL, Decoded>()
        c.countLimit = 24
        c.totalCostLimit = 1_200_000_000
        return c
    }()
    static let thumbCache: NSCache<NSURL, NSImage> = {
        let c = NSCache<NSURL, NSImage>()
        c.countLimit = 4000
        return c
    }()
    static let infoCache: NSCache<NSURL, InfoBox> = {
        let c = NSCache<NSURL, InfoBox>()
        c.countLimit = 4000
        return c
    }()
    final class InfoBox { let info: ImageInfo; init(_ i: ImageInfo) { info = i } }

    static let ciContext = CIContext(options: [
        .cacheIntermediates: false,
        .name: "RawViewer",
    ])
    static let displayP3 = CGColorSpace(name: CGColorSpace.displayP3)!

    // MARK: Types

    static func type(of url: URL) -> UTType? { UTType(filenameExtension: url.pathExtension) }
    static func isImage(_ url: URL) -> Bool { type(of: url)?.conforms(to: .image) ?? false }
    static func isRAW(_ url: URL) -> Bool { type(of: url)?.conforms(to: .rawImage) ?? false }

    /// Folders expand to the images they directly contain, sorted like Finder.
    static func expand(_ urls: [URL]) -> [URL] {
        var out: [URL] = []
        let fm = FileManager.default
        for url in urls {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { continue }
            if isDir.boolValue {
                let items = (try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
                out += items.filter(isImage).sorted {
                    $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending
                }
            } else if isImage(url) {
                out.append(url)
            }
        }
        return out
    }

    // MARK: Decoding

    static func source(_ url: URL) -> CGImageSource? {
        CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary)
    }

    static func info(_ url: URL) -> ImageInfo? {
        if let hit = infoCache.object(forKey: url as NSURL) { return hit.info }
        guard let src = source(url),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [String: Any]
        else { return nil }
        var w = props[kCGImagePropertyPixelWidth as String] as? Int ?? 0
        var h = props[kCGImagePropertyPixelHeight as String] as? Int ?? 0
        let orientation = props[kCGImagePropertyOrientation as String] as? Int ?? 1
        if orientation >= 5 { swap(&w, &h) }
        let info = ImageInfo(pixelSize: CGSize(width: w, height: h), properties: props)
        infoCache.setObject(InfoBox(info), forKey: url as NSURL)
        return info
    }

    static func thumbnail(_ src: CGImageSource, maxPixel: Int, fromFullImage: Bool) -> CGImage? {
        var opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        if fromFullImage {
            opts[kCGImageSourceCreateThumbnailFromImageAlways] = true
        } else {
            opts[kCGImageSourceCreateThumbnailFromImageIfAbsent] = true
        }
        return CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
    }

    /// Small image for the sidebar. Uses whatever thumbnail the file embeds.
    static func sidebarThumbnail(_ url: URL) -> CGImage? {
        guard let src = source(url) else { return nil }
        return thumbnail(src, maxPixel: thumbMaxPixel, fromFullImage: false)
    }

    /// Screen-sized image, as fast as possible. For RAW, the embedded preview.
    static func preview(_ url: URL) -> Decoded? {
        if let hit = previewCache.object(forKey: url as NSURL) { return hit }
        guard let src = source(url) else { return nil }
        let fullLong = info(url)?.longSide ?? 0
        let target = fullLong > 0 ? min(previewMaxPixel, fullLong) : previewMaxPixel

        var image: CGImage?
        var embedded = false
        if isRAW(url) {
            // Embedded JPEG at native size: no demosaic and no resample.
            // Some cameras embed only a small JPEG; the viewer then develops
            // the RAW at screen size in the background.
            image = thumbnail(src, maxPixel: fullLong > 0 ? min(fullLong, maxTextureSide) : target, fromFullImage: false)
            embedded = image != nil
        }
        if image == nil {
            image = thumbnail(src, maxPixel: target, fromFullImage: true)
        }
        guard let image else { return nil }
        let decoded = Decoded(image: image,
                              isReduced: fullLong > 0 && max(image.width, image.height) < fullLong,
                              isEmbeddedPreview: embedded)
        previewCache.setObject(decoded, forKey: url as NSURL, cost: decoded.cost)
        return decoded
    }

    /// Decode at (up to) `longSide` pixels on the long edge, from the real image data.
    static func decode(_ url: URL, longSide: Int) -> CGImage? {
        let fullLong = info(url)?.longSide ?? longSide
        let target = min(longSide, fullLong, maxTextureSide)
        if isRAW(url), let img = developRAW(url, longSide: target, fullLongSide: fullLong) {
            return img
        }
        guard let src = source(url) else { return nil }
        return thumbnail(src, maxPixel: target, fromFullImage: true)
    }

    /// Camera RAW develop on the GPU via Core Image.
    static func developRAW(_ url: URL, longSide: Int, fullLongSide: Int) -> CGImage? {
        guard let filter = CIRAWFilter(imageURL: url) else { return nil }
        if fullLongSide > 0, longSide < fullLongSide {
            filter.scaleFactor = Float(longSide) / Float(fullLongSide)
        }
        guard let output = filter.outputImage else { return nil }
        let extent = output.extent.integral
        return ciContext.createCGImage(output, from: extent, format: .RGBA8, colorSpace: displayP3)
    }

    /// Rotate by quarter turns; positive turns are counter-clockwise.
    static func rotate(_ img: CGImage, quarterTurns: Int) -> CGImage {
        let t = ((quarterTurns % 4) + 4) % 4
        if t == 0 { return img }
        let w = img.width, h = img.height
        let (nw, nh) = t % 2 == 1 ? (h, w) : (w, h)
        guard let ctx = CGContext(data: nil, width: nw, height: nh, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: displayP3,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return img }
        ctx.interpolationQuality = .none
        switch t {
        case 1: ctx.translateBy(x: CGFloat(nw), y: 0); ctx.rotate(by: .pi / 2)
        case 2: ctx.translateBy(x: CGFloat(nw), y: CGFloat(nh)); ctx.rotate(by: .pi)
        default: ctx.translateBy(x: 0, y: CGFloat(nh)); ctx.rotate(by: -.pi / 2)
        }
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage() ?? img
    }

    /// Drop everything cached for a file that was deleted.
    static func forget(_ url: URL) {
        previewCache.removeObject(forKey: url as NSURL)
        thumbCache.removeObject(forKey: url as NSURL)
        infoCache.removeObject(forKey: url as NSURL)
    }

    /// Loading the RAW camera support bundle costs several hundred ms the first
    /// time. Do it at launch, off the main thread.
    static func warmUp() {
        DispatchQueue.global(qos: .utility).async {
            _ = CIRAWFilter.supportedCameraModels.count
        }
    }

    /// Best image for filling the screen: the embedded JPEG when it is big
    /// enough, otherwise (or when `develop` is set) a RAW develop at screen size.
    static func screenImage(_ url: URL, develop: Bool) -> Decoded? {
        guard let p = preview(url) else { return nil }
        let full = info(url)?.longSide ?? p.longSide
        let need = min(previewMaxPixel, full)
        let tooSmall = p.longSide * 2 < need
        guard isRAW(url), p.isEmbeddedPreview, tooSmall || develop,
              let image = decode(url, longSide: need)
        else { return p }
        let d = Decoded(image: image, isReduced: max(image.width, image.height) < full, isEmbeddedPreview: false)
        remember(d, for: url)
        return d
    }

    /// Cache a screen-sized result so revisiting the image is instant.
    static func remember(_ d: Decoded, for url: URL) {
        guard d.longSide <= max(previewMaxPixel, (previewCache.object(forKey: url as NSURL)?.longSide ?? 0)) else { return }
        previewCache.setObject(d, forKey: url as NSURL, cost: d.cost)
    }

    /// Decode neighbours ahead of time so arrow-key browsing is instant.
    static func prefetch(_ urls: [URL], develop: Bool) {
        prefetchQueue.cancelAllOperations()
        for url in urls {
            if let hit = previewCache.object(forKey: url as NSURL), !(develop && hit.isEmbeddedPreview) { continue }
            prefetchQueue.addOperation { _ = screenImage(url, develop: develop) }
        }
    }
}
