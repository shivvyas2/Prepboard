import SwiftUI

/// Shared native color and component tokens.
extension Color {
    init(hex: UInt32) {
        self.init(red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
    }
}

/// Cool white surfaces, cobalt for actions and selection, orange for what needs attention now (matches the web app).
enum PB {
    // Neutral white base: a light gray page so pure-white cards stand out
    static let bg = Color(hex: 0xF4F5F7)
    static let bg2 = Color(hex: 0xEFF1F4)
    static let surface = Color(hex: 0xF6F7F9)
    static let card = Color(hex: 0xFFFFFF)
    static let ink = Color(hex: 0x15171C)
    static let ink2 = Color(hex: 0x474D5A)
    static let muted = Color(hex: 0x6A7080)
    static let line = Color(hex: 0xE8EAEE)
    static let line2 = Color(hex: 0xD8DBE1)
    // Accents. `sun` is the orange accent: badges, "now" and highlights.
    static let cobalt = Color(hex: 0x1E4FE0)
    static let cobaltSoft = Color(hex: 0xE9EFFD)
    static let sun = Color(hex: 0xE8590C)       // deep orange: badges, "now", time left
    static let sunSoft = Color(hex: 0xFDEBDD)
    static let onSun = Color.white
    static let sunInk = Color(hex: 0xB4470F)   // orange text on light backgrounds
    static let red = Color(hex: 0xD1343B)
    static let redSoft = Color(hex: 0xFDE8E8)
    static let green = Color(hex: 0x1F8A5B)
    static let greenSoft = Color(hex: 0xE3F4EC)
    static let shadow = Color(hex: 0x1A2233)

    static let rXL: CGFloat = 28, rLG: CGFloat = 20, rMD: CGFloat = 14

    /// 8-point grid. Spacing and padding use these steps (4 is the half step for tight pairs).
    static let s1: CGFloat = 4, s2: CGFloat = 8, s3: CGFloat = 12, s4: CGFloat = 16, s6: CGFloat = 24, s8: CGFloat = 32, s12: CGFloat = 48
    /// Minimum tap target (Apple HIG): 44 pt on touch screens; the Mac uses a pointer.
    #if os(iOS)
    static let minTap: CGFloat = 44
    static func controlHeight(compact: Bool) -> CGFloat { compact ? 44 : 48 }
    #else
    static let minTap: CGFloat = 0
    static func controlHeight(compact: Bool) -> CGFloat { compact ? 32 : 40 }
    #endif

    static var background: some View {
        LinearGradient(colors: [bg, bg2], startPoint: .top, endPoint: .bottom).ignoresSafeArea()
    }
}

extension Font {
    static let pbDisplay = Font.system(size: 40, weight: .bold).width(.standard)
    static let pbLabel = Font.system(size: 11, weight: .semibold)
    static let pbMono = Font.system(size: 11, weight: .medium, design: .monospaced)
}

struct CardModifier: ViewModifier {
    var padding: CGFloat = 20
    var fill: Color = PB.card
    var radius: CGFloat = PB.rXL
    func body(content: Content) -> some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: radius, style: .continuous).fill(fill))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(PB.line))
            .shadow(color: PB.shadow.opacity(0.05), radius: 12, y: 4)
    }
}

extension View {
    func pbCard(padding: CGFloat = 24, fill: Color = PB.card, radius: CGFloat = PB.rXL) -> some View {
        modifier(CardModifier(padding: padding, fill: fill, radius: radius))
    }
    func pbLabelStyle() -> some View {
        font(.pbLabel).kerning(0.9).textCase(.uppercase).foregroundStyle(PB.muted)
    }
}

struct PillButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    var filled = true
    var compact = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: compact ? 13 : 14, weight: filled ? .semibold : .medium))
            .lineLimit(1)
            .padding(.horizontal, compact ? 16 : 24)
            .frame(height: PB.controlHeight(compact: compact))
            .foregroundStyle(filled ? Color.white : PB.ink2)
            .background(Capsule().fill(filled ? PB.cobalt : PB.card))
            .overlay(Capsule().strokeBorder(filled ? Color.clear : PB.line2))
            .contentShape(Capsule())
            .opacity(isEnabled ? 1 : 0.45)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

struct CircleIconButton: View {
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovering = false
    let systemImage: String
    var size: CGFloat = 44
    var active = false
    var label: String = ""
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: size * 0.38, weight: .regular))
                .frame(width: size, height: size)
                .foregroundStyle(active ? Color.white : hovering ? PB.ink : PB.ink2)
                .background(Circle().fill(active ? PB.cobalt : hovering ? PB.surface : PB.card))
                .overlay(Circle().strokeBorder(active ? PB.cobalt : hovering ? PB.line2 : PB.line))
                .shadow(color: PB.cobalt.opacity(active ? 0.28 : 0), radius: 8, y: 4)
                // Touch: at least 44 pt to tap, even when the circle is drawn smaller.
                .contentShape(Rectangle().inset(by: -max(0, PB.minTap - size) / 2))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .opacity(isEnabled ? 1 : 0.4)
        .accessibilityLabel(label.isEmpty ? systemImage : label)
        .help(label)
    }
}

/// Square checkbox (no switches) — matches the web app.
struct CheckboxToggleStyle: ToggleStyle {
    var inverted = false
    /// Show the toggle's label beside the box (the whole row is the tap target).
    var labeled = false
    func makeBody(configuration: Configuration) -> some View {
        if labeled {
            Button { configuration.isOn.toggle() } label: {
                HStack(spacing: 8) {
                    box(configuration)
                    configuration.label.font(.system(size: 14, weight: .medium)).foregroundStyle(PB.ink).fixedSize(horizontal: false, vertical: true)
                }
                .frame(minHeight: 32)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(configuration.isOn ? [.isSelected] : [])
        } else {
            Button { configuration.isOn.toggle() } label: { box(configuration) }
                .buttonStyle(.plain)
                .accessibilityLabel("Done")
                .accessibilityAddTraits(configuration.isOn ? [.isSelected] : [])
        }
    }

    private func box(_ configuration: Configuration) -> some View {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(configuration.isOn ? (inverted ? PB.sun : PB.cobalt) : Color.clear)
                .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(inverted ? (configuration.isOn ? PB.sun : Color.white) : (configuration.isOn ? PB.cobalt : PB.ink2), lineWidth: 1.5))
                .overlay {
                    if configuration.isOn {
                        Image(systemName: "checkmark").font(.system(size: 11, weight: .bold))
                            .foregroundStyle(inverted ? PB.onSun : Color.white)
                    }
                }
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
                .animation(.easeOut(duration: 0.12), value: configuration.isOn)
    }
}

struct Chip: View {
    let text: String
    var style: Style = .plain
    enum Style { case plain, dark, red }
    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .padding(.horizontal, 12).padding(.vertical, 4)
            .foregroundStyle(style == .plain ? PB.ink2 : .white)
            .background(RoundedRectangle(cornerRadius: 8).fill(style == .dark ? PB.cobalt : style == .red ? PB.red : PB.surface))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(style == .plain ? PB.line : .clear))
    }
}

struct ProgressBar: View {
    let value: Double
    var inverted = false
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(inverted ? Color.white.opacity(0.18) : PB.surface)
                Capsule().fill(inverted ? PB.sun : PB.cobalt).frame(width: max(0, geo.size.width * value))
            }
        }
        .frame(height: 8)
        .overlay(Capsule().strokeBorder(inverted ? .clear : PB.line))
        .accessibilityElement()
        .accessibilityLabel("Progress")
        .accessibilityValue("\(Int(value * 100)) percent")
    }
}

struct PBTextField: View {
    let label: String
    @Binding var text: String
    var axis: Axis = .horizontal
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).pbLabelStyle()
            TextField(label, text: $text, axis: axis)
                .textFieldStyle(.plain)
                .lineLimit(axis == .vertical ? 4...12 : 1...1)
                .padding(.horizontal, 12).padding(.vertical, 12)
                .background(RoundedRectangle(cornerRadius: 12).fill(PB.surface))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(PB.line))
        }
    }
}

extension Date {
    var pbShort: String { formatted(.dateTime.month(.abbreviated).day()) }
    var pbDay: String { formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()) }
    @MainActor var pbFull: String {
        "\(formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())), \(TimeFmt.hm(self)) \(formatted(.dateTime.timeZone()))"
    }
}

// MARK: - Sheets that fit the window

private struct WindowSizeKey: EnvironmentKey { static let defaultValue: CGSize = .zero }
extension EnvironmentValues {
    /// The main window's content size, so sheets can stay inside it. Zero until measured.
    var pbWindowSize: CGSize {
        get { self[WindowSizeKey.self] }
        set { self[WindowSizeKey.self] = newValue }
    }
}

/// Sizes a sheet to its ideal size but never larger than the window it opens over, so its close and Done buttons
/// stay on screen in a small window. Content taller than that should scroll.
private struct SheetFrame: ViewModifier {
    @Environment(\.pbWindowSize) private var window
    var minWidth: CGFloat, idealWidth: CGFloat, minHeight: CGFloat, idealHeight: CGFloat
    func body(content: Content) -> some View {
        #if os(macOS)
        let maxW = window.width > 0 ? max(320, window.width - 48) : .infinity
        let maxH = window.height > 0 ? max(300, window.height - 48) : .infinity
        content.frame(minWidth: min(minWidth, maxW), idealWidth: min(idealWidth, maxW), maxWidth: maxW,
                      minHeight: min(minHeight, maxH), idealHeight: min(idealHeight, maxH), maxHeight: maxH)
        #else
        content
        #endif
    }
}

extension View {
    func pbSheetFrame(minWidth: CGFloat = 420, idealWidth: CGFloat, minHeight: CGFloat = 360, idealHeight: CGFloat) -> some View {
        modifier(SheetFrame(minWidth: minWidth, idealWidth: idealWidth, minHeight: minHeight, idealHeight: idealHeight))
    }
}
