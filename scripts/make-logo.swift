// Draws logo/sonar.png (1024x1024): a radar sweep with rings and a ping blip on a deep teal gradient.
import AppKit
import CoreGraphics
let size: CGFloat = 1024
let cs = CGColorSpaceCreateDeviceRGB()
let ctx = CGContext(data: nil, width: Int(size), height: Int(size), bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
func c(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor { CGColor(red: r, green: g, blue: b, alpha: a) }
// Background gradient
let bg = CGGradient(colorsSpace: cs, colors: [c(0.02, 0.10, 0.16), c(0.03, 0.30, 0.36)] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(bg, start: CGPoint(x: 0, y: size), end: CGPoint(x: size, y: 0), options: [])
let center = CGPoint(x: size / 2, y: size / 2)
// Rings
ctx.setLineWidth(10)
for (i, r) in [130.0, 250.0, 370.0].enumerated() {
    ctx.setStrokeColor(c(0.35, 0.95, 0.85, 0.55 - CGFloat(i) * 0.13))
    ctx.addArc(center: center, radius: r, startAngle: 0, endAngle: .pi * 2, clockwise: false)
    ctx.strokePath()
}
// Sweep wedge with fading gradient
ctx.saveGState()
let start = CGFloat.pi * 0.25, end = CGFloat.pi * 0.62
ctx.move(to: center)
ctx.addArc(center: center, radius: 400, startAngle: start, endAngle: end, clockwise: false)
ctx.closePath()
ctx.clip()
let sweep = CGGradient(colorsSpace: cs, colors: [c(0.30, 1.0, 0.85, 0.0), c(0.30, 1.0, 0.85, 0.55)] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(sweep, start: CGPoint(x: center.x + 400 * cos(end), y: center.y + 400 * sin(end)),
                       end: CGPoint(x: center.x + 400 * cos(start), y: center.y + 400 * sin(start)), options: [])
ctx.restoreGState()
// Sweep edge
ctx.setStrokeColor(c(0.55, 1.0, 0.9, 0.95)); ctx.setLineWidth(12); ctx.setLineCap(.round)
ctx.move(to: center); ctx.addLine(to: CGPoint(x: center.x + 390 * cos(start), y: center.y + 390 * sin(start))); ctx.strokePath()
// Center and blip
ctx.setFillColor(c(0.55, 1.0, 0.9)); ctx.fillEllipse(in: CGRect(x: center.x - 26, y: center.y - 26, width: 52, height: 52))
let blip = CGPoint(x: center.x + 250 * cos(0.55), y: center.y + 250 * sin(0.55))
for (r, a) in [(70.0, 0.18), (44.0, 0.35)] {
    ctx.setFillColor(c(1, 1, 1, CGFloat(a))); ctx.fillEllipse(in: CGRect(x: blip.x - r, y: blip.y - r, width: r * 2, height: r * 2))
}
ctx.setFillColor(c(1, 1, 1)); ctx.fillEllipse(in: CGRect(x: blip.x - 24, y: blip.y - 24, width: 48, height: 48))
let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
