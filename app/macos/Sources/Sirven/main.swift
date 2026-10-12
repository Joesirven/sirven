import AppKit
import SirvenMenuCore
import SirvenOnboarding
import SwiftUI

// the Sirven executable inside Sirven.app, the one bundle sirven ships. no dock icon (LSUIElement
// in Info.plist): it owns sirven's menu bar item (MenuBarController, drawn from SirvenMenuCore in
// macos/menu-bar), and on first launch it also shows the onboarding wizard.
//
//   Sirven                     normal launch
//   Sirven --demo              the wizard against test data: fake permissions, a sample
//                              endpoint, nothing saved to your real settings
//   Sirven --snapshot <dir>    render each wizard step to an image in <dir>, then quit
//   Sirven --reset-onboarding  forget the saved result, so the wizard shows again
//   Sirven --print-menu        print the menu bar menu as text from live, read-only state, then quit
//   Sirven --render-icon <dir> write AppIcon.iconset into <dir> (build.sh uses it), then quit

let arguments = CommandLine.arguments

func argument(after flag: String) -> String? {
  guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
  return arguments[index + 1]
}

// the copy ships in Contents/Resources. outside a bundle (swift run, tests), SIRVEN_COPY or
// the repository's copy/ folder is used instead.
func locateCopy() -> URL? {
  if let bundled = Bundle.main.url(forResource: OnboardingCopy.fileName, withExtension: "json") { return bundled }
  if let path = ProcessInfo.processInfo.environment["SIRVEN_COPY"] { return URL(fileURLWithPath: path) }
  var directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
  for _ in 0..<5 {
    let candidate = directory.appendingPathComponent("copy/\(OnboardingCopy.fileName).json")
    if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
    directory.deleteLastPathComponent()
  }
  return nil
}

func loadCopyOrExit() -> OnboardingCopy {
  guard let url = locateCopy() else {
    FileHandle.standardError.write(Data("sirven: the wizard copy (\(OnboardingCopy.fileName).json) was not found\n".utf8))
    exit(1)
  }
  do {
    return try OnboardingCopy.load(from: url)
  } catch {
    FileHandle.standardError.write(Data("sirven: could not read \(url.path): \(error)\n".utf8))
    exit(1)
  }
}

let demoEndpoint = "http://127.0.0.1:7878"

@MainActor
func snapshot(into directory: URL) {
  let copy = loadCopyOrExit()
  let model = OnboardingModel(copy: copy, broker: FakePermissionBroker(), endpoint: demoEndpoint)
  try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  var index = 1
  while true {
    if model.step == .permissions {
      // show the permissions step answered, as a user who allowed both would see it.
      let group = DispatchGroup()
      for permission in Permission.allCases {
        group.enter()
        Task { await model.request(permission); group.leave() }
      }
      while group.wait(timeout: .now()) == .timedOut { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
    }
    let view = OnboardingView(model: model, onDone: { _ in })
      .environment(\.sirvenStillFrame, true)
    let renderer = ImageRenderer(content: view)
    renderer.scale = 2
    if let image = renderer.nsImage, let tiff = image.tiffRepresentation,
       let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
      let url = directory.appendingPathComponent("\(index)-\(model.step).png")
      try? png.write(to: url)
      print(url.path)
    }
    if model.step == .confirmation { break }
    model.next()
    index += 1
  }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
  private var window: NSWindow?
  private var menuBar: MenuBarController?
  private let demo = arguments.contains("--demo")

  private lazy var store: OnboardingStore = {
    if demo {
      return OnboardingStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent("sirven-demo", isDirectory: true))
    }
    return .standard
  }()

  func applicationDidFinishLaunching(_ notification: Notification) {
    if arguments.contains("--reset-onboarding") { try? store.reset() }
    let menuBar = MenuBarController(
      tailscale: TailscaleClient(executable: TailscaleClient.resolveExecutable()),
      stateProvider: StateFileProvider(path: StateFileProvider.defaultPath())
    )
    menuBar.install()
    self.menuBar = menuBar
    if demo || store.load() == nil { showWizard() }
  }

  private func showWizard() {
    let copy = loadCopyOrExit()
    let broker: PermissionBroker = demo ? FakePermissionBroker() : SystemPermissionBroker()
    let endpoint = demo ? demoEndpoint : store.runtimeEndpoint()
    let model = OnboardingModel(copy: copy, broker: broker, endpoint: endpoint)
    let view = OnboardingView(model: model) { [weak self] result in
      guard let self else { return }
      try? self.store.save(result)
      self.window?.close()
      self.window = nil
    }
    let window = NSWindow(
      contentRect: NSRect(origin: .zero, size: OnboardingView.size),
      styleMask: [.titled, .closable, .fullSizeContentView],
      backing: .buffered, defer: false
    )
    window.titlebarAppearsTransparent = true
    window.titleVisibility = .hidden
    window.isMovableByWindowBackground = true
    window.isReleasedWhenClosed = false
    window.contentView = NSHostingView(rootView: view)
    window.center()
    self.window = window
    NSApp.activate(ignoringOtherApps: true)
    window.makeKeyAndOrderFront(nil)
  }

}

// the app icon: the sirven mark in white on the accent, on the rounded square macOS expects,
// drawn from the same SirvenMark the wizard uses so the two can never drift.
struct AppIcon: View {
  var body: some View {
    ZStack {
      RoundedRectangle(cornerRadius: 230, style: .continuous)
        .fill(Theme.accent)
        .frame(width: 824, height: 824)
        .shadow(color: .black.opacity(0.18), radius: 20, y: 10)
      SirvenMark(lineWidth: 44).foregroundColor(.white).frame(width: 440, height: 440)
    }
    .frame(width: 1024, height: 1024)
  }
}

@MainActor
func renderIcon(into directory: URL) {
  let iconset = directory.appendingPathComponent("AppIcon.iconset", isDirectory: true)
  try? FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
  for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
      let renderer = ImageRenderer(content: AppIcon())
      renderer.scale = CGFloat(points * scale) / 1024
      let name = scale == 1 ? "icon_\(points)x\(points).png" : "icon_\(points)x\(points)@2x.png"
      guard let image = renderer.cgImage else { exit(1) }
      let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
      try? png?.write(to: iconset.appendingPathComponent(name))
    }
  }
  print(iconset.path)
}

if arguments.contains("--print-menu") {
  let tailscale = TailscaleClient(executable: TailscaleClient.resolveExecutable())
  let state = StateFileProvider(path: StateFileProvider.defaultPath()).current()
  print(MenuModel.render(MenuModel.build(state: state, tailscale: tailscale.snapshot())))
  exit(0)
}

if let directory = argument(after: "--render-icon") {
  MainActor.assumeIsolated { renderIcon(into: URL(fileURLWithPath: directory)) }
  exit(0)
}

if let directory = argument(after: "--snapshot") {
  MainActor.assumeIsolated { snapshot(into: URL(fileURLWithPath: directory)) }
  exit(0)
}

let app = NSApplication.shared
let delegate = MainActor.assumeIsolated { AppDelegate() }
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
