// swift-tools-version:5.9
// the sirven macOS app: the onboarding wizard (a library the menu-bar app links) and the
// Sirven executable that build.sh wraps into Sirven.app. macOS 13 is the floor because the
// open-at-login permission and the lazy privileged helper both use SMAppService.
import PackageDescription

let package = Package(
  name: "Sirven",
  platforms: [.macOS(.v13)],
  products: [
    .library(name: "SirvenOnboarding", targets: ["SirvenOnboarding"]),
    .executable(name: "Sirven", targets: ["Sirven"]),
  ],
  targets: [
    .target(name: "SirvenOnboarding"),
    .executableTarget(name: "Sirven", dependencies: ["SirvenOnboarding"]),
    .testTarget(name: "SirvenOnboardingTests", dependencies: ["SirvenOnboarding"]),
  ]
)
