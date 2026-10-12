import SwiftUI

// the wizard: three steps and a confirmation, one window, lots of space.
public struct OnboardingView: View {
  @ObservedObject var model: OnboardingModel
  let onDone: (OnboardingResult) -> Void
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  public init(model: OnboardingModel, onDone: @escaping (OnboardingResult) -> Void) {
    self.model = model
    self.onDone = onDone
  }

  public static let size = CGSize(width: 600, height: 560)

  public var body: some View {
    VStack(spacing: 0) {
      ProgressDots(step: model.step)
        .padding(.top, 28)

      ZStack {
        stepView
          .id(model.step)
          .transition(StepTransition.make(forward: model.movingForward, reduceMotion: reduceMotion))
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
      .padding(.horizontal, 48)
      .padding(.top, 28)

      footer
        .padding(.horizontal, 48)
        .padding(.bottom, 28)
    }
    .frame(width: Self.size.width, height: Self.size.height)
    .background(Theme.background)
    .foregroundColor(Theme.text)
    .preferredColorScheme(.light)
  }

  @ViewBuilder
  private var stepView: some View {
    switch model.step {
    case .welcome: WelcomeStep(copy: model.copy.welcome)
    case .tier: TierStep(model: model)
    case .permissions: PermissionsStep(model: model)
    case .confirmation: ConfirmationStep(model: model)
    }
  }

  private var footer: some View {
    HStack {
      if model.canGoBack {
        Button(model.copy.navigation.back) { withAnimation(Theme.swap) { model.back() } }
          .buttonStyle(PillButtonStyle(primary: false))
          .transition(.opacity)
      }
      Spacer()
      Button(primaryLabel) {
        if model.step == .confirmation {
          onDone(model.result())
        } else {
          withAnimation(Theme.swap) { model.next() }
        }
      }
      .buttonStyle(PillButtonStyle())
      .keyboardShortcut(.defaultAction)
    }
    .animation(Theme.swap, value: model.canGoBack)
  }

  private var primaryLabel: String {
    switch model.step {
    case .welcome: return model.copy.welcome.next
    case .tier: return model.copy.tier.next
    case .permissions: return model.copy.permissions.next
    case .confirmation: return model.copy.confirmation.done
    }
  }
}

// three dots for the three steps; the confirmation fills them all.
struct ProgressDots: View {
  let step: OnboardingStep

  var body: some View {
    HStack(spacing: 8) {
      ForEach(OnboardingStep.steps, id: \.rawValue) { each in
        Capsule()
          .fill(each.rawValue <= step.rawValue ? Theme.accent : Theme.hairline)
          .frame(width: each == step ? 22 : 6, height: 6)
      }
    }
    .animation(Theme.enter(Theme.Duration.fast), value: step)
    .accessibilityElement()
    .accessibilityLabel(step == .confirmation ? "Setup complete" : "Step \(step.rawValue + 1) of \(OnboardingStep.steps.count)")
  }
}

struct StepHeader: View {
  let title: String
  let body_: String

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text(title).font(Theme.displayFont).tracking(-0.2)
      Text(body_).font(Theme.bodyFont).foregroundColor(Theme.muted)
        .fixedSize(horizontal: false, vertical: true)
    }
  }
}

struct WelcomeStep: View {
  let copy: OnboardingCopy.Welcome
  @State private var breathing = false
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    VStack(alignment: .leading, spacing: 36) {
      Spacer(minLength: 24)
      SirvenMark(lineWidth: 3)
        .foregroundColor(Theme.accent)
        .frame(width: 72, height: 72)
        .scaleEffect(breathing ? 1 : 0.96)
        .onAppear {
          guard !reduceMotion else { return }
          withAnimation(.easeInOut(duration: 2.4).repeatForever(autoreverses: true)) { breathing = true }
        }
        .accessibilityHidden(true)
      StepHeader(title: copy.title, body_: copy.body)
      Spacer()
    }
  }
}

struct TierStep: View {
  @ObservedObject var model: OnboardingModel

  var body: some View {
    let copy = model.copy.tier
    VStack(alignment: .leading, spacing: 24) {
      StepHeader(title: copy.title, body_: copy.body)
      VStack(spacing: 10) {
        ForEach(Array(copy.options.enumerated()), id: \.element.id) { index, option in
          TierCard(option: option, badge: copy.unavailableBadge, selected: model.tier == option.id) {
            withAnimation(Theme.swap) { _ = model.choose(option.id) }
          }
          .staggered(index)
        }
      }
    }
  }
}

struct TierCard: View {
  let option: OnboardingCopy.TierOption
  let badge: String
  let selected: Bool
  let choose: () -> Void

  var body: some View {
    Button(action: choose) {
      HStack(alignment: .top, spacing: 14) {
        Circle()
          .strokeBorder(selected ? Theme.accent : Theme.faint.opacity(0.6), lineWidth: selected ? 5 : 1.5)
          .frame(width: 16, height: 16)
          .padding(.top, 2)
        VStack(alignment: .leading, spacing: 6) {
          HStack(spacing: 8) {
            Text(option.name).font(.system(size: 15, weight: .medium))
            if !option.available {
              Text(badge)
                .font(Theme.labelFont)
                .foregroundColor(Theme.muted)
                .padding(.horizontal, 8).padding(.vertical, 2)
                .background(Capsule().fill(Theme.stage))
            }
          }
          if selected || option.available {
            Text(option.summary).font(Theme.bodyFont).foregroundColor(Theme.muted)
              .fixedSize(horizontal: false, vertical: true)
          }
          // bandwidth lent and autonomy travel together, so they sit on one line.
          HStack(spacing: 6) {
            Text(option.lends)
            Text("·").foregroundColor(Theme.faint)
            Text(option.autonomy)
          }
          .font(Theme.labelFont)
          .foregroundColor(selected ? Theme.accent : Theme.faint)
          if !option.available {
            Text(option.unavailableNote).font(.system(size: 12)).foregroundColor(Theme.faint)
          }
        }
        Spacer(minLength: 0)
      }
      .contentShape(Rectangle())
      .card(highlighted: selected)
      .opacity(option.available ? 1 : 0.62)
    }
    .buttonStyle(.plain)
    .disabled(!option.available)
    .accessibilityAddTraits(selected ? .isSelected : [])
  }
}

struct PermissionsStep: View {
  @ObservedObject var model: OnboardingModel

  var body: some View {
    let copy = model.copy.permissions
    VStack(alignment: .leading, spacing: 24) {
      StepHeader(title: copy.title, body_: copy.body)
      VStack(spacing: 10) {
        ForEach(Array(copy.items.enumerated()), id: \.element.id) { index, item in
          PermissionRow(item: item, state: model.state(of: item.id), copy: copy) {
            Task { await model.request(item.id) }
          }
          .staggered(index)
        }
      }
      VStack(alignment: .leading, spacing: 4) {
        Text(copy.notAskedTitle).font(Theme.labelFont).foregroundColor(Theme.muted)
        Text(copy.notAskedBody).font(.system(size: 12)).foregroundColor(Theme.faint)
          .fixedSize(horizontal: false, vertical: true)
      }
      .staggered(copy.items.count)
    }
  }
}

struct PermissionRow: View {
  let item: OnboardingCopy.PermissionItem
  let state: PermissionState
  let copy: OnboardingCopy.PermissionsStep
  let request: () -> Void

  var body: some View {
    HStack(alignment: .center, spacing: 16) {
      VStack(alignment: .leading, spacing: 4) {
        Text(item.name).font(.system(size: 15, weight: .medium))
        Text(item.why).font(Theme.bodyFont).foregroundColor(Theme.muted)
          .fixedSize(horizontal: false, vertical: true)
      }
      Spacer(minLength: 8)
      ZStack {
        switch state {
        case .notAsked:
          Button(copy.allow, action: request).buttonStyle(PillButtonStyle(primary: false))
        case .allowed:
          Label(copy.allowed, systemImage: "checkmark").foregroundColor(Theme.accent)
        case .declined:
          Text(copy.declined).foregroundColor(Theme.faint)
        }
      }
      .font(Theme.labelFont)
      .transition(.opacity.combined(with: .scale(scale: 0.96)))
      .animation(Theme.enter(Theme.Duration.fast), value: state)
    }
    .card()
  }
}

struct ConfirmationStep: View {
  @ObservedObject var model: OnboardingModel

  var body: some View {
    let copy = model.copy.confirmation
    VStack(alignment: .leading, spacing: 22) {
      Text(copy.title).font(Theme.displayFont).tracking(-0.2)
      VStack(alignment: .leading, spacing: 8) {
        ForEach(Array(model.facts.enumerated()), id: \.offset) { index, fact in
          HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: "checkmark").font(.system(size: 11, weight: .semibold)).foregroundColor(Theme.accent)
            Text(fact).font(Theme.bodyFont).fixedSize(horizontal: false, vertical: true)
          }
          .staggered(index)
        }
      }
      MenuBarPreview(copy: copy)
        .staggered(model.facts.count + 1)
    }
  }
}

// introduces the menu-bar app: a strip of menu bar with the sirven mark, and the menu
// opening from it (origin-aware, from the mark down).
struct MenuBarPreview: View {
  let copy: OnboardingCopy.Confirmation
  @State private var opened = false
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.sirvenStillFrame) private var stillFrame

  var body: some View {
    let open = opened || stillFrame
    return VStack(alignment: .leading, spacing: 10) {
      VStack(alignment: .leading, spacing: 2) {
        Text(copy.menuBarTitle).font(.system(size: 15, weight: .medium))
        Text(copy.menuBarBody).font(.system(size: 12)).foregroundColor(Theme.muted)
      }
      HStack(alignment: .top, spacing: 16) {
        VStack(alignment: .trailing, spacing: 0) {
          HStack(spacing: 10) {
            Spacer()
            ForEach(0..<3) { _ in Capsule().fill(Theme.hairline).frame(width: 14, height: 5) }
            SirvenMark(lineWidth: 1.5).frame(width: 12, height: 12)
              .foregroundColor(open ? Theme.accent : Theme.text)
          }
          .padding(.horizontal, 10)
          .frame(height: 22)
          .background(Theme.stage)
          .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))

          VStack(alignment: .leading, spacing: 7) {
            ForEach(copy.menuBarItems) { item in
              HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(item.name).font(Theme.labelFont).frame(width: 72, alignment: .leading)
                Text(item.detail).font(.system(size: 12)).foregroundColor(Theme.muted)
              }
            }
          }
          .padding(12)
          .frame(width: 380, alignment: .leading)
          .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.white))
          .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.hairline))
          .shadow(color: .black.opacity(0.06), radius: 14, y: 4)
          .padding(.top, 6)
          .scaleEffect(open || reduceMotion ? 1 : 0.97, anchor: .topTrailing)
          .opacity(open ? 1 : 0)
        }
      }
    }
    .onAppear {
      withAnimation(Theme.enter(Theme.Duration.medium).delay(0.6)) { opened = true }
    }
  }
}
