import AppKit
// PrepBoard mark: soft-black timeline spine + burnt-orange bowl forming a "P",
// with a checked box as the counter and a sun "now" dot on the timeline.
func c(_ h: UInt32, _ a: CGFloat = 1) -> CGColor { CGColor(red: CGFloat((h>>16)&255)/255, green: CGFloat((h>>8)&255)/255, blue: CGFloat(h&255)/255, alpha: a) }
let S: CGFloat = 1024
let out = CommandLine.arguments[1]
let full = CommandLine.arguments.count > 2 && CommandLine.arguments[2] == "full"  // full-bleed for iOS
let cs = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(data: nil, width: Int(S), height: Int(S), bitsPerComponent: 8, bytesPerRow: 0, space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
ctx.translateBy(x: 0, y: S); ctx.scaleBy(x: 1, y: -1) // top-left origin
let tile = full ? CGRect(x: 0, y: 0, width: S, height: S) : CGRect(x: 100, y: 100, width: 824, height: 824)
let tilePath = CGPath(roundedRect: tile, cornerWidth: full ? 0 : 186, cornerHeight: full ? 0 : 186, transform: nil)
if !full { ctx.saveGState(); ctx.setShadow(offset: CGSize(width: 0, height: 14), blur: 28, color: c(0x3C2D14, 0.28)); ctx.addPath(tilePath); ctx.setFillColor(c(0xF6EFE3)); ctx.fillPath(); ctx.restoreGState() }
ctx.saveGState(); ctx.addPath(tilePath); ctx.clip()
let g = CGGradient(colorsSpace: cs, colors: [c(0xFBF6EC), c(0xEFE6D6)] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(g, start: CGPoint(x: 0, y: tile.minY), end: CGPoint(x: 0, y: tile.maxY), options: [])
ctx.restoreGState()
// Geometry (centered optically)
let sx: CGFloat = 318, sw: CGFloat = 116, top: CGFloat = 262, bottom: CGFloat = 770
let bh: CGFloat = 316, br = bh/2, bx1: CGFloat = 712
// Bowl (burnt orange): rect from stem to bx1-br + right semicircle
let bowl = CGMutablePath()
bowl.move(to: CGPoint(x: sx + sw/2, y: top))
bowl.addLine(to: CGPoint(x: bx1 - br, y: top))
bowl.addArc(center: CGPoint(x: bx1 - br, y: top + br), radius: br, startAngle: -.pi/2, endAngle: .pi/2, clockwise: false)
bowl.addLine(to: CGPoint(x: sx + sw/2, y: top + bh))
bowl.closeSubpath()
ctx.addPath(bowl); ctx.setFillColor(c(0xC4561C)); ctx.fillPath()
// Spine (soft black)
ctx.addPath(CGPath(roundedRect: CGRect(x: sx, y: top, width: sw, height: bottom - top), cornerWidth: sw/2, cornerHeight: sw/2, transform: nil))
ctx.setFillColor(c(0x1E1B18)); ctx.fillPath()
// Counter = ivory checkbox with soft-black check
let cb: CGFloat = 132, ccx: CGFloat = 560, ccy = top + br
ctx.addPath(CGPath(roundedRect: CGRect(x: ccx - cb/2, y: ccy - cb/2, width: cb, height: cb), cornerWidth: 30, cornerHeight: 30, transform: nil))
ctx.setFillColor(c(0xFBF6EC)); ctx.fillPath()
ctx.setStrokeColor(c(0x1E1B18)); ctx.setLineWidth(22); ctx.setLineCap(.round); ctx.setLineJoin(.round)
ctx.move(to: CGPoint(x: ccx - 34, y: ccy + 2)); ctx.addLine(to: CGPoint(x: ccx - 8, y: ccy + 28)); ctx.addLine(to: CGPoint(x: ccx + 36, y: ccy - 26)); ctx.strokePath()
// Timeline ticks on the spine below the bowl + sun "now" dot
ctx.setFillColor(c(0xFBF6EC, 0.9))
for y in [628.0, 700.0] as [CGFloat] { ctx.addPath(CGPath(roundedRect: CGRect(x: sx + 30, y: y - 6, width: sw - 60, height: 12), cornerWidth: 6, cornerHeight: 6, transform: nil)); ctx.fillPath() }
ctx.setFillColor(c(0xF7C744)); ctx.fillEllipse(in: CGRect(x: sx + sw + 36, y: 599, width: 58, height: 58))
let img = ctx.makeImage()!
let rep = NSBitmapImageRep(cgImage: img)
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
