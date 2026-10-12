import Foundation

// every word the wizard shows comes from copy/onboarding-wizard.json, so Jose's review is
// one read. this file only gives that JSON a shape.
public struct OnboardingCopy: Decodable, Equatable {
  public struct Welcome: Decodable, Equatable {
    public let title: String
    public let body: String
    public let next: String
  }

  public struct TierOption: Decodable, Equatable, Identifiable {
    public let id: Tier
    public let name: String
    public let summary: String
    public let lends: String
    public let autonomy: String
    public let available: Bool
    public let unavailableNote: String
  }

  public struct TierStep: Decodable, Equatable {
    public let title: String
    public let body: String
    public let unavailableBadge: String
    public let options: [TierOption]
    public let next: String
  }

  public struct PermissionItem: Decodable, Equatable, Identifiable {
    public let id: Permission
    public let name: String
    public let why: String
  }

  public struct PermissionsStep: Decodable, Equatable {
    public let title: String
    public let body: String
    public let allow: String
    public let allowed: String
    public let declined: String
    public let items: [PermissionItem]
    public let notAskedTitle: String
    public let notAskedBody: String
    public let next: String
  }

  public struct Facts: Decodable, Equatable {
    public let solo: String
    public let asks: String
    public let notificationsOn: String
    public let notificationsOff: String
    public let openAtLoginOn: String
    public let openAtLoginOff: String
    public let endpoint: String
    public let endpointPending: String
  }

  public struct MenuBarItem: Decodable, Equatable, Identifiable {
    public let name: String
    public let detail: String
    public var id: String { name }
  }

  public struct Confirmation: Decodable, Equatable {
    public let title: String
    public let facts: Facts
    public let menuBarTitle: String
    public let menuBarBody: String
    public let menuBarItems: [MenuBarItem]
    public let done: String
  }

  public struct Navigation: Decodable, Equatable {
    public let back: String
    public let stepLabel: String
  }

  public let welcome: Welcome
  public let tier: TierStep
  public let permissions: PermissionsStep
  public let confirmation: Confirmation
  public let navigation: Navigation

  public static func load(from url: URL) throws -> OnboardingCopy {
    try JSONDecoder().decode(OnboardingCopy.self, from: Data(contentsOf: url))
  }

  public static let fileName = "onboarding-wizard"
}
