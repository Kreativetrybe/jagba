// Draws the app icon: the JaGBa wordmark in bone on a charcoal tile.
// Build with Sources/WordmarkPaths.swift (see tools/make-icon.sh).
import AppKit

let size: CGFloat = 1024
let image = NSImage(size: NSSize(width: size, height: size))
image.lockFocus()
let ctx = NSGraphicsContext.current!.cgContext

// macOS icon grid: an 824 pt rounded square centred on the 1024 canvas.
let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
let soot = CGColor(red: 0x1E / 255, green: 0x1C / 255, blue: 0x1A / 255, alpha: 1)
let raised = CGColor(red: 0x2A / 255, green: 0x27 / 255, blue: 0x24 / 255, alpha: 1)
let bone = CGColor(red: 0xD9 / 255, green: 0xCB / 255, blue: 0xB8 / 255, alpha: 1)
let tilePath = CGPath(roundedRect: tile, cornerWidth: 185, cornerHeight: 185, transform: nil)
ctx.addPath(tilePath)
ctx.clip()
// a soft vertical shade, lighter at the top
let shade = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [raised, soot] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(shade, start: CGPoint(x: 0, y: tile.maxY), end: CGPoint(x: 0, y: tile.minY), options: [])

// Parse the generated "M x y L … Z" paths (y down) into one CGPath per letter.
func parse(_ d: String) -> CGMutablePath {
    let path = CGMutablePath()
    for part in d.split(separator: "Z") {
        let pts = part.replacingOccurrences(of: "M", with: "").split(separator: "L").map { pair -> CGPoint in
            let n = pair.split(separator: " ").compactMap { Double($0) }
            return CGPoint(x: n[0], y: n[1])
        }
        guard let first = pts.first else { continue }
        path.move(to: first)
        pts.dropFirst().forEach { path.addLine(to: $0) }
        path.closeSubpath()
    }
    return path
}

let width: CGFloat = 640
let scale = width / WordmarkPaths.size.width
let height = WordmarkPaths.size.height * scale
ctx.translateBy(x: (size - width) / 2, y: (size + height) / 2)
ctx.scaleBy(x: scale, y: -scale)     // the paths use y down
for d in WordmarkPaths.letters {
    let p = parse(d)
    ctx.addPath(p); ctx.setStrokeColor(soot); ctx.setLineWidth(9); ctx.setLineJoin(.round); ctx.strokePath()
    ctx.addPath(p); ctx.setFillColor(bone); ctx.fillPath()
}
image.unlockFocus()

let rep = NSBitmapImageRep(data: image.tiffRepresentation!)!
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
