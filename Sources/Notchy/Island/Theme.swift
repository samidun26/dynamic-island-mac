import AppKit
import CoreText
import SwiftUI

/// The island's look. Classic is the system font and smooth shapes; Retro is pixel type, stepped
/// corners, segmented meters and pixelated artwork, optionally as a one-colour CRT.
enum IslandStyle: String, CaseIterable, Identifiable {
    case classic, retro
    var id: String { rawValue }
    var title: String { self == .classic ? "Classic" : "Retro" }
}

/// Retro colour: full colour, or one phosphor colour like an old monochrome monitor.
enum Phosphor: String, CaseIterable, Identifiable {
    case color, green, amber
    var id: String { rawValue }
    var title: String {
        switch self {
        case .color: "Full colour"
        case .green: "Green screen"
        case .amber: "Amber screen"
        }
    }
    var tint: Color? {
        switch self {
        case .color: nil
        case .green: Color(red: 0.35, green: 1, blue: 0.45)
        case .amber: Color(red: 1, green: 0.72, blue: 0.16)
        }
    }
}

struct IslandTheme: Equatable {
    var style = IslandStyle.classic
    var phosphor = Phosphor.color
    var scanlines = true

    var isRetro: Bool { style == .retro }
    /// Size of one "pixel" in retro drawings (corners, meters, artwork), in points.
    var pixel: CGFloat { isRetro ? 3 : 0 }

    /// Text in the island. `digits` is for numbers that tick (clocks, countdowns, times), which
    /// must keep a fixed width.
    @MainActor func font(_ size: CGFloat, _ weight: Font.Weight = .regular, digits: Bool = false, rounded: Bool = false) -> Font {
        guard isRetro else {
            let f = Font.system(size: size, weight: weight, design: rounded ? .rounded : .default)
            return digits ? f.monospacedDigit() : f
        }
        return digits ? RetroFonts.digits(size) : RetroFonts.text(size, weight)
    }
}

private struct IslandThemeKey: EnvironmentKey {
    static let defaultValue = IslandTheme()
}

extension EnvironmentValues {
    var islandTheme: IslandTheme {
        get { self[IslandThemeKey.self] }
        set { self[IslandThemeKey.self] = newValue }
    }
}

extension View {
    /// The island's text font for the current style.
    func islandFont(_ size: CGFloat, _ weight: Font.Weight = .regular, digits: Bool = false, rounded: Bool = false) -> some View {
        modifier(IslandFont(size: size, weight: weight, digits: digits, rounded: rounded))
    }
}

private struct IslandFont: ViewModifier {
    @Environment(\.islandTheme) private var theme
    let size: CGFloat
    let weight: Font.Weight
    let digits: Bool
    let rounded: Bool
    func body(content: Content) -> some View { content.font(theme.font(size, weight, digits: digits, rounded: rounded)) }
}

/// Retro finish for the whole island: one phosphor colour, and faint scanlines.
struct RetroScreen: ViewModifier {
    let theme: IslandTheme

    func body(content: Content) -> some View {
        if theme.isRetro {
            content
                .modifier(PhosphorTint(tint: theme.phosphor.tint))
                .overlay {
                    if theme.scanlines {
                        Canvas { gc, size in
                            var y: CGFloat = 1
                            while y < size.height {
                                gc.fill(Path(CGRect(x: 0, y: y, width: size.width, height: 1)), with: .color(.black.opacity(0.22)))
                                y += 3
                            }
                        }
                        .allowsHitTesting(false)
                    }
                }
        } else {
            content
        }
    }
}

private struct PhosphorTint: ViewModifier {
    let tint: Color?
    func body(content: Content) -> some View {
        if let tint { content.grayscale(1).colorMultiply(tint) } else { content }
    }
}

/// The bundled pixel fonts (SIL Open Font License, see Resources/Fonts): Pixelify Sans for text,
/// VT323 for numbers.
@MainActor
enum RetroFonts {
    private static var registered = false
    private static var cache: [String: Font] = [:]

    /// Makes the bundled fonts available to this process. Safe to call more than once.
    static func register() {
        guard !registered else { return }
        registered = true
        guard let dir = Bundle.main.resourceURL?.appendingPathComponent("Fonts"),
              let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return }
        for url in files where ["ttf", "otf"].contains(url.pathExtension.lowercased()) {
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
        let text = isAvailable(CTFontCreateWithName("PixelifySans-Regular" as CFString, 12, nil), "Pixelify")
        let digits = isAvailable(CTFontCreateWithName("VT323-Regular" as CFString, 12, nil), "VT323")
        QALog.log("FONTS text=\(text) digits=\(digits)")
    }

    /// Pixelify Sans at a weight, through its weight axis (it ships as one variable font).
    static func text(_ size: CGFloat, _ weight: Font.Weight) -> Font {
        let wght: Double = switch weight {
        case .bold, .heavy, .black: 700
        case .semibold: 600
        case .medium: 500
        default: 400
        }
        let key = "t\(size)-\(wght)"
        if let f = cache[key] { return f }
        // Pixel fonts look small next to the system font at the same size.
        let base = CTFontDescriptorCreateWithNameAndSize("PixelifySans-Regular" as CFString, size * 1.08)
        let wghtAxis = NSNumber(value: 0x7767_6874) // 'wght'
        let desc = CTFontDescriptorCreateCopyWithVariation(base, wghtAxis as CFNumber, CGFloat(wght))
        let ct = CTFontCreateWithFontDescriptor(desc, size * 1.08, nil)
        let font = isAvailable(ct, "Pixelify") ? Font(ct) : Font.system(size: size, weight: weight, design: .monospaced)
        cache[key] = font
        return font
    }

    /// VT323: fixed-width terminal digits.
    static func digits(_ size: CGFloat) -> Font {
        let key = "d\(size)"
        if let f = cache[key] { return f }
        let ct = CTFontCreateWithName("VT323-Regular" as CFString, size * 1.4, nil)
        let font = isAvailable(ct, "VT323") ? Font(ct) : Font.system(size: size, weight: .semibold, design: .monospaced)
        cache[key] = font
        return font
    }

    /// Core Text falls back to another font when one isn't found: check we got ours.
    private static func isAvailable(_ font: CTFont, _ family: String) -> Bool {
        (CTFontCopyFamilyName(font) as String).hasPrefix(family)
    }
}
