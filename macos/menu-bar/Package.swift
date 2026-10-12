// swift-tools-version:5.9
// the sirven menu bar app: a core library (the Tailscale client, the sirven state provider, and
// the menu model) and a thin AppKit app that draws the model as a menu bar menu.
import PackageDescription

let package = Package(
    name: "SirvenMenuBar",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "SirvenMenuBar", targets: ["SirvenMenuBar"]),
    ],
    targets: [
        .target(name: "SirvenMenuCore"),
        .executableTarget(name: "SirvenMenuBar", dependencies: ["SirvenMenuCore"]),
        .testTarget(
            name: "SirvenMenuCoreTests",
            dependencies: ["SirvenMenuCore"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
