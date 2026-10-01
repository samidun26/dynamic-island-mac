// swift-tools-version: 6.0
import PackageDescription

// NotchyCore is plain Foundation (geometry, activity priority, hover intent,
// now-playing parsing) so it builds and tests anywhere. The app target needs
// AppKit/SwiftUI and is only added on macOS.
var targets: [Target] = [
    .target(name: "NotchyCore"),
    .testTarget(name: "NotchyCoreTests", dependencies: ["NotchyCore"]),
]
var products: [Product] = [
    .library(name: "NotchyCore", targets: ["NotchyCore"]),
]

#if os(macOS)
targets.append(.executableTarget(
    name: "Notchy",
    dependencies: ["NotchyCore"],
    linkerSettings: [
        .linkedFramework("IOKit"),
        .linkedFramework("CoreAudio"),
        .linkedFramework("EventKit"),
        .linkedFramework("ServiceManagement"),
    ]
))
products.append(.executable(name: "Notchy", targets: ["Notchy"]))
#endif

let package = Package(
    name: "Notchy",
    platforms: [.macOS(.v14)],
    products: products,
    targets: targets,
    swiftLanguageModes: [.v6]
)
