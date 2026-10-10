import SwiftUI

/// A Claude-style spark (radiating rounded rays in Claude's terracotta).
/// Drawn in code as a stand-in; replace with the official mark from Anthropic's brand assets if you have it.
struct ClaudeMark: View {
    var color = Color(hex: 0xD97757)

    var body: some View {
        Canvas { ctx, size in
            let c = CGPoint(x: size.width / 2, y: size.height / 2)
            let r: CGFloat = min(size.width, size.height) / 2
            let style = StrokeStyle(lineWidth: r * 0.2, lineCap: .round)
            for i in 0..<12 {
                let even = i.isMultiple(of: 2)
                let angle: CGFloat = CGFloat(i) / 12 * 2 * .pi + (even ? 0 : 0.08)
                let outer: CGFloat = r * (even ? 1.0 : 0.78)
                let inner: CGFloat = r * 0.16
                let dx = cos(angle), dy = sin(angle)
                var p = Path()
                p.move(to: CGPoint(x: c.x + dx * inner, y: c.y + dy * inner))
                p.addLine(to: CGPoint(x: c.x + dx * outer, y: c.y + dy * outer))
                ctx.stroke(p, with: .color(color), style: style)
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityLabel("Claude")
    }
}
