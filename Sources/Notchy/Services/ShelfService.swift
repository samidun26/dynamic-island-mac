import AppKit
import NotchyCore
import Observation
import UniformTypeIdentifiers

/// Files dropped on the notch, kept until removed (also across relaunches, as bookmarks that
/// follow a file when it moves). Notchy only remembers where the files are; it never copies them.
@MainActor @Observable
final class ShelfModel {
    struct File: Identifiable, Equatable {
        let id = UUID()
        let url: URL
        var name: String { url.lastPathComponent }
    }

    private(set) var files: [File] = []
    @ObservationIgnored private let persists: Bool
    private static let key = "shelfFiles"
    static let limit = 40

    /// Where screenshots and images dropped on the island are kept (macOS deletes a screenshot's
    /// temporary file once it's been dragged somewhere). Files dropped from elsewhere stay put.
    let storage: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent(AppInfo.name, isDirectory: true)
        .appendingPathComponent("Shelf", isDirectory: true)

    func isStored(_ url: URL) -> Bool {
        url.standardizedFileURL.path.hasPrefix(storage.standardizedFileURL.path + "/")
    }

    /// Deletes a copy kept in `storage` once nothing refers to it any more.
    func discardIfStored(_ url: URL) {
        guard isStored(url), !files.contains(where: { $0.url.standardizedFileURL == url.standardizedFileURL }) else { return }
        try? FileManager.default.removeItem(at: url)
    }

    init(persists: Bool) {
        self.persists = persists
        guard persists, let saved = UserDefaults.standard.array(forKey: Self.key) as? [Data] else { return }
        files = saved.compactMap { data in
            var stale = false
            guard let url = try? URL(resolvingBookmarkData: data, options: [.withoutUI], bookmarkDataIsStale: &stale),
                  FileManager.default.fileExists(atPath: url.path) else { return nil }
            return File(url: url)
        }
    }

    func add(_ urls: [URL]) {
        let new = urls.filter { url in url.isFileURL && !files.contains { $0.url.standardizedFileURL == url.standardizedFileURL } }
        guard !new.isEmpty else { return }
        files.insert(contentsOf: new.map { File(url: $0) }, at: 0)
        if files.count > Self.limit { files.removeLast(files.count - Self.limit) }
        QALog.log("SHELF added \(new.count) total=\(files.count)")
        save()
    }

    func remove(_ id: UUID) {
        let gone = files.filter { $0.id == id }.map(\.url)
        files.removeAll { $0.id == id }
        gone.forEach(discardIfStored)
        save()
    }

    func clear() {
        let gone = files.map(\.url)
        files.removeAll()
        gone.forEach(discardIfStored)
        save()
    }

    func open(_ file: File) { NSWorkspace.shared.open(file.url) }
    func reveal(_ file: File) { NSWorkspace.shared.activateFileViewerSelecting([file.url]) }

    private func save() {
        guard persists else { return }
        UserDefaults.standard.set(files.compactMap { try? $0.url.bookmarkData() }, forKey: Self.key)
    }

    // Demo
    func showDemo(_ urls: [URL]) { files = urls.map { File(url: $0) } }
}

/// Recent clipboard text. The pasteboard has no change notification, so its change counter is
/// read twice a second (a cheap call) while history is on. Copies marked as passwords or
/// otherwise not-to-be-recorded (the nspasteboard.org markers that password managers set) are
/// skipped. History lives in memory only; just the items you pin are saved.
@MainActor @Observable
final class ClipboardModel {
    private(set) var history = ClipHistory()
    private(set) var isOn = false

    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var lastChange = NSPasteboard.general.changeCount
    @ObservationIgnored private var ownChange: Int?
    @ObservationIgnored private let persists: Bool
    private static let pinsKey = "clipboardPins"

    init(persists: Bool) {
        self.persists = persists
        if persists, let pins = UserDefaults.standard.stringArray(forKey: Self.pinsKey) {
            history = ClipHistory(items: pins.map { ClipHistory.Item(text: $0, pinned: true) })
        }
    }

    func start() {
        guard timer == nil else { return }
        isOn = true
        lastChange = NSPasteboard.general.changeCount   // what was there before isn't history
        let t = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        t.tolerance = 0.2
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    /// Stops recording and forgets everything that isn't pinned.
    func stop() {
        timer?.invalidate()
        timer = nil
        isOn = false
        history.clear()
    }

    func poll() {
        let pb = NSPasteboard.general
        let change = pb.changeCount
        guard change != lastChange else { return }
        lastChange = change
        guard change != ownChange else { return }
        let types = pb.types?.map(\.rawValue) ?? []
        guard ClipboardPolicy.shouldRecord(types: types) else {
            QALog.log("CLIP skipped (marked private)")
            return
        }
        guard let text = pb.string(forType: .string) else { return }
        history.add(text)
        QALog.log("CLIP added \(text.count) characters")
    }

    /// Copies dropped files: one image goes on as the picture itself (PNG and TIFF, as macOS's own
    /// screenshot-to-clipboard does), so it pastes into chats and documents; anything else goes on
    /// as files, as Finder's Copy does. Returns what was copied, for the confirmation.
    @discardableResult
    func copyFiles(_ urls: [URL]) -> String? {
        guard !urls.isEmpty else { return nil }
        let pb = NSPasteboard.general
        let copied: String
        if urls.count == 1, let url = urls.first,
           UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) == true,
           let image = NSImage(contentsOf: url), let tiff = image.tiffRepresentation {
            let item = NSPasteboardItem()
            if let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) { item.setData(png, forType: .png) }
            item.setData(tiff, forType: .tiff)
            pb.clearContents()
            pb.writeObjects([item])
            copied = "image"
        } else {
            pb.clearContents()
            pb.writeObjects(urls.map { $0 as NSURL })
            copied = urls.count == 1 ? "file" : "\(urls.count) files"
        }
        ownChange = pb.changeCount
        lastChange = pb.changeCount
        QALog.log("SHELF copied \(copied)")
        return copied
    }

    /// Puts an item back on the clipboard (and at the top of the history).
    func copy(_ item: ClipHistory.Item) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(item.text, forType: .string)
        ownChange = pb.changeCount
        lastChange = ownChange ?? lastChange
        history.add(item.text)
        QALog.log("CLIP copied back")
    }

    func togglePin(_ item: ClipHistory.Item) {
        history.togglePin(item.id)
        savePins()
    }

    func remove(_ item: ClipHistory.Item) {
        history.remove(item.id)
        savePins()
    }

    func clear() { history.clear() }

    private func savePins() {
        guard persists else { return }
        UserDefaults.standard.set(history.pinned.map(\.text), forKey: Self.pinsKey)
    }

    // Demo
    func showDemo(_ texts: [String], pinned: Set<String> = []) {
        var h = ClipHistory()
        for t in texts.reversed() { h.add(t) }
        for item in h.items where pinned.contains(item.text) { h.togglePin(item.id) }
        history = h
        isOn = true
    }
}
