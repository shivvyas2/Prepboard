import SwiftUI

/// The PrepBoard mark: a soft-black timeline spine and a burnt-orange bowl forming a "P",
/// a checked box as the counter, and a sun "now" dot. Same geometry as brand/render_icon.swift.
struct PrepBoardMark: View {
    static let ink = Color(hex: 0x1E1B18)
    static let orange = Color(hex: 0xC4561C)
    static let ivory = Color(hex: 0xFBF6EC)

    var body: some View {
        Canvas { ctx, size in
            // Mark occupies 318…712 × 262…770 of the 1024 icon grid; fit that box into `size`.
            let box = CGRect(x: 300, y: 252, width: 424, height: 528)
            let k = min(size.width / box.width, size.height / box.height)
            ctx.translateBy(x: (size.width - box.width * k) / 2, y: (size.height - box.height * k) / 2)
            ctx.scaleBy(x: k, y: k)
            ctx.translateBy(x: -box.minX, y: -box.minY)

            let sx: CGFloat = 318, sw: CGFloat = 116, top: CGFloat = 262, bottom: CGFloat = 770
            let bh: CGFloat = 316, br = bh / 2, bx1: CGFloat = 712
            var bowl = Path()
            bowl.move(to: CGPoint(x: sx + sw / 2, y: top))
            bowl.addLine(to: CGPoint(x: bx1 - br, y: top))
            bowl.addArc(center: CGPoint(x: bx1 - br, y: top + br), radius: br, startAngle: .degrees(-90), endAngle: .degrees(90), clockwise: false)
            bowl.addLine(to: CGPoint(x: sx + sw / 2, y: top + bh))
            bowl.closeSubpath()
            ctx.fill(bowl, with: .color(Self.orange))
            ctx.fill(Path(roundedRect: CGRect(x: sx, y: top, width: sw, height: bottom - top), cornerRadius: sw / 2), with: .color(Self.ink))

            let cb: CGFloat = 132, ccx: CGFloat = 560, ccy = top + br
            ctx.fill(Path(roundedRect: CGRect(x: ccx - cb / 2, y: ccy - cb / 2, width: cb, height: cb), cornerRadius: 30), with: .color(Self.ivory))
            var check = Path()
            check.move(to: CGPoint(x: ccx - 34, y: ccy + 2))
            check.addLine(to: CGPoint(x: ccx - 8, y: ccy + 28))
            check.addLine(to: CGPoint(x: ccx + 36, y: ccy - 26))
            ctx.stroke(check, with: .color(Self.ink), style: StrokeStyle(lineWidth: 22, lineCap: .round, lineJoin: .round))

            for y: CGFloat in [628, 700] {
                ctx.fill(Path(roundedRect: CGRect(x: sx + 30, y: y - 6, width: sw - 60, height: 12), cornerRadius: 6), with: .color(Self.ivory.opacity(0.9)))
            }
            ctx.fill(Path(ellipseIn: CGRect(x: sx + sw + 36, y: 599, width: 58, height: 58)), with: .color(PB.sun))
        }
        .accessibilityLabel("PrepBoard")
    }
}

/// The mark on its ivory tile, as used for the app icon.
struct PrepBoardLogo: View {
    var size: CGFloat = 44

    var body: some View {
        PrepBoardMark()
            .padding(size * 0.2)
            .frame(width: size, height: size)
            .background(
                RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
                    .fill(LinearGradient(colors: [Color(hex: 0xFBF6EC), Color(hex: 0xEFE6D6)], startPoint: .top, endPoint: .bottom))
            )
            .overlay(RoundedRectangle(cornerRadius: size * 0.26, style: .continuous).strokeBorder(PB.line2))
    }
}
