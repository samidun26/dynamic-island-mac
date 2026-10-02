// qa-driver: scripted input and inspection for QA runs on a real macOS session.
// Coordinates are CoreGraphics global coordinates (origin top-left of the main display, points).
//
//   qa-driver info                         screen size, scale, mouse, Accessibility trust
//   qa-driver move X Y [ms]                glide the pointer to X,Y over ms (default 400) with real mouseMoved events
//   qa-driver jump X Y                     one instant mouseMoved
//   qa-driver click X Y                    move there, then press and release
//   qa-driver drag X1 Y1 X2 Y2 [ms]        press, drag, release
//   qa-driver swipe DX DY [X Y]            two-finger trackpad swipe (began / changed… / ended)
//   qa-driver key escape|return|cmd-w      press a key
//   qa-driver windows OWNER                on-screen windows of a process: id, layer, x, y, w, h, sharing
//   qa-driver ax-dump BUNDLE_ID            accessibility tree (role, label, value, frame)
//   qa-driver ax-find BUNDLE_ID LABEL [X Y W H]   centre "X Y" of the first element whose label/title/value
//                                          contains LABEL (falls back to hit-testing the given region)
//   qa-driver ax-frame BUNDLE_ID LABEL [X Y W H]  its frame "X Y W H"
//   qa-driver ax-at X Y                    the element under a point (what VoiceOver would hit)
//   qa-driver ax-press BUNDLE_ID LABEL     AXPress it
//   qa-driver ax-texts BUNDLE_ID [X Y W H] every static text value
//   qa-driver ax-menu BUNDLE_ID TITLE [press]  an item of the app's own menus: its shortcut ("key=W
//                                          modifiers=0" is ⌘W), and AXPress it with "press"
//   qa-driver pasteboard TEXT [TYPE…]      put TEXT on the clipboard, with extra (empty) marker types
//   qa-driver file-drag PATH X1 Y1 X2 Y2 [HOLD_MS]
//                                          drag PATH from a small window at X1,Y1 and drop it at X2,Y2,
//                                          as from Finder (a real drag session); prints the drop result
//   qa-driver pixel PNG X Y                "dark" or "light" and the RGB at a point (points)
//   qa-driver dark-run PNG Y               longest run of near-black pixels on row Y (points): "x width"
//   qa-driver dark-box PNG                 bounding box of the near-black blob touching the top centre: "x y w h"
import AppKit
import ApplicationServices
import CoreGraphics

setvbuf(stdout, nil, _IOLBF, 0)
let args = Array(CommandLine.arguments.dropFirst())
func arg(_ i: Int) -> String { i < args.count ? args[i] : "" }
func num(_ i: Int, _ d: Double = 0) -> Double { Double(arg(i)) ?? d }
func fail(_ msg: String) -> Never { FileHandle.standardError.write((msg + "\n").data(using: .utf8)!); exit(1) }

let source = CGEventSource(stateID: .hidSystemState)

func post(_ e: CGEvent?) { e?.post(tap: .cghidEventTap) }
func mouseLocation() -> CGPoint { CGEvent(source: nil)?.location ?? .zero }

func moveEvent(_ p: CGPoint, dragging: Bool = false) {
    post(CGEvent(mouseEventSource: source, mouseType: dragging ? .leftMouseDragged : .mouseMoved, mouseCursorPosition: p, mouseButton: .left))
}

func glide(to target: CGPoint, ms: Double, dragging: Bool = false) {
    let start = mouseLocation()
    let steps = max(1, Int(ms / 8))
    for i in 1...steps {
        let t = Double(i) / Double(steps)
        let e = t < 0.5 ? 2 * t * t : 1 - pow(-2 * t + 2, 2) / 2
        moveEvent(CGPoint(x: start.x + (target.x - start.x) * e, y: start.y + (target.y - start.y) * e), dragging: dragging)
        usleep(useconds_t(ms / Double(steps) * 1000))
    }
}

func button(_ type: CGEventType, _ p: CGPoint) {
    let e = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: p, mouseButton: .left)
    e?.setIntegerValueField(.mouseEventClickState, value: 1)
    post(e)
}

func click(_ p: CGPoint) {
    glide(to: p, ms: 120)
    usleep(60_000)
    button(.leftMouseDown, p)
    usleep(70_000)
    button(.leftMouseUp, p)
}

/// A trackpad-style scroll gesture: continuous deltas with began/changed/ended phases.
func swipe(dx: Double, dy: Double) {
    let steps = 10
    func scroll(_ x: Double, _ y: Double, phase: Int64) {
        guard let e = CGEvent(scrollWheelEvent2Source: source, units: .pixel, wheelCount: 2, wheel1: Int32(y), wheel2: Int32(x), wheel3: 0) else { return }
        e.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        e.setIntegerValueField(.scrollWheelEventScrollPhase, value: phase)
        e.setDoubleValueField(.scrollWheelEventPointDeltaAxis1, value: y)
        e.setDoubleValueField(.scrollWheelEventPointDeltaAxis2, value: x)
        e.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: y)
        e.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2, value: x)
        e.post(tap: .cghidEventTap)
    }
    scroll(0, 0, phase: 1) // kCGScrollPhaseBegan
    for _ in 0..<steps {
        usleep(12_000)
        scroll(dx / Double(steps), dy / Double(steps), phase: 2) // changed
    }
    usleep(12_000)
    scroll(0, 0, phase: 4) // ended
}

// MARK: Accessibility

func appElement(_ bundleID: String) -> AXUIElement {
    guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first else { fail("not running: \(bundleID)") }
    return AXUIElementCreateApplication(app.processIdentifier)
}

func attr(_ e: AXUIElement, _ name: String) -> AnyObject? {
    var v: AnyObject?
    return AXUIElementCopyAttributeValue(e, name as CFString, &v) == .success ? v : nil
}

func frame(_ e: AXUIElement) -> CGRect? {
    var p = CGPoint.zero, s = CGSize.zero
    guard let pv = attr(e, kAXPositionAttribute), let sv = attr(e, kAXSizeAttribute) else { return nil }
    AXValueGetValue(pv as! AXValue, .cgPoint, &p)
    AXValueGetValue(sv as! AXValue, .cgSize, &s)
    return CGRect(origin: p, size: s)
}

func label(_ e: AXUIElement) -> String {
    [kAXDescriptionAttribute, kAXTitleAttribute, kAXValueAttribute, kAXHelpAttribute]
        .compactMap { attr(e, $0) as? String }.filter { !$0.isEmpty }.joined(separator: " | ")
}

func walk(_ e: AXUIElement, depth: Int = 0, _ visit: (AXUIElement, Int) -> Bool) {
    guard depth < 40, visit(e, depth) else { return }
    for c in (attr(e, kAXChildrenAttribute) as? [AXUIElement]) ?? [] { walk(c, depth: depth + 1, visit) }
}

/// Top-level elements: the app's windows and children (some panels only appear in one of them).
func roots(_ bundleID: String) -> [AXUIElement] {
    let app = appElement(bundleID)
    return ((attr(app, kAXWindowsAttribute) as? [AXUIElement]) ?? []) + ((attr(app, kAXChildrenAttribute) as? [AXUIElement]) ?? [])
}

/// Elements found by hit-testing a grid over a region (works even when window enumeration does not).
func scan(_ region: CGRect?, pid: pid_t) -> [AXUIElement] {
    guard let r = region else { return [] }
    let system = AXUIElementCreateSystemWide()
    var out: [AXUIElement] = []
    var y = r.minY + 3
    while y < r.maxY {
        var x = r.minX + 3
        while x < r.maxX {
            var el: AXUIElement?
            if AXUIElementCopyElementAtPosition(system, Float(x), Float(y), &el) == .success, let el {
                var owner: pid_t = 0
                AXUIElementGetPid(el, &owner)
                if owner == pid, !out.contains(where: { CFEqual($0, el) }) { out.append(el) }
            }
            x += 6
        }
        y += 6
    }
    return out
}

func region(at i: Int) -> CGRect? {
    args.count >= i + 4 ? CGRect(x: num(i), y: num(i + 1), width: num(i + 2), height: num(i + 3)) : nil
}

func pid(_ bundleID: String) -> pid_t { NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first?.processIdentifier ?? 0 }

func labelParts(_ e: AXUIElement) -> [String] {
    [kAXDescriptionAttribute, kAXTitleAttribute, kAXValueAttribute, kAXHelpAttribute]
        .compactMap { attr(e, $0) as? String }.filter { !$0.isEmpty }
}

/// Exact label matches win over substring matches ("Play" must not hit "Playback position").
func find(_ bundleID: String, _ needle: String, _ r: CGRect?) -> AXUIElement? {
    var candidates: [AXUIElement] = []
    for w in roots(bundleID) { walk(w) { e, _ in candidates.append(e); return true } }
    for e in scan(r, pid: pid(bundleID)) {
        // The hit element may be a child of the labelled one (e.g. an image inside a button).
        var cur: AXUIElement? = e
        for _ in 0..<4 {
            guard let c = cur else { break }
            candidates.append(c)
            cur = attr(c, kAXParentAttribute).map { $0 as! AXUIElement }
        }
    }
    let exact = candidates.first { labelParts($0).contains { $0.caseInsensitiveCompare(needle) == .orderedSame } }
    return exact ?? candidates.first { label($0).localizedCaseInsensitiveContains(needle) }
}

// MARK: Pixels

func loadImage(_ path: String) -> (CGImage, Double) {
    guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
          let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { fail("cannot read \(path)") }
    let pointsWide = Double(NSScreen.screens.first?.frame.width ?? CGFloat(img.width))
    return (img, Double(img.width) / pointsWide)
}

func pixels(_ img: CGImage) -> [UInt8] {
    var buf = [UInt8](repeating: 0, count: img.width * img.height * 4)
    buf.withUnsafeMutableBytes { b in
        let ctx = CGContext(data: b.baseAddress, width: img.width, height: img.height, bitsPerComponent: 8, bytesPerRow: img.width * 4,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: img.width, height: img.height))
    }
    return buf
}

func isDark(_ px: [UInt8], _ w: Int, _ x: Int, _ y: Int) -> Bool {
    let i = (y * w + x) * 4
    return Int(px[i]) + Int(px[i + 1]) + Int(px[i + 2]) < 3 * 22
}

// MARK: File drag

/// A small window holding one file; scripted mouse events drag it out with a real drag session,
/// the way Finder would, so the destination sees an ordinary file drop.
final class DragSource: NSView, NSDraggingSource {
    let url: URL
    var started = false
    var ended: ((NSDragOperation) -> Void)?

    init(url: URL, frame: NSRect) {
        self.url = url
        super.init(frame: frame)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.systemBlue.setFill()
        bounds.fill()
    }
    override func mouseDown(with event: NSEvent) {}
    override func mouseDragged(with event: NSEvent) {
        guard !started else { return }
        started = true
        let item = NSDraggingItem(pasteboardWriter: url as NSURL)
        item.setDraggingFrame(bounds, contents: NSWorkspace.shared.icon(forFile: url.path))
        beginDraggingSession(with: [item], event: event, source: self)
        print("drag started")
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation { .copy }
    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) { ended?(operation) }
}

@MainActor func fileDrag(path: String, from a: CGPoint, to b: CGPoint, hold: Double) -> Never {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let side: CGFloat = 64
    let top = NSScreen.screens[0].frame.maxY   // CoreGraphics y runs down from the top of the main display
    let window = NSWindow(contentRect: NSRect(x: a.x - side / 2, y: top - a.y - side / 2, width: side, height: side),
                          styleMask: [.borderless], backing: .buffered, defer: false)
    window.level = .floating
    let view = DragSource(url: URL(fileURLWithPath: path), frame: NSRect(x: 0, y: 0, width: side, height: side))
    view.ended = { op in
        print("drop \(op.isEmpty ? "refused" : "accepted")")
        exit(op.isEmpty ? 3 : 0)
    }
    window.contentView = view
    window.orderFrontRegardless()
    DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) {
        glide(to: a, ms: 150)
        usleep(100_000)
        button(.leftMouseDown, a)
        usleep(200_000)
        // A small step first: the drag starts on the first dragged event.
        glide(to: CGPoint(x: a.x + 12, y: a.y - 12), ms: 120, dragging: true)
        glide(to: b, ms: 700, dragging: true)
        // Wiggle in place while holding, as a hand does, so the destination keeps getting updates.
        let steps = max(1, Int(hold / 50))
        for i in 0..<steps {
            moveEvent(CGPoint(x: b.x + (i % 2 == 0 ? 1 : -1), y: b.y), dragging: true)
            usleep(50_000)
        }
        button(.leftMouseUp, b)
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            MainActor.assumeIsolated { print(view.started ? "drop: no answer from the drag session" : "drag never started") }
            exit(4)
        }
    }
    app.run()
    exit(0)
}

// MARK: Commands

switch arg(0) {
case "info":
    let s = NSScreen.screens.first!
    print("screen=\(Int(s.frame.width))x\(Int(s.frame.height)) scale=\(s.backingScaleFactor) visibleTop=\(Int(s.frame.maxY - s.visibleFrame.maxY)) safeTop=\(Int(s.safeAreaInsets.top)) mouse=\(mouseLocation()) axTrusted=\(AXIsProcessTrusted())")
case "move":
    glide(to: CGPoint(x: num(1), y: num(2)), ms: num(3, 400))
    print("mouse=\(mouseLocation())")
case "jump":
    moveEvent(CGPoint(x: num(1), y: num(2)))
    print("mouse=\(mouseLocation())")
case "click":
    click(CGPoint(x: num(1), y: num(2)))
case "drag":
    let a = CGPoint(x: num(1), y: num(2)), b = CGPoint(x: num(3), y: num(4))
    glide(to: a, ms: 120)
    button(.leftMouseDown, a)
    usleep(80_000)
    glide(to: b, ms: num(5, 300), dragging: true)
    usleep(80_000)
    button(.leftMouseUp, b)
case "swipe":
    if args.count >= 5 { glide(to: CGPoint(x: num(3), y: num(4)), ms: 150) }
    swipe(dx: num(1), dy: num(2))
case "key":
    let code: CGKeyCode = arg(1) == "return" ? 36 : arg(1) == "cmd-w" ? 13 : 53
    let down = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: true)
    let up = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: false)
    // Always set the flags: an event from this source otherwise inherits modifiers from earlier
    // ones (an Escape after ⌘W arrived as ⌘Escape, which does not close a menu).
    let flags: CGEventFlags = arg(1).hasPrefix("cmd-") ? .maskCommand : []
    down?.flags = flags
    up?.flags = flags
    if args.count > 2, let pid = pid_t(arg(2)) {
        // Straight to one process, past the window server's keyboard focus.
        down?.postToPid(pid)
        up?.postToPid(pid)
    } else {
        post(down)
        post(up)
    }
case "windows":
    let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
    for w in list where (w[kCGWindowOwnerName as String] as? String) == arg(1) {
        let b = w[kCGWindowBounds as String] as? [String: Double] ?? [:]
        print("id=\(w[kCGWindowNumber as String] ?? 0) layer=\(w[kCGWindowLayer as String] ?? 0) x=\(Int(b["X"] ?? 0)) y=\(Int(b["Y"] ?? 0)) w=\(Int(b["Width"] ?? 0)) h=\(Int(b["Height"] ?? 0)) sharing=\(w[kCGWindowSharingState as String] ?? -1) name=\(w[kCGWindowName as String] ?? "")")
    }
case "ax-at":
    var el: AXUIElement?
    let err = AXUIElementCopyElementAtPosition(AXUIElementCreateSystemWide(), Float(num(1)), Float(num(2)), &el)
    if let el {
        var owner: pid_t = 0
        AXUIElementGetPid(el, &owner)
        print("pid=\(owner) role=\(attr(el, kAXRoleAttribute) as? String ?? "?") label=[\(label(el))] frame=\(frame(el).map { "\($0)" } ?? "-")")
    } else {
        print("none (error \(err.rawValue))")
    }
case "pixel":
    let (img, scale) = loadImage(arg(1))
    let px = pixels(img), w = img.width
    let x = min(w - 1, Int(num(2) * scale)), y = min(img.height - 1, Int(num(3) * scale))
    let i = (y * w + x) * 4
    print("\(isDark(px, w, x, y) ? "dark" : "light") \(px[i]) \(px[i + 1]) \(px[i + 2])")
case "ax-dump":
    let app = appElement(arg(1))
    print("windows=\((attr(app, kAXWindowsAttribute) as? [AXUIElement])?.count ?? -1) children=\((attr(app, kAXChildrenAttribute) as? [AXUIElement])?.count ?? -1)")
    for w in roots(arg(1)) {
        walk(w) { e, d in
            let f = frame(e).map { "\(Int($0.minX)),\(Int($0.minY)) \(Int($0.width))x\(Int($0.height))" } ?? "-"
            print(String(repeating: "  ", count: d) + "\(attr(e, kAXRoleAttribute) as? String ?? "?") [\(label(e))] \(f)")
            return true
        }
    }
case "ax-find":
    guard let e = find(arg(1), arg(2), region(at: 3)), let f = frame(e) else { fail("not found: \(arg(2))") }
    print("\(Int(f.midX)) \(Int(f.midY))")
case "ax-frame":
    guard let e = find(arg(1), arg(2), region(at: 3)), let f = frame(e) else { fail("not found: \(arg(2))") }
    print("\(Int(f.minX)) \(Int(f.minY)) \(Int(f.width)) \(Int(f.height))")
case "ax-press":
    guard let e = find(arg(1), arg(2), region(at: 3)) else { fail("not found: \(arg(2))") }
    print(AXUIElementPerformAction(e, kAXPressAction as CFString) == .success ? "pressed" : "press failed")
case "status-items":
    // Every menu bar icon on screen (status-level windows), whoever owns it: "owner x width".
    let level = Int(CGWindowLevelForKey(.statusWindow))
    let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
    for w in list where (w[kCGWindowLayer as String] as? Int) == level {
        let b = w[kCGWindowBounds as String] as? [String: Double] ?? [:]
        let owner = (w[kCGWindowOwnerName as String] as? String ?? "?").replacingOccurrences(of: " ", with: "_")
        print("\(owner) \(Int(b["X"] ?? 0)) \(Int(b["Width"] ?? 0))")
    }
case "menu-extent":
    // Right edge of the frontmost app's menus (Accessibility): "app maxX".
    guard let app = NSWorkspace.shared.menuBarOwningApplication else { fail("no menu bar owner") }
    let el = AXUIElementCreateApplication(app.processIdentifier)
    var end = 0.0
    if let bar = attr(el, kAXMenuBarAttribute) {
        for item in (attr(bar as! AXUIElement, kAXChildrenAttribute) as? [AXUIElement]) ?? [] {
            if let f = frame(item), f.width > 0 { end = max(end, Double(f.maxX)) }
        }
    }
    print("\((app.localizedName ?? "?").replacingOccurrences(of: " ", with: "_")) \(Int(end))")
case "status-press":
    // Press the app's menu bar item the way VoiceOver would (AXExtrasMenuBar → first item).
    // The call can block while the menu is open, so callers run it under a time limit.
    guard let bar = attr(appElement(arg(1)), "AXExtrasMenuBar"),
          let item = (attr(bar as! AXUIElement, kAXChildrenAttribute) as? [AXUIElement])?.first else { fail("no menu bar item") }
    print(AXUIElementPerformAction(item, kAXPressAction as CFString) == .success ? "pressed" : "press failed")
case "ax-texts":
    var seen = Set<String>()
    func emit(_ e: AXUIElement) {
        if (attr(e, kAXRoleAttribute) as? String) == kAXStaticTextRole {
            let v = (attr(e, kAXValueAttribute) as? String) ?? (attr(e, kAXDescriptionAttribute) as? String) ?? ""
            if !v.isEmpty, seen.insert(v).inserted { print(v) }
        }
    }
    for w in roots(arg(1)) { walk(w) { e, _ in emit(e); return true } }
    for e in scan(region(at: 2), pid: pid(arg(1))) { emit(e) }
case "dark-run":
    let (img, scale) = loadImage(arg(1))
    let px = pixels(img), w = img.width
    let y = min(img.height - 1, Int(num(2) * scale))
    var best = (0, 0), cur = 0
    for x in 0..<w {
        cur = isDark(px, w, x, y) ? cur + 1 : 0
        if cur > best.1 { best = (x - cur + 1, cur) }
    }
    print("\(Int(Double(best.0) / scale)) \(Int(Double(best.1) / scale))")
case "dark-box":
    // Flood the dark region connected to the top-centre pixel row (the island hangs from the top edge).
    let (img, scale) = loadImage(arg(1))
    let px = pixels(img), w = img.width, h = img.height
    var seen = [Bool](repeating: false, count: w * h)
    var stack: [(Int, Int)] = []
    let cx = w / 2
    for y in 0..<min(h, Int(6 * scale)) where isDark(px, w, cx, y) { stack.append((cx, y)) }
    var minX = w, minY = h, maxX = -1, maxY = -1
    while let (x, y) = stack.popLast() {
        guard x >= 0, y >= 0, x < w, y < h, !seen[y * w + x], isDark(px, w, x, y) else { continue }
        seen[y * w + x] = true
        minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
        stack.append(contentsOf: [(x + 1, y), (x - 1, y), (x, y + 1), (x, y - 1)])
    }
    if maxX < 0 { print("0 0 0 0") } else {
        print("\(Int(Double(minX) / scale)) \(Int(Double(minY) / scale)) \(Int(Double(maxX - minX + 1) / scale)) \(Int(Double(maxY - minY + 1) / scale))")
    }
case "ax-menu":
    guard let bar = attr(appElement(arg(1)), kAXMenuBarAttribute) else { fail("no menu bar") }
    var found: AXUIElement?
    func search(_ e: AXUIElement, _ depth: Int) {
        guard found == nil, depth < 6 else { return }
        if (attr(e, kAXRoleAttribute) as? String) == kAXMenuItemRole, (attr(e, kAXTitleAttribute) as? String) == arg(2) {
            found = e
            return
        }
        for c in (attr(e, kAXChildrenAttribute) as? [AXUIElement]) ?? [] { search(c, depth + 1) }
    }
    search(bar as! AXUIElement, 0)
    guard let item = found else { fail("no menu item \(arg(2))") }
    let key = attr(item, kAXMenuItemCmdCharAttribute) as? String ?? "-"
    let mods = (attr(item, kAXMenuItemCmdModifiersAttribute) as? Int) ?? -1
    print("key=\(key) modifiers=\(mods)")
    if arg(3) == "press" {
        print(AXUIElementPerformAction(item, kAXPressAction as CFString) == .success ? "pressed" : "press failed")
    }
case "pasteboard":
    let pb = NSPasteboard.general
    pb.clearContents()
    pb.declareTypes([.string] + args.dropFirst(2).map { NSPasteboard.PasteboardType($0) }, owner: nil)
    pb.setString(arg(1), forType: .string)
    for t in args.dropFirst(2) { pb.setData(Data(), forType: NSPasteboard.PasteboardType(t)) }
    print("changeCount=\(pb.changeCount)")
case "file-drag":
    MainActor.assumeIsolated {
        fileDrag(path: arg(1), from: CGPoint(x: num(2), y: num(3)), to: CGPoint(x: num(4), y: num(5)), hold: num(6, 1200))
    }
default:
    fail("unknown command \(arg(0)); see the header of QA/Driver/main.swift")
}
