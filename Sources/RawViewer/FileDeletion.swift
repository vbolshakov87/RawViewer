import AppKit

/// Moves image files (and their .xmp sidecars) to the Trash or deletes them.
enum FileDeletion {
    struct Result {
        var removed: [URL] = []
        var failed: [(url: URL, error: Error)] = []
    }

    /// Lightroom/Camera Raw sidecars: `DSC_0001.xmp`; darktable: `DSC_0001.NEF.xmp`.
    static func sidecars(for url: URL) -> [URL] {
        let dir = url.deletingLastPathComponent()
        let base = url.deletingPathExtension().lastPathComponent
        var seen = Set<String>()
        return ["\(base).xmp", "\(base).XMP", "\(url.lastPathComponent).xmp"]
            .map { dir.appendingPathComponent($0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) && seen.insert($0.path.lowercased()).inserted }
    }

    /// The delete command a Delete-key event asks for, if any.
    static func action(for event: NSEvent) -> Selector? {
        guard let key = event.charactersIgnoringModifiers?.unicodeScalars.first.map({ Int($0.value) }),
              key == NSDeleteCharacter || key == NSBackspaceCharacter else { return nil }
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.function, .numericPad, .capsLock])
        switch mods {
        case [], [.command]: return #selector(BrowserWindowController.moveToTrash(_:))
        case [.command, .option]: return #selector(BrowserWindowController.deleteImmediately(_:))
        default: return nil
        }
    }

    static func delete(_ urls: [URL], permanently: Bool) -> Result {
        let fm = FileManager.default
        var result = Result()
        for url in urls {
            do {
                if permanently {
                    try fm.removeItem(at: url)
                } else {
                    try fm.trashItem(at: url, resultingItemURL: nil)
                }
                result.removed.append(url)
                for sidecar in sidecars(for: url) {
                    if permanently { try? fm.removeItem(at: sidecar) } else { try? fm.trashItem(at: sidecar, resultingItemURL: nil) }
                }
            } catch {
                result.failed.append((url, error))
            }
        }
        return result
    }
}
