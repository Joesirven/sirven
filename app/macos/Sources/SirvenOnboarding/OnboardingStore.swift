import Foundation

// where the wizard's result lives: ~/Library/Application Support/sirven/onboarding.json.
// the menu-bar app reads it to decide whether to show the wizard, and to show the tier.
// the runtime's endpoint is read from runtime.json in the same folder once the runtime
// writes one (see docs/DOWNLOAD-AND-ONBOARDING.md, integration seams).
public struct OnboardingStore {
  public let directory: URL

  public init(directory: URL) {
    self.directory = directory
  }

  public static var standard: OnboardingStore {
    let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    return OnboardingStore(directory: support.appendingPathComponent("sirven", isDirectory: true))
  }

  public var resultURL: URL { directory.appendingPathComponent("onboarding.json") }
  public var runtimeURL: URL { directory.appendingPathComponent("runtime.json") }

  public func load() -> OnboardingResult? {
    guard let data = try? Data(contentsOf: resultURL) else { return nil }
    return try? Self.decoder.decode(OnboardingResult.self, from: data)
  }

  public func save(_ result: OnboardingResult) throws {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try Self.encoder.encode(result).write(to: resultURL, options: .atomic)
  }

  public func reset() throws {
    if FileManager.default.fileExists(atPath: resultURL.path) {
      try FileManager.default.removeItem(at: resultURL)
    }
  }

  // nil until the runtime has written its endpoint; the wizard then says so plainly.
  public func runtimeEndpoint() -> String? {
    guard let data = try? Data(contentsOf: runtimeURL),
          let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let endpoint = object["agentEndpoint"] as? String, !endpoint.isEmpty
    else { return nil }
    return endpoint
  }

  private static var encoder: JSONEncoder {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    return encoder
  }

  private static var decoder: JSONDecoder {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return decoder
  }
}
