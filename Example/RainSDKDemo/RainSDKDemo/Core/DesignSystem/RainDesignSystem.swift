import SwiftUI
import PhosphorSwift

// The Rain SDK demo design system — tokens and components per
// `rain-sdk-demo-design-system.md` (dark product surface, direction 3b).
//
// Rules baked in here so screens can't drift:
// - Pink is state and identity, never an ink. No gradients, no glows.
// - Uniform 1px hairline borders in the neutral ramp; shadows only for true overlays.
// - Three type sizes per screen, Helvetica Neue Light/Semibold only.
// - Interactive elements are radius-full; cards/tiles 20; nested info blocks 4.
// - Sentence case everywhere; no emoji — glyphs are Phosphor Regular in one flat color.

// MARK: - Color

extension Color {
  static let rainInk         = Color(hex: 0x121212)
  static let rainSurface     = Color(hex: 0x161719)
  static let rainSurfaceAlt  = Color(hex: 0x1C1C1F)
  static let rainBorder      = Color(hex: 0x303030)
  static let rainTextPrimary = Color.white
  static let rainTextBody    = Color(hex: 0xCABDDD)
  /// Text-safe muted (4.5:1 on ink). Never use `rainIconMuted` for text.
  static let rainTextMuted   = Color(hex: 0x9A93A6)
  /// Icons/chevrons/bullet dots only (4.01:1 on ink) — not for text.
  static let rainIconMuted   = Color(hex: 0x787185)
  static let rainAccent      = Color(hex: 0xFF2FB6)
  static let rainAccentPress = Color(hex: 0xC41385)
  static let rainSuccess     = Color(hex: 0x00B87B)
  static let rainWarn        = Color(hex: 0xFF8A3D)
  static let rainDanger      = Color(hex: 0xFF262A)
  static let rainFocusHalo   = Color(red: 1, green: 47 / 255, blue: 182 / 255, opacity: 0.12)
  static let rainDangerWash  = Color(red: 1, green: 38 / 255, blue: 42 / 255, opacity: 0.10)

  init(hex: UInt32) {
    self.init(
      .sRGB,
      red: Double((hex >> 16) & 0xFF) / 255,
      green: Double((hex >> 8) & 0xFF) / 255,
      blue: Double(hex & 0xFF) / 255
    )
  }
}

// MARK: - Type

enum RainFont {
  private static func custom(_ weight: Font.Weight, size: CGFloat) -> Font {
    Font.custom("Helvetica Neue", size: size).weight(weight)
  }

  static let title = custom(.semibold, size: 24) // tracking -0.72
  static let label = custom(.semibold, size: 16) // tracking -0.16
  static let body  = custom(.light, size: 16)    // tracking -0.16
  static let meta  = custom(.light, size: 12)
  static let micro = custom(.semibold, size: 12) // section labels
}

// MARK: - Metrics & motion

enum RainMetrics {
  static let s1: CGFloat = 8
  static let s2: CGFloat = 16
  static let s3: CGFloat = 24
  static let s4: CGFloat = 32
  static let rSmall: CGFloat = 4   // nested info blocks only
  static let rLarge: CGFloat = 20  // cards, tiles, sheets
  static let control: CGFloat = 48
  static let hairline: CGFloat = 1
}

enum RainMotion {
  static let base = Animation.timingCurve(0.2, 0.8, 0.2, 1, duration: 0.2)
}

// MARK: - Icons (Phosphor Regular, one flat color)

/// Semantic icon names → Phosphor glyphs, per the design-system emoji-replacement table.
/// Single point of truth: adding a glyph anywhere in the app goes through a case here.
enum RainIcon {
  case walletQR        // was 💳 → qr-code
  case balances        // was 💰 → wallet
  case sendTokens      // was 📤 → paper-plane-tilt
  case withdraw        // was 🏦 → bank
  case authPull        // was 🔐 → lock-simple
  case history         // was 📜 → clock-counter-clockwise
  case copy            // was 📋
  case valid           // was ✅ → check-circle
  case invalid         // was ❌ → x-circle
  case info            // was ℹ️
  case star            // was ⭐
  case nativeToken     // was ⛰️/💎 → cube
  case refresh         // was 🔄 / SF arrow.clockwise → arrow-clockwise
  case viewExternal    // was 🔎 → arrow-square-out
  case tokenRow        // was 🪙 → coin
  case sendToken       // was 🔗 → coins
  case withdrawAction  // was 🔓 → lock-simple-open
  case prepared        // was 📝 → note-pencil
  case fee             // was ⛽ → gas-pump
  case caretDown
  case arrowLeft
  case arrowRight

  private var ph: Ph {
    switch self {
    case .walletQR: .qrCode
    case .balances: .wallet
    case .sendTokens: .paperPlaneTilt
    case .withdraw: .bank
    case .authPull: .lockSimple
    case .history: .clockCounterClockwise
    case .copy: .copy
    case .valid: .checkCircle
    case .invalid: .xCircle
    case .info: .info
    case .star: .star
    case .nativeToken: .cube
    case .refresh: .arrowClockwise
    case .viewExternal: .arrowSquareOut
    case .tokenRow: .coin
    case .sendToken: .coins
    case .withdrawAction: .lockSimpleOpen
    case .prepared: .notePencil
    case .fee: .gasPump
    case .caretDown: .caretDown
    case .arrowLeft: .arrowLeft
    case .arrowRight: .arrowRight
    }
  }

  /// Sizes per context: 22 feature tiles, 20 rows, 16 chevrons/inline marks.
  @ViewBuilder
  func view(size: CGFloat, color: Color) -> some View {
    ph.regular
      .renderingMode(.template)
      .resizable()
      .scaledToFit()
      .frame(width: size, height: size)
      .foregroundStyle(color)
  }
}

// MARK: - Surfaces

struct RainCardModifier: ViewModifier {
  func body(content: Content) -> some View {
    content
      .padding(RainMetrics.s2)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(Color.rainSurface)
      .clipShape(RoundedRectangle(cornerRadius: RainMetrics.rLarge, style: .continuous))
      .overlay(
        RoundedRectangle(cornerRadius: RainMetrics.rLarge, style: .continuous)
          .stroke(Color.rainBorder, lineWidth: RainMetrics.hairline)
      )
  }
}

extension View {
  func rainCard() -> some View { modifier(RainCardModifier()) }
}

/// Card with a sentence-case section title (16 Semibold) and 16-gap content.
struct RainSectionCard<Content: View>: View {
  let title: String
  @ViewBuilder let content: Content

  var body: some View {
    VStack(alignment: .leading, spacing: RainMetrics.s2) {
      Text(title)
        .font(RainFont.label)
        .tracking(-0.16)
        .foregroundStyle(Color.rainTextPrimary)
      content
    }
    .rainCard()
  }
}

/// Nested info block: radius 4, `surfaceAlt` fill, no border.
struct RainInfoBlock<Content: View>: View {
  var title: String?
  @ViewBuilder let content: Content

  var body: some View {
    VStack(alignment: .leading, spacing: RainMetrics.s1) {
      if let title {
        Text(title)
          .font(RainFont.micro)
          .tracking(-0.12)
          .foregroundStyle(Color.rainTextMuted)
      }
      content
    }
    .padding(RainMetrics.s2)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(Color.rainSurfaceAlt)
    .clipShape(RoundedRectangle(cornerRadius: RainMetrics.rSmall, style: .continuous))
  }
}

/// Warning note: meta size in the warn tone on the nested-block fill. For a missing precondition
/// the user can fix, not a failure.
struct RainWarningNote: View {
  let text: String

  var body: some View {
    Text(text)
      .font(RainFont.meta)
      .lineSpacing(3)
      .foregroundStyle(Color.rainWarn)
      .padding(RainMetrics.s2)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(Color.rainSurfaceAlt)
      .clipShape(RoundedRectangle(cornerRadius: RainMetrics.rSmall, style: .continuous))
  }
}

/// Error banner: danger wash, no border, code text kept verbatim.
struct RainErrorBanner: View {
  let text: String

  var body: some View {
    Text(text)
      .font(RainFont.body)
      .tracking(-0.16)
      .lineSpacing(4)
      .foregroundStyle(Color.rainDanger)
      .padding(RainMetrics.s2)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(Color.rainDangerWash)
      .clipShape(RoundedRectangle(cornerRadius: RainMetrics.rLarge, style: .continuous))
  }
}

// MARK: - Text roles

/// 12 Semibold muted section label (sentence case).
struct RainSectionLabel: View {
  let text: String
  var body: some View {
    Text(text)
      .font(RainFont.micro)
      .tracking(-0.12)
      .foregroundStyle(Color.rainTextMuted)
  }
}

/// Status log line: `Status: …`, 12 Light muted, no card.
struct RainStatusLog: View {
  let text: String
  var body: some View {
    Text("Status: \(text)")
      .font(RainFont.meta)
      .tracking(-0.12)
      .foregroundStyle(Color.rainTextMuted)
      .frame(maxWidth: .infinity, alignment: .leading)
  }
}

// MARK: - Status pill

struct RainStatusPill: View {
  let text: String
  var active: Bool = true

  var body: some View {
    Text(text)
      .font(RainFont.micro)
      .tracking(-0.12)
      .foregroundStyle(active ? Color.white : Color.rainTextMuted)
      .padding(.vertical, 4)
      .padding(.horizontal, 12)
      .background(active ? Color.rainAccent : Color.rainSurface)
      .clipShape(Capsule())
      .overlay(
        Capsule().stroke(active ? .clear : Color.rainBorder, lineWidth: RainMetrics.hairline)
      )
  }
}

// MARK: - Buttons

struct RainPrimaryButtonStyle: ButtonStyle {
  @Environment(\.isEnabled) private var isEnabled

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(RainFont.label)
      .tracking(-0.16)
      .foregroundStyle(isEnabled ? Color.white : Color.rainTextMuted)
      .frame(maxWidth: .infinity, minHeight: RainMetrics.control)
      .background(
        isEnabled
          ? (configuration.isPressed ? Color.rainAccentPress : Color.rainAccent)
          : Color.rainSurface
      )
      .clipShape(Capsule())
      .animation(RainMotion.base, value: configuration.isPressed)
  }
}

struct RainSecondaryButtonStyle: ButtonStyle {
  @Environment(\.isEnabled) private var isEnabled

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(RainFont.label)
      .tracking(-0.16)
      .foregroundStyle(
        isEnabled
          ? (configuration.isPressed ? Color.rainAccent : Color.rainTextPrimary)
          : Color.rainTextMuted
      )
      .frame(maxWidth: .infinity, minHeight: RainMetrics.control)
      .background(isEnabled ? Color.clear : Color.rainSurface)
      .clipShape(Capsule())
      .overlay(
        Capsule().stroke(
          isEnabled
            ? (configuration.isPressed ? Color.rainAccent : Color.rainIconMuted)
            : Color.clear,
          lineWidth: RainMetrics.hairline
        )
      )
      .animation(RainMotion.base, value: configuration.isPressed)
  }
}

struct RainDestructiveButtonStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(RainFont.label)
      .tracking(-0.16)
      .foregroundStyle(Color.rainDanger)
      .frame(maxWidth: .infinity, minHeight: RainMetrics.control)
      .overlay(
        Capsule().stroke(
          configuration.isPressed ? Color.rainDanger : Color.rainBorder,
          lineWidth: RainMetrics.hairline
        )
      )
      .animation(RainMotion.base, value: configuration.isPressed)
  }
}

/// Async action button with the standard keyboard-dismiss + spinner behavior.
struct RainAsyncButton: View {
  enum Kind { case primary, secondary, destructive }

  let title: String
  var kind: Kind = .primary
  var enabled: Bool = true
  /// External loading override — normally omitted: the button tracks its own in-flight action,
  /// so only the tapped button spins while the others are merely disabled (via `enabled`).
  var isLoading: Bool = false
  let action: () async -> Void

  /// True while this button's own action is in flight; drives the spinner.
  @State private var isRunning = false

  var body: some View {
    Button {
      hideKeyboard()
      Task {
        isRunning = true
        await action()
        isRunning = false
      }
    } label: {
      HStack(spacing: RainMetrics.s1) {
        if isLoading || isRunning {
          ProgressView()
            .progressViewStyle(CircularProgressViewStyle(tint: spinnerTint))
        }
        Text(title)
      }
    }
    .modifier(RainButtonKindModifier(kind: kind))
    .disabled(!enabled || isRunning)
  }

  private var spinnerTint: Color {
    kind == .primary && enabled ? .white : .rainTextMuted
  }
}

private struct RainButtonKindModifier: ViewModifier {
  let kind: RainAsyncButton.Kind

  func body(content: Content) -> some View {
    switch kind {
    case .primary: content.buttonStyle(RainPrimaryButtonStyle())
    case .secondary: content.buttonStyle(RainSecondaryButtonStyle())
    case .destructive: content.buttonStyle(RainDestructiveButtonStyle())
    }
  }
}

// MARK: - Input field

struct RainLabeledField: View {
  let title: String
  let placeholder: String
  @Binding var text: String
  @FocusState private var focused: Bool

  var body: some View {
    VStack(alignment: .leading, spacing: RainMetrics.s1) {
      RainSectionLabel(text: title)
      TextField("", text: $text, prompt: Text(placeholder).foregroundStyle(Color.rainTextMuted))
        .font(RainFont.body)
        .tracking(-0.16)
        .foregroundStyle(Color.rainTextPrimary)
        .tint(Color.rainAccent)
        .textInputAutocapitalization(.never)
        .disableAutocorrection(true)
        .focused($focused)
        .padding(.horizontal, 20)
        .frame(minHeight: RainMetrics.control)
        .background(Color.rainSurface)
        .clipShape(Capsule())
        .overlay(
          Capsule().stroke(
            focused ? Color.rainAccent : Color.rainBorder,
            lineWidth: RainMetrics.hairline
          )
        )
        .background(
          Capsule()
            .stroke(Color.rainFocusHalo, lineWidth: focused ? 3 : 0)
            .padding(-2)
        )
        .animation(RainMotion.base, value: focused)
    }
  }
}

// MARK: - Segmented tabs

struct RainSegmentedTabs<Item: Hashable & Identifiable>: View {
  let items: [Item]
  @Binding var selection: Item
  let title: (Item) -> String
  var isDisabled: Bool = false

  var body: some View {
    HStack(spacing: 0) {
      ForEach(items) { item in
        Button {
          withAnimation(RainMotion.base) { selection = item }
        } label: {
          // 12 Semibold (micro), not 16: four segments share one row, and the longer labels
          // ("Portal MPC", "Rain Wallet") must fit without scaling artifacts. Micro is the
          // sanctioned small size, and it matches the status pill's text.
          Text(title(item))
            .font(RainFont.micro)
            .tracking(-0.12)
            .lineLimit(1)
            .minimumScaleFactor(0.85)
            .foregroundStyle(selection == item ? Color.white : Color.rainTextMuted)
            .padding(.vertical, 12)
            .padding(.horizontal, 4)
            .frame(maxWidth: .infinity)
            .background(selection == item ? Color.rainAccent : Color.clear)
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
      }
    }
    .padding(4)
    .background(Color.rainSurface)
    .clipShape(Capsule())
    .overlay(Capsule().stroke(Color.rainBorder, lineWidth: RainMetrics.hairline))
    .disabled(isDisabled)
    .opacity(isDisabled ? 0.6 : 1)
  }
}

// MARK: - Feature tile

struct RainFeatureTile<Destination: View>: View {
  let icon: RainIcon
  let title: String
  @ViewBuilder let destination: () -> Destination
  @State private var pressed = false

  var body: some View {
    NavigationLink(destination: destination()) {
      VStack(alignment: .leading, spacing: RainMetrics.s2) {
        icon.view(size: 22, color: .rainAccent)
        Text(title)
          .font(RainFont.label)
          .tracking(-0.16)
          .foregroundStyle(Color.rainTextPrimary)
          .multilineTextAlignment(.leading)
      }
      .frame(maxWidth: .infinity, minHeight: 96, alignment: .topLeading)
      .padding(RainMetrics.s2)
      .background(Color.rainSurface)
      .clipShape(RoundedRectangle(cornerRadius: RainMetrics.rLarge, style: .continuous))
      .overlay(
        RoundedRectangle(cornerRadius: RainMetrics.rLarge, style: .continuous)
          .stroke(pressed ? Color.rainAccent : Color.rainBorder, lineWidth: RainMetrics.hairline)
      )
    }
    .buttonStyle(.plain)
    .simultaneousGesture(
      DragGesture(minimumDistance: 0)
        .onChanged { _ in withAnimation(RainMotion.base) { pressed = true } }
        .onEnded { _ in withAnimation(RainMotion.base) { pressed = false } }
    )
  }
}

// MARK: - Selector row

/// Menu-picker face: surface pill, value left, caret right.
struct RainSelectorRow<Label: View>: View {
  @ViewBuilder let label: Label

  var body: some View {
    HStack {
      label
        .font(RainFont.label)
        .tracking(-0.16)
        .foregroundStyle(Color.rainTextPrimary)
      Spacer()
      RainIcon.caretDown.view(size: 16, color: .rainIconMuted)
    }
    .padding(.vertical, RainMetrics.s2)
    .padding(.horizontal, 20)
    .background(Color.rainSurface)
    .clipShape(Capsule())
    .overlay(Capsule().stroke(Color.rainBorder, lineWidth: RainMetrics.hairline))
  }
}

// MARK: - Screen scaffold

/// Ink canvas + standard screen padding. Apply to every screen's outermost content.
struct RainScreen: ViewModifier {
  func body(content: Content) -> some View {
    content
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .background(Color.rainInk.ignoresSafeArea())
      .preferredColorScheme(.dark)
      .tint(Color.rainAccent)
  }
}

extension View {
  func rainScreen() -> some View { modifier(RainScreen()) }
}
