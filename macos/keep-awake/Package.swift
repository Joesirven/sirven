// swift-tools-version:5.9
// keep-awake for sirven: hold a power assertion while the user's agent has work in flight.
import PackageDescription

let package = Package(
    name: "SirvenKeepAwake",
    platforms: [.macOS(.v13)],
    products: [
        // the menu bar app links this library for the status surface and the release action.
        .library(name: "SirvenKeepAwake", targets: ["SirvenKeepAwake"]),
        .executable(name: "sirven-keep-awake", targets: ["sirven-keep-awake"]),
        .executable(name: "sirven-keep-awake-helper", targets: ["sirven-keep-awake-helper"]),
    ],
    targets: [
        .target(name: "SirvenKeepAwake", linkerSettings: [.linkedFramework("IOKit"), .linkedFramework("ServiceManagement")]),
        .executableTarget(name: "sirven-keep-awake", dependencies: ["SirvenKeepAwake"]),
        .executableTarget(name: "sirven-keep-awake-helper", dependencies: ["SirvenKeepAwake"]),
        .testTarget(name: "SirvenKeepAwakeTests", dependencies: ["SirvenKeepAwake"]),
    ]
)
