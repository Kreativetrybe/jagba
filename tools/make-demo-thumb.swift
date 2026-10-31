// Draws tools/demo-thumb.png: an abstract "video frame" in the JAGBA palette,
// used as the sample thumbnail in screenshots (no real video's artwork).
import AppKit
let w: CGFloat = 1280, h: CGFloat = 720
let img = NSImage(size: NSSize(width: w, height: h))
img.lockFocus()
let ctx = NSGraphicsContext.current!.cgContext
func c(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}
let bg = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [c(0x2B2622), c(0x141210)] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(bg, start: CGPoint(x: 0, y: h), end: CGPoint(x: w, y: 0), options: [])
// a speaker's silhouette at a desk, lit warm from the left
ctx.setFillColor(c(0xA8392A, 0.9)); ctx.fillEllipse(in: CGRect(x: 760, y: 330, width: 210, height: 210))
ctx.setFillColor(c(0x1E1C1A)); ctx.fillEllipse(in: CGRect(x: 790, y: 360, width: 150, height: 150))
let body = CGMutablePath(); body.move(to: CGPoint(x: 660, y: 120)); body.addCurve(to: CGPoint(x: 1070, y: 120), control1: CGPoint(x: 700, y: 330), control2: CGPoint(x: 1030, y: 330)); body.closeSubpath()
ctx.addPath(body); ctx.setFillColor(c(0x1E1C1A)); ctx.fillPath()
ctx.setFillColor(c(0x8A6633)); ctx.fill(CGRect(x: 0, y: 0, width: w, height: 124))
// lower-third caption bars
ctx.setFillColor(c(0xD9CBB8)); ctx.fill(CGRect(x: 90, y: 200, width: 420, height: 38))
ctx.setFillColor(c(0xD2B48C, 0.7)); ctx.fill(CGRect(x: 90, y: 160, width: 300, height: 22))
// soft light streaks
for i in 0..<5 {
    ctx.setFillColor(c(0xD9CBB8, 0.05 + 0.02 * CGFloat(i)))
    ctx.fill(CGRect(x: 120 + CGFloat(i) * 70, y: 300, width: 34, height: 360))
}
img.unlockFocus()
let rep = NSBitmapImageRep(data: img.tiffRepresentation!)!
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
