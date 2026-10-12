import Foundation

public enum Tier: String, Codable, CaseIterable {
  case solo, neighborly, coop
}

public enum Permission: String, Codable, CaseIterable {
  case notifications, openAtLogin
}

public enum PermissionState: String, Codable {
  case notAsked, allowed, declined
}

// Jose's bar: connecting a personal agent is two or three steps plus a confirmation. the
// three steps are welcome, tier, and permissions; the confirmation states what is now true.
// the privileged helper is deliberately absent: it asks lazily, on first need.
public enum OnboardingStep: Int, CaseIterable {
  case welcome, tier, permissions, confirmation

  public static let steps: [OnboardingStep] = allCases.filter { $0 != .confirmation }
}

// what the wizard leaves behind for the menu-bar app and the runtime to read.
public struct OnboardingResult: Codable, Equatable {
  public static let currentVersion = 1

  public let version: Int
  public let completedAt: Date
  public let tier: Tier
  public let notifications: PermissionState
  public let openAtLogin: PermissionState
}

@MainActor
public final class OnboardingModel: ObservableObject {
  @Published public private(set) var step: OnboardingStep = .welcome
  // set when the step changes, so the views can slide the right way.
  @Published public private(set) var movingForward = true
  // Solo is the default and, until the ship gates clear, the only tier that can be chosen.
  @Published public private(set) var tier: Tier = .solo
  @Published public private(set) var permissions: [Permission: PermissionState] = [:]

  public let copy: OnboardingCopy
  public let endpoint: String?
  private let broker: PermissionBroker
  private let now: () -> Date

  public init(copy: OnboardingCopy, broker: PermissionBroker, endpoint: String?, now: @escaping () -> Date = Date.init) {
    self.copy = copy
    self.broker = broker
    self.endpoint = endpoint
    self.now = now
    for permission in Permission.allCases { permissions[permission] = broker.state(of: permission) }
  }

  public var stepNumber: Int { step.rawValue + 1 }

  public var canGoBack: Bool { step != .welcome && step != .confirmation }

  public func next() {
    guard let following = OnboardingStep(rawValue: step.rawValue + 1) else { return }
    movingForward = true
    step = following
  }

  public func back() {
    guard canGoBack, let previous = OnboardingStep(rawValue: step.rawValue - 1) else { return }
    movingForward = false
    step = previous
  }

  public func isAvailable(_ tier: Tier) -> Bool {
    copy.tier.options.first { $0.id == tier }?.available ?? false
  }

  // returns false, and changes nothing, for a tier that is not open yet.
  @discardableResult
  public func choose(_ tier: Tier) -> Bool {
    guard isAvailable(tier) else { return false }
    self.tier = tier
    return true
  }

  public func state(of permission: Permission) -> PermissionState {
    permissions[permission] ?? .notAsked
  }

  public func request(_ permission: Permission) async {
    permissions[permission] = await broker.request(permission)
  }

  // the confirmation, one plain sentence per fact, built from the real state rather than
  // from what the user was hoping for.
  public var facts: [String] {
    let text = copy.confirmation.facts
    var lines = [text.solo, text.asks]
    lines.append(state(of: .notifications) == .allowed ? text.notificationsOn : text.notificationsOff)
    lines.append(state(of: .openAtLogin) == .allowed ? text.openAtLoginOn : text.openAtLoginOff)
    if let endpoint {
      lines.append(text.endpoint.replacingOccurrences(of: "{endpoint}", with: endpoint))
    } else {
      lines.append(text.endpointPending)
    }
    return lines
  }

  public func result() -> OnboardingResult {
    OnboardingResult(
      version: OnboardingResult.currentVersion,
      completedAt: now(),
      tier: tier,
      notifications: state(of: .notifications),
      openAtLogin: state(of: .openAtLogin)
    )
  }
}
