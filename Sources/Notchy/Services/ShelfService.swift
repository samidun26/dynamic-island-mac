import AppKit
import NotchyCore
import Observation

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
        files.removeAll { $0.id == id }
        save()
    }

    func clear() {
        files.removeAll()
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
