import Foundation
import ServiceManagement
import UserNotifications

// the seam between the wizard and the system prompts. the wizard never asks for anything
// itself; it asks a broker, so tests and the demo run against a fake.
@MainActor
public protocol PermissionBroker {
  func state(of permission: Permission) -> PermissionState
  func request(_ permission: Permission) async -> PermissionState
}

// the real prompts. notifications go through the system's own prompt; open at login
// registers the app itself as a login item, which macOS announces in its own notification.
// neither is the privileged helper, which registers lazily on first need.
@MainActor
public final class SystemPermissionBroker: PermissionBroker {
  private var known: [Permission: PermissionState] = [:]

  public init() {
    known[.openAtLogin] = SMAppService.mainApp.status == .enabled ? .allowed : .notAsked
  }

  public func state(of permission: Permission) -> PermissionState {
    known[permission] ?? .notAsked
  }

  public func request(_ permission: Permission) async -> PermissionState {
    let result: PermissionState
    switch permission {
    case .notifications:
      let granted = (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])) ?? false
      result = granted ? .allowed : .declined
    case .openAtLogin:
      do {
        try SMAppService.mainApp.register()
        result = .allowed
      } catch {
        result = .declined
      }
    }
    known[permission] = result
    return result
  }
}

// test data: answers every request with the scripted state, and records what was asked.
@MainActor
public final class FakePermissionBroker: PermissionBroker {
  public private(set) var requested: [Permission] = []
  private let answers: [Permission: PermissionState]

  public init(answers: [Permission: PermissionState] = [.notifications: .allowed, .openAtLogin: .allowed]) {
    self.answers = answers
  }

  public func state(of permission: Permission) -> PermissionState { .notAsked }

  public func request(_ permission: Permission) async -> PermissionState {
    requested.append(permission)
    return answers[permission] ?? .declined
  }
}
