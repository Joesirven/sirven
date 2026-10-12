// swift-tools-version:5.9
// the sirven macOS app, the one bundle sirven ships: the onboarding wizard (SirvenOnboarding),
// the menu bar core from macos/menu-bar (SirvenMenuCore), and the Sirven executable that
// build.sh wraps into Sirven.app. macOS 13 is the floor because the
// open-at-login permission and the lazy privileged helper both use SMAppService.
import PackageDescription

let package = Package(
  name: "Sirven",
  platforms: [.macOS(.v13)],
  products: [
    .library(name: "SirvenOnboarding", targets: ["SirvenOnboarding"]),
    .executable(name: "Sirven", targets: ["Sirven"]),
  ],
  dependencies: [
    .package(path: "../../macos/menu-bar"),
  ],
  targets: [
    .target(name: "SirvenOnboarding"),
    .executableTarget(name: "Sirven", dependencies: [
      "SirvenOnboarding",
      .product(name: "SirvenMenuCore", package: "menu-bar"),
    ]),
    .testTarget(name: "SirvenOnboardingTests", dependencies: ["SirvenOnboarding"]),
  ]
)
