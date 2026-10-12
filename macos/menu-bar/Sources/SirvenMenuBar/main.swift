import AppKit
import SirvenMenuCore

// sirven's menu bar app: no Dock icon (LSUIElement in the bundle, and the accessory activation
// policy when run bare), one menu bar item, and a menu drawn from MenuModel.
//
//   SirvenMenuBar               run the menu bar app
//   SirvenMenuBar --print-menu  print the menu as text from live, read-only state, and exit

let arguments = CommandLine.arguments.dropFirst()
let tailscale = TailscaleClient(executable: TailscaleClient.resolveExecutable())
let stateProvider = StateFileProvider(path: StateFileProvider.defaultPath())

if arguments.contains("--print-menu") {
    let entries = MenuModel.build(state: stateProvider.current(), tailscale: tailscale.snapshot())
    print(MenuModel.render(entries))
    exit(0)
}

let app = NSApplication.shared
let controller = MenuBarController(tailscale: tailscale, stateProvider: stateProvider)
app.setActivationPolicy(.accessory)
app.delegate = controller
app.run()
