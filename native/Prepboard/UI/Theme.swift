import SwiftUI

/// Light, minimal palette (matches the web app).
extension Color {
    init(hex: UInt32) {
        self.init(red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
    }
}

/// Warm beige base with cobalt blue accents and sun yellow highlights (matches the web app).
enum PB {
    // Warm beige base
    static let bg = Color(hex: 0xEFE9DF)
    static let bg2 = Color(hex: 0xE9E1D3)
    static let surface = Color(hex: 0xF7F2EA)
    static let card = Color(hex: 0xFFFDF9)
    static let ink = Color(hex: 0x1D1A16)
    static let ink2 = Color(hex: 0x4F4A42)
    static let muted = Color(hex: 0x8C8579)
    static let line = Color(hex: 0xE7DFD2)
    static let line2 = Color(hex: 0xD9CFBF)
    // Accents
    static let cobalt = Color(hex: 0x1F4FD8)
    static let cobaltSoft = Color(hex: 0xE5EBFB)
    static let sun = Color(hex: 0xF7C744)
    static let sunSoft = Color(hex: 0xEBDCAF)   // sand yellow
    static let onSun = Color(hex: 0x2B2410)
    static let red = Color(hex: 0xC2410C)

    static let rXL: CGFloat = 28, rLG: CGFloat = 20, rMD: CGFloat = 14

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
            .shadow(color: Color(hex: 0x3C2D14).opacity(0.07), radius: 14, y: 8)
    }
}

extension View {
    func pbCard(padding: CGFloat = 20, fill: Color = PB.card, radius: CGFloat = PB.rXL) -> some View {
        modifier(CardModifier(padding: padding, fill: fill, radius: radius))
    }
    func pbLabelStyle() -> some View {
        font(.pbLabel).kerning(0.9).textCase(.uppercase).foregroundStyle(PB.muted)
    }
}

struct PillButtonStyle: ButtonStyle {
    var filled = true
    var compact = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: compact ? 13 : 14, weight: filled ? .semibold : .medium))
            .padding(.horizontal, compact ? 14 : 20)
            .frame(height: compact ? 34 : 44)
            .foregroundStyle(filled ? Color.white : PB.ink2)
            .background(Capsule().fill(filled ? PB.cobalt : Color.clear))
            .overlay(Capsule().strokeBorder(filled ? Color.clear : PB.line2))
            .contentShape(Capsule())
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

struct CircleIconButton: View {
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
                .foregroundStyle(active ? Color.white : PB.ink2)
                .background(Circle().fill(active ? PB.cobalt : PB.card))
                .overlay(Circle().strokeBorder(active ? PB.cobalt : PB.line))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label.isEmpty ? systemImage : label)
        .help(label)
    }
}

/// Square checkbox (no switches) — matches the web app.
struct CheckboxToggleStyle: ToggleStyle {
    var inverted = false
    func makeBody(configuration: Configuration) -> some View {
        Button { configuration.isOn.toggle() } label: {
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
        .buttonStyle(.plain)
        .accessibilityLabel("Done")
        .accessibilityAddTraits(configuration.isOn ? [.isSelected] : [])
    }
}

struct Chip: View {
    let text: String
    var style: Style = .plain
    enum Style { case plain, dark, red }
    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .padding(.horizontal, 10).padding(.vertical, 4)
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
                .padding(.horizontal, 12).padding(.vertical, 10)
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
