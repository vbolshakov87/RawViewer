import Foundation
import ImageIO

/// Command-line timing of each decode stage: `RawViewer --bench file...`
enum Bench {
    static func ms(_ start: UInt64) -> String {
        String(format: "%7.1f ms", Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6)
    }

    static func run(_ paths: [String]) {
        for path in paths {
            let url = URL(fileURLWithPath: path)
            let bytes = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int) ?? 0
            print("== \(url.lastPathComponent)  \(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file))  raw=\(ImageLoader.isRAW(url))")
            for pass in 1...2 {
                ImageLoader.previewCache.removeAllObjects()
                ImageLoader.infoCache.removeAllObjects()
                print("  pass \(pass)")
                var t = DispatchTime.now().uptimeNanoseconds
                let info = ImageLoader.info(url)
                print("    properties        \(ms(t))  \(Int(info?.pixelSize.width ?? 0))x\(Int(info?.pixelSize.height ?? 0))")
                t = DispatchTime.now().uptimeNanoseconds
                let th = ImageLoader.sidebarThumbnail(url)
                print("    sidebar thumbnail \(ms(t))  \(th?.width ?? 0)x\(th?.height ?? 0)")
                t = DispatchTime.now().uptimeNanoseconds
                let p = ImageLoader.preview(url)
                print("    screen preview    \(ms(t))  \(p?.image.width ?? 0)x\(p?.image.height ?? 0)")
                let full = info?.longSide ?? 0
                if ImageLoader.isRAW(url) {
                    t = DispatchTime.now().uptimeNanoseconds
                    let half = ImageLoader.developRAW(url, longSide: full / 2, fullLongSide: full)
                    _ = half?.dataProvider?.data.map { CFDataGetLength($0) }
                    print("    CIRAWFilter 1/2   \(ms(t))  \(half?.width ?? 0)x\(half?.height ?? 0)")
                    t = DispatchTime.now().uptimeNanoseconds
                    let ci = ImageLoader.developRAW(url, longSide: full, fullLongSide: full)
                    _ = ci?.dataProvider?.data.map { CFDataGetLength($0) }
                    print("    CIRAWFilter full  \(ms(t))  \(ci?.width ?? 0)x\(ci?.height ?? 0)")
                }
                if let src = ImageLoader.source(url) {
                    t = DispatchTime.now().uptimeNanoseconds
                    let opts: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                                 kCGImageSourceCreateThumbnailWithTransform: true,
                                                 kCGImageSourceThumbnailMaxPixelSize: full,
                                                 kCGImageSourceShouldCacheImmediately: true]
                    let img = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
                    print("    ImageIO full      \(ms(t))  \(img?.width ?? 0)x\(img?.height ?? 0)")
                }
            }
        }
    }
}
