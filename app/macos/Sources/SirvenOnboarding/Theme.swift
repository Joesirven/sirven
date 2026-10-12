import SwiftUI

// docs/DESIGN-LANGUAGE.md as SwiftUI values: one accent, light product surface, hairline
// cards, and the motion token scale. nothing else in the app picks its own color or timing.
public enum Theme {
  public static let background = Color(red: 0xFD / 255, green: 0xFD / 255, blue: 0xFD / 255)
  public static let stage = Color(red: 0xF9 / 255, green: 0xF9 / 255, blue: 0xF9 / 255)
  public static let text = Color(red: 0x0D / 255, green: 0x0D / 255, blue: 0x0D / 255)
  public static let muted = Color(red: 0x6C / 255, green: 0x6C / 255, blue: 0x6C / 255)
  public static let faint = Color(red: 0x8F / 255, green: 0x8F / 255, blue: 0x8F / 255)
  public static let hairline = Color.black.opacity(0.06)
  public static let accent = Color(red: 0x00 / 255, green: 0x73 / 255, blue: 0xE5 / 255)
  public static let accentHover = Color(red: 0x00 / 255, green: 0x64 / 255, blue: 0xC8 / 255)
  public static let accentTint = Color(red: 0x00 / 255, green: 0x73 / 255, blue: 0xE5 / 255).opacity(0.09)

  public enum Duration {
    public static let stagger = 0.04
    public static let quick = 0.15
    public static let fast = 0.25
    public static let medium = 0.35
  }

  public enum Distance {
    public static let base: CGFloat = 8
    public static let medium: CGFloat = 12
  }

  // smooth-out for entrances, ease-out for exits (closing faster than opening).
  public static func enter(_ duration: Double = Duration.medium) -> Animation {
    .timingCurve(0.22, 1, 0.36, 1, duration: duration)
  }

  public static let exit = Animation.easeOut(duration: Duration.quick)
  public static let swap = Animation.easeInOut(duration: Duration.fast)

  public static let displayFont = Font.system(size: 30, weight: .medium, design: .default)
  public static let bodyFont = Font.system(size: 14)
  public static let labelFont = Font.system(size: 12, weight: .medium)
}

// a white card with a hairline border and the soft layered shadow.
struct Card: ViewModifier {
  var highlighted = false

  func body(content: Content) -> some View {
    content
      .padding(16)
      .background(
        RoundedRectangle(cornerRadius: 14, style: .continuous)
          .fill(highlighted ? Theme.accentTint : Color.white)
      )
      .overlay(
        RoundedRectangle(cornerRadius: 14, style: .continuous)
          .strokeBorder(highlighted ? Theme.accent.opacity(0.5) : Theme.hairline, lineWidth: 1)
      )
      .shadow(color: .black.opacity(0.04), radius: 1.5, y: 1)
  }
}

extension View {
  func card(highlighted: Bool = false) -> some View { modifier(Card(highlighted: highlighted)) }
}

// the pill buttons: one filled primary, one quiet secondary.
struct PillButtonStyle: ButtonStyle {
  var primary = true

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(.system(size: 13, weight: .medium))
      .padding(.horizontal, 18)
      .padding(.vertical, 8)
      .foregroundColor(primary ? .white : Theme.text)
      .background(
        Capsule().fill(primary ? (configuration.isPressed ? Theme.accentHover : Theme.accent) : Color.white)
      )
      .overlay(Capsule().strokeBorder(primary ? Color.clear : Theme.hairline, lineWidth: 1))
      .scaleEffect(configuration.isPressed ? 0.98 : 1)
      .animation(.easeOut(duration: Theme.Duration.quick), value: configuration.isPressed)
  }
}

// the sirven mark: a ring (your connection) holding a dot (your agent). drawn, not an image,
// so the wizard, the menu bar, and the generated app icon are the same shape.
public struct SirvenMark: View {
  public var lineWidth: CGFloat = 2

  public init(lineWidth: CGFloat = 2) {
    self.lineWidth = lineWidth
  }

  public var body: some View {
    GeometryReader { proxy in
      let side = min(proxy.size.width, proxy.size.height)
      ZStack {
        Circle().strokeBorder(lineWidth: lineWidth)
        Circle().frame(width: side * 0.34, height: side * 0.34)
      }
      .frame(width: side, height: side)
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
  }
}

// enter from 8 points of travel and 0.98 scale, softened with opacity; reduced motion keeps
// only the fade.
struct StepTransition {
  static func make(forward: Bool, reduceMotion: Bool) -> AnyTransition {
    if reduceMotion { return .opacity }
    let travel = Theme.Distance.medium * (forward ? 1 : -1)
    return .asymmetric(
      insertion: .opacity.combined(with: .offset(x: travel)).combined(with: .scale(scale: 0.98))
        .animation(Theme.enter()),
      removal: .opacity.combined(with: .offset(x: -travel / 2)).animation(Theme.exit)
    )
  }
}

// staggered entrance for grouped rows: each one 40 milliseconds after the last.
struct Staggered: ViewModifier {
  let index: Int
  @State private var shown = false
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.sirvenStillFrame) private var stillFrame

  func body(content: Content) -> some View {
    let shown = self.shown || stillFrame
    return content
      .opacity(shown ? 1 : 0)
      .offset(y: shown || reduceMotion ? 0 : Theme.Distance.base)
      .onAppear {
        withAnimation(Theme.enter().delay(Theme.Duration.fast + Double(index) * Theme.Duration.stagger)) {
          self.shown = true
        }
      }
  }
}

extension View {
  func staggered(_ index: Int) -> some View { modifier(Staggered(index: index)) }
}

// a still frame renders every view in its settled state, with no entrance pending. used for
// snapshots (Sirven --snapshot), which cannot wait for an animation to run.
private struct StillFrameKey: EnvironmentKey {
  static let defaultValue = false
}

public extension EnvironmentValues {
  var sirvenStillFrame: Bool {
    get { self[StillFrameKey.self] }
    set { self[StillFrameKey.self] = newValue }
  }
}
