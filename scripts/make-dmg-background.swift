// DMG window background (660x440) with the first-launch steps.
import AppKit
let w: CGFloat = 660, h: CGFloat = 440
let img = NSImage(size: NSSize(width: w, height: h))
img.lockFocus()
NSGradient(starting: NSColor(red: 0.02, green: 0.10, blue: 0.16, alpha: 1), ending: NSColor(red: 0.03, green: 0.30, blue: 0.36, alpha: 1))!
    .draw(in: NSRect(x: 0, y: 0, width: w, height: h), angle: 45)
func text(_ s: String, _ y: CGFloat, _ size: CGFloat, _ weight: NSFont.Weight = .regular, alpha: CGFloat = 1) {
    let p = NSMutableParagraphStyle(); p.alignment = .center
    (s as NSString).draw(in: NSRect(x: 30, y: y, width: w - 60, height: size * 3),
        withAttributes: [.font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: NSColor.white.withAlphaComponent(alpha), .paragraphStyle: p])
}
text("Drag Sonar to Applications", 380, 20, .semibold)
text("→", 255, 40, .light, alpha: 0.8)
text("If macOS blocks it: System Settings → Privacy & Security → scroll down → Open Anyway.", 120, 12, alpha: 0.9)
text("Sonar is not notarized (no Apple Developer ID). You install it at your own risk.", 98, 11, alpha: 0.7)
img.unlockFocus()
let rep = NSBitmapImageRep(data: img.tiffRepresentation!)!
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
