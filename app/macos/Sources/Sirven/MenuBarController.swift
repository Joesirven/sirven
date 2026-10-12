import AppKit
import SirvenMenuCore

/// Owns the menu bar item. The signed app's AppDelegate creates it and calls install(). The menu shows the last known state the moment it opens, then
/// refreshes in the background and redraws only if something changed. Every Tailscale call runs
/// on one serial queue, never on the main thread.
final class MenuBarController: NSObject, NSMenuDelegate {
    /// the Menu Bar pane of System Settings on macOS 26, where "Allow in the Menu Bar" lives.
    static let menuBarSettingsURL = URL(string: "x-apple.systempreferences:com.apple.ControlCenter-Settings.extension")!
    /// the App Store build first, then the standalone build.
    static let tailscaleBundleIdentifiers = ["io.tailscale.ipn.macos", "io.tailscale.ipn.macsys"]

    private let tailscale: TailscaleClient
    private let stateProvider: SirvenStateProvider
    private let work = DispatchQueue(label: "sirven.menu-bar.tailscale")
    private var statusItem: NSStatusItem!
    private let menu = NSMenu()

    private var state = SirvenState.fresh
    private var snapshot = TailscaleSnapshot(connection: .starting)
    private var lastError: String?
    private var drawn: [MenuEntry] = []

    init(tailscale: TailscaleClient, stateProvider: SirvenStateProvider) {
        self.tailscale = tailscale
        self.stateProvider = stateProvider
    }

    func install() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = Self.icon()
        statusItem.button?.setAccessibilityLabel(MenuCopy.appName)
        menu.delegate = self
        menu.autoenablesItems = false
        statusItem.menu = menu
        redraw()
        refresh()
    }

    // MARK: drawing

    func menuWillOpen(_ menu: NSMenu) {
        refresh()
    }

    private func refresh() {
        let tailscale = self.tailscale
        let stateProvider = self.stateProvider
        work.async {
            let snapshot = tailscale.snapshot()
            let state = stateProvider.current()
            DispatchQueue.main.async {
                self.snapshot = snapshot
                self.state = state
                self.redraw()
            }
        }
    }

    private func redraw() {
        let entries = MenuModel.build(state: state, tailscale: snapshot, lastError: lastError)
        guard entries != drawn else { return }
        drawn = entries
        menu.removeAllItems()
        for item in Self.menuItems(entries, target: self) { menu.addItem(item) }
    }

    private static func menuItems(_ entries: [MenuEntry], target: MenuBarController) -> [NSMenuItem] {
        entries.map { entry in
            switch entry {
            case .separator:
                return NSMenuItem.separator()
            case .heading(let text):
                let item = NSMenuItem(title: text, action: nil, keyEquivalent: "")
                item.attributedTitle = NSAttributedString(string: text, attributes: [
                    .font: NSFont.systemFont(ofSize: NSFont.systemFontSize, weight: .semibold),
                ])
                item.isEnabled = false
                return item
            case .line(let text):
                let item = NSMenuItem(title: text, action: nil, keyEquivalent: "")
                item.isEnabled = false
                return item
            case .item(let model):
                let item = NSMenuItem(title: model.title, action: nil, keyEquivalent: model.action == .quit ? "q" : "")
                item.isEnabled = model.enabled
                item.state = model.checked ? .on : .off
                if let action = model.action {
                    item.target = target
                    item.action = #selector(MenuBarController.perform(_:))
                    item.representedObject = ActionBox(action)
                }
                if !model.children.isEmpty {
                    let submenu = NSMenu()
                    submenu.autoenablesItems = false
                    for child in menuItems(model.children, target: target) { submenu.addItem(child) }
                    item.submenu = submenu
                }
                return item
            }
        }
    }

    // MARK: actions

    @objc private func perform(_ sender: NSMenuItem) {
        guard let action = (sender.representedObject as? ActionBox)?.action else { return }
        switch action {
        case .connect: change { $0.connect() }
        case .disconnect: change { $0.disconnect() }
        case .useExitNode(let address): change { $0.useExitNode(address) }
        case .copy(let text):
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        case .openTierSettings: inform(MenuCopy.tierComing)
        case .openKeepAwakeSettings: inform(MenuCopy.keepAwakeComing)
        case .hideTailscaleMenuBarItem: askToHideTailscaleItem()
        case .openTailscale: openTailscale()
        case .quit: NSApp.terminate(nil)
        }
    }

    private func change(_ body: @escaping (TailscaleClient) -> TailscaleChangeResult) {
        let tailscale = self.tailscale
        work.async {
            let result = body(tailscale)
            DispatchQueue.main.async {
                if case .failed(let reason) = result { self.lastError = reason } else { self.lastError = nil }
                self.refresh()
            }
        }
    }

    private func askToHideTailscaleItem() {
        guard ProcessInfo.processInfo.isOperatingSystemAtLeast(OperatingSystemVersion(majorVersion: 26, minorVersion: 0, patchVersion: 0)) else {
            inform(MenuCopy.hideOlderMacOS, title: MenuCopy.hideTitle)
            return
        }
        let alert = NSAlert()
        alert.messageText = MenuCopy.hideTitle
        alert.informativeText = MenuCopy.hideBody
        alert.addButton(withTitle: MenuCopy.hideConfirm)
        alert.addButton(withTitle: MenuCopy.hideDecline)
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.open(Self.menuBarSettingsURL)
        }
    }

    private func openTailscale() {
        for identifier in Self.tailscaleBundleIdentifiers {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: identifier) {
                NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
                return
            }
        }
    }

    private func inform(_ text: String, title: String = MenuCopy.comingTitle) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        alert.addButton(withTitle: MenuCopy.done)
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    // MARK: icon

    /// The sirven mark (the same ring and dot as SirvenMark in the wizard), as a template glyph
    /// so macOS tints it for light, dark, and tinted menu bars.
    static func icon() -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { rect in
            NSColor.black.setStroke()
            NSColor.black.setFill()
            let ring = NSBezierPath(ovalIn: rect.insetBy(dx: 2.5, dy: 2.5))
            ring.lineWidth = 1.6
            ring.stroke()
            let dot = rect.width * 0.34 * (13 / 18)
            NSBezierPath(ovalIn: NSRect(x: rect.midX - dot / 2, y: rect.midY - dot / 2, width: dot, height: dot)).fill()
            return true
        }
        image.isTemplate = true
        return image
    }
}

private final class ActionBox: NSObject {
    let action: MenuAction
    init(_ action: MenuAction) { self.action = action }
}
