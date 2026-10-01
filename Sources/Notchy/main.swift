import AppKit
import SwiftUI
import NotchyCore

// Pipeline check skeleton; replaced by the real app.
@MainActor func snapshot(_ dir: String) {
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    let view = ZStack { Color.gray; RoundedRectangle(cornerRadius: 20).fill(.black).frame(width: 300, height: 100) }
        .frame(width: 400, height: 200)
    let r = ImageRenderer(content: view)
    r.scale = 2
    if let cg = r.cgImage {
        let rep = NSBitmapImageRep(cgImage: cg)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: dir + "/test.png"))
        print("wrote", dir + "/test.png")
    }
}

let args = CommandLine.arguments
if let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count {
    MainActor.assumeIsolated { snapshot(args[i + 1]) }
    exit(0)
}
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
MainActor.assumeIsolated {
    let w = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 300, height: 100), styleMask: [.borderless], backing: .buffered, defer: false)
    w.contentView = NSHostingView(rootView: Color.red)
    w.orderFrontRegardless()
    print("NOTCHY_WINDOW_ID=\(w.windowNumber)")
    fflush(stdout)
    _ = w
}
app.run()
