// swift-tools-version:5.9
// the sirven menu bar core: the Tailscale client, the sirven state provider, and the menu model.
// it is a library only. the signed app (app/macos) links it and draws the model as its menu bar
// menu, so sirven ships as one app bundle.
import PackageDescription

let package = Package(
    name: "SirvenMenuBar",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "SirvenMenuCore", targets: ["SirvenMenuCore"]),
    ],
    targets: [
        .target(name: "SirvenMenuCore"),
        .testTarget(
            name: "SirvenMenuCoreTests",
            dependencies: ["SirvenMenuCore"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
