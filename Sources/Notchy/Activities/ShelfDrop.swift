import AppKit
import QuickLookThumbnailing
import UniformTypeIdentifiers

/// What can be dropped on the island: files from Finder, the screenshot thumbnail macOS shows
/// after ⌘⇧3/4/5 (a promised file, often with the image itself), or an image dragged out of an
/// app (just the image data).
@MainActor
enum ShelfDrop {
    /// Drag pasteboard types that open the island on the shelf.
    static let dragTypes: Set<NSPasteboard.PasteboardType> = [
        .fileURL, .png, .tiff,
        NSPasteboard.PasteboardType("public.jpeg"), NSPasteboard.PasteboardType("public.heic"),
        NSPasteboard.PasteboardType("com.apple.NSFilePromiseItemMetaData"),
        NSPasteboard.PasteboardType("com.apple.pasteboard.promised-file-url"),
        NSPasteboard.PasteboardType("com.apple.pasteboard.promised-file-content-type"),
        NSPasteboard.PasteboardType("NSPromiseContentsPboardType"),
    ]
    static let utTypes: [UTType] = [.fileURL, .image]

    static func accepts(_ types: [NSPasteboard.PasteboardType]) -> Bool {
        types.contains(where: dragTypes.contains)
    }

    /// Turns dropped items into files. A dropped file stays where it is, unless it sits in a
    /// temporary folder that macOS empties (a screenshot's does): then it is copied into `storage`.
    /// Images and promised files are written into `storage`.
    static func files(from providers: [NSItemProvider], storage: URL) async -> [URL] {
        var urls: [URL] = []
        for p in providers {
            if let url = await file(from: p, storage: storage) { urls.append(url) }
        }
        return urls
    }

    private static func file(from p: NSItemProvider, storage: URL) async -> URL? {
        if p.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            let url: URL? = await withCheckedContinuation { c in
                _ = p.loadObject(ofClass: URL.self) { url, _ in c.resume(returning: url) }
            }
            if let url, url.isFileURL {
                return isTemporary(url) ? Self.copy(url, into: storage) : url
            }
        }
        guard let type = p.registeredTypeIdentifiers.first(where: { UTType($0)?.conforms(to: .image) == true }) else { return nil }
        // The screenshot thumbnail suggests "Screenshot <date> at <time>"; plain image data has no name.
        let ext = UTType(type)?.preferredFilenameExtension ?? "png"
        let base = p.suggestedName.flatMap { $0.isEmpty ? nil : ($0 as NSString).deletingPathExtension } ?? "Image \(stamp())"
        let name = "\(base).\(ext)"
        // A promised file or image data: macOS hands over a temporary file that's gone after the
        // callback, so it's copied in there.
        let copied: URL? = await withCheckedContinuation { c in
            _ = p.loadFileRepresentation(forTypeIdentifier: type) { temp, _ in
                c.resume(returning: temp.flatMap { Self.copy($0, into: storage, named: name) })
            }
        }
        if let copied { return copied }
        let data: Data? = await withCheckedContinuation { c in
            _ = p.loadDataRepresentation(forTypeIdentifier: type) { data, _ in c.resume(returning: data) }
        }
        guard let data else { return nil }
        return write(data, named: name, into: storage)
    }

    nonisolated static func isTemporary(_ url: URL) -> Bool {
        let path = url.resolvingSymlinksInPath().path
        return path.hasPrefix("/private/var/folders/") || path.hasPrefix("/var/folders/") || path.contains("/TemporaryItems/")
    }

    nonisolated static func copy(_ url: URL, into dir: URL, named name: String? = nil) -> URL? {
        let fm = FileManager.default
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let dest = unique(name ?? url.lastPathComponent, in: dir)
        return (try? fm.copyItem(at: url, to: dest)) != nil ? dest : nil
    }

    nonisolated static func write(_ data: Data, named name: String, into dir: URL) -> URL? {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dest = unique(name, in: dir)
        return (try? data.write(to: dest)) != nil ? dest : nil
    }

    nonisolated private static func unique(_ name: String, in dir: URL) -> URL {
        let base = (name as NSString).deletingPathExtension, ext = (name as NSString).pathExtension
        var candidate = dir.appendingPathComponent(name)
        var n = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = dir.appendingPathComponent(ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)")
            n += 1
        }
        return candidate
    }

    nonisolated private static func stamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return f.string(from: Date())
    }
}

/// Quick Look previews for shelf tiles (screenshots, photos, PDFs and documents show their
/// content; anything else keeps its Finder icon).
@MainActor
enum Thumbnails {
    /// A finished image, handed from Quick Look's queue to the view.
    private struct Rendered: @unchecked Sendable { let image: CGImage? }

    static func make(for url: URL, side: CGFloat) async -> CGImage? {
        let request = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: side, height: side), scale: 2,
                                                   representationTypes: .thumbnail)
        let done: Rendered = await withCheckedContinuation { c in
            QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { rep, _ in
                c.resume(returning: Rendered(image: rep?.cgImage))
            }
        }
        return done.image
    }
}
