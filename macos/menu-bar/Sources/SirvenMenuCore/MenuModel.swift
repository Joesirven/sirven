import Foundation

public enum MenuAction: Equatable {
    case connect
    case disconnect
    /// `nil` stops using an exit node.
    case useExitNode(String?)
    case copy(String)
    case openTierSettings
    case openKeepAwakeSettings
    case hideTailscaleMenuBarItem
    case openTailscale
    case quit
}

public struct MenuItem: Equatable {
    public var title: String
    public var action: MenuAction?
    public var enabled: Bool
    public var checked: Bool
    public var children: [MenuEntry]

    public init(_ title: String, action: MenuAction? = nil, enabled: Bool = true, checked: Bool = false, children: [MenuEntry] = []) {
        self.title = title
        self.action = action
        self.enabled = enabled
        self.checked = checked
        self.children = children
    }
}

public enum MenuEntry: Equatable {
    /// the one heading at the top of the menu.
    case heading(String)
    /// a quiet line of state that does nothing when clicked.
    case line(String)
    case item(MenuItem)
    case separator
}

/// Builds the whole menu from state. Pure: the app draws whatever this returns, and the tests
/// read it as text.
public enum MenuModel {
    public static func build(
        state: SirvenState,
        tailscale: TailscaleSnapshot,
        lastError: String? = nil,
        formatTime: (Date) -> String = MenuModel.shortTime
    ) -> [MenuEntry] {
        var entries: [MenuEntry] = [.heading(MenuCopy.appName)]
        entries.append(tierEntry(state.tier))
        entries.append(.line(agentLine(state.agent)))
        entries.append(.line(keepAwakeLine(state.keepAwake, formatTime: formatTime)))
        entries.append(.separator)
        entries += tailscaleEntries(tailscale)
        if let lastError {
            entries.append(.line("\(MenuCopy.lastChangeFailed) \(lastError)"))
        }
        entries.append(.separator)
        entries.append(.item(MenuItem(MenuCopy.keepAwakeSettings, action: .openKeepAwakeSettings)))
        entries.append(.item(MenuItem(MenuCopy.hideTailscaleItem, action: .hideTailscaleMenuBarItem)))
        entries.append(.item(MenuItem(MenuCopy.openTailscale, action: .openTailscale, enabled: tailscale.connection != .notInstalled)))
        entries.append(.separator)
        entries.append(.item(MenuItem(MenuCopy.quit, action: .quit)))
        return entries
    }

    static func tierEntry(_ tier: Tier) -> MenuEntry {
        // Neighborly and Co-op carry other people's traffic, which the ship gates hold back
        // until attestation and the allowlist review work end to end, so only Solo is choosable.
        var children: [MenuEntry] = Tier.allCases.map { option in
            let available = option == .solo
            let title = available ? option.title : "\(option.title), \(MenuCopy.notYetAvailable)"
            return .item(MenuItem(title, enabled: available, checked: option == tier))
        }
        children.append(.line(MenuCopy.tierSummary(tier)))
        children.append(.separator)
        children.append(.item(MenuItem(MenuCopy.tierSettings, action: .openTierSettings)))
        return .item(MenuItem("\(MenuCopy.tierLabel) \(tier.title)", children: children))
    }

    static func agentLine(_ agent: SirvenState.Agent) -> String {
        switch agent.activity {
        case .notConnected: return "\(MenuCopy.agentLabel) \(MenuCopy.agentNotConnected)"
        case .idle: return "\(MenuCopy.agentLabel) \(MenuCopy.agentIdle)"
        case .working:
            guard let task = agent.task, !task.isEmpty else { return "\(MenuCopy.agentLabel) \(MenuCopy.agentWorking)" }
            return "\(MenuCopy.agentLabel) \(MenuCopy.agentWorkingOn) \(task)"
        case .waitingForYou: return "\(MenuCopy.agentLabel) \(withTask(MenuCopy.agentWaiting, agent.task))"
        }
    }

    static func keepAwakeLine(_ keepAwake: SirvenState.KeepAwake, formatTime: (Date) -> String) -> String {
        guard keepAwake.held else { return "\(MenuCopy.keepAwakeLabel) \(MenuCopy.off)" }
        var line = "\(MenuCopy.keepAwakeLabel) \(MenuCopy.on)"
        if let reason = keepAwake.reason, !reason.isEmpty { line += " \(MenuCopy.forTask) \(reason)" }
        if let since = keepAwake.since { line += ", \(MenuCopy.since) \(formatTime(since))" }
        return line
    }

    static func tailscaleEntries(_ snapshot: TailscaleSnapshot) -> [MenuEntry] {
        switch snapshot.connection {
        case .notInstalled:
            return [.line("\(MenuCopy.tailscaleLabel) \(MenuCopy.tailscaleNotInstalled)")]
        case .unavailable(let reason):
            return [.line("\(MenuCopy.tailscaleLabel) \(reason)")]
        case .needsLogin:
            return [
                .line("\(MenuCopy.tailscaleLabel) \(MenuCopy.tailscaleNeedsLogin)"),
                .item(MenuItem(MenuCopy.logInWithTailscale, action: .openTailscale)),
            ]
        case .starting:
            return [.line("\(MenuCopy.tailscaleLabel) \(MenuCopy.tailscaleStarting)")]
        case .disconnected:
            var entries: [MenuEntry] = [.line("\(MenuCopy.tailscaleLabel) \(MenuCopy.tailscaleDisconnected)")]
            if let identity = snapshot.identity { entries.append(deviceEntry(identity)) }
            entries.append(.item(MenuItem(MenuCopy.connect, action: .connect)))
            return entries
        case .connected:
            var entries: [MenuEntry] = [.line("\(MenuCopy.tailscaleLabel) \(MenuCopy.tailscaleConnected)")]
            if let identity = snapshot.identity { entries.append(deviceEntry(identity)) }
            entries.append(exitNodeEntry(snapshot))
            entries.append(.item(MenuItem(MenuCopy.disconnect, action: .disconnect)))
            return entries
        }
    }

    static func deviceEntry(_ identity: TailscaleIdentity) -> MenuEntry {
        var children: [MenuEntry] = []
        if !identity.dnsName.isEmpty {
            children.append(.item(MenuItem("\(MenuCopy.copy) \(identity.dnsName)", action: .copy(identity.dnsName))))
        }
        for address in identity.addresses {
            children.append(.item(MenuItem("\(MenuCopy.copy) \(address)", action: .copy(address))))
        }
        if identity.tailnet != nil || identity.login != nil { children.append(.separator) }
        if let tailnet = identity.tailnet { children.append(.line("\(MenuCopy.tailnetLabel) \(tailnet)")) }
        if let login = identity.login { children.append(.line("\(MenuCopy.signedInAs) \(login)")) }
        return .item(MenuItem("\(MenuCopy.thisDevice) \(identity.hostName)", children: children))
    }

    static func exitNodeEntry(_ snapshot: TailscaleSnapshot) -> MenuEntry {
        let active = snapshot.activeExitNode
        var children: [MenuEntry] = [
            .item(MenuItem(MenuCopy.noExitNode, action: .useExitNode(nil), checked: active == nil)),
        ]
        if snapshot.exitNodes.isEmpty {
            children.append(.line(MenuCopy.noExitNodesOffered))
        } else {
            children.append(.separator)
            for node in snapshot.exitNodes {
                let title = node.online ? node.name : "\(node.name), \(MenuCopy.offline)"
                children.append(.item(MenuItem(title, action: .useExitNode(node.address), enabled: node.online || node.active, checked: node.active)))
            }
        }
        return .item(MenuItem("\(MenuCopy.exitNodeLabel) \(active?.name ?? MenuCopy.none)", children: children))
    }

    private static func withTask(_ base: String, _ task: String?) -> String {
        guard let task, !task.isEmpty else { return base }
        return "\(base): \(task)"
    }

    public static func shortTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        return formatter.string(from: date)
    }

    /// The menu as indented text, for `--print-menu` and the tests. A check mark leads a checked
    /// item, parentheses wrap a disabled one, and a trailing `>` marks a submenu.
    public static func render(_ entries: [MenuEntry], depth: Int = 0) -> String {
        let indent = String(repeating: "    ", count: depth)
        var lines: [String] = []
        for entry in entries {
            switch entry {
            case .heading(let text): lines.append("\(indent)# \(text)")
            case .line(let text): lines.append("\(indent)  \(text)")
            case .separator: lines.append("\(indent)  ---")
            case .item(let item):
                let mark = item.checked ? "\u{2713} " : "  "
                var title = item.enabled ? item.title : "(\(item.title))"
                if !item.children.isEmpty { title += " >" }
                lines.append("\(indent)\(mark)\(title)")
                if !item.children.isEmpty { lines.append(render(item.children, depth: depth + 1)) }
            }
        }
        return lines.joined(separator: "\n")
    }
}
