// Draws the images for the README and the download page from the app's own
// screens (run ./tools/snapshots.sh first). Run from the repo root:
//   swift tools/make-readme-images.swift
// Writes docs/screens/hero.png (the app in a Mac window), step-1…4.png (one
// crop per onboarding step) and how-it-works.png (all four steps, for the README).
import AppKit

let screens = "build/screens/", out = "docs/screens/"
try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)
for f in ["CourierPrime-Regular.ttf", "CourierPrime-Bold.ttf"] {
    CTFontManagerRegisterFontsForURL(URL(fileURLWithPath: "Resources/Fonts/" + f) as CFURL, .process, nil)
}

func hex(_ s: String, _ a: CGFloat = 1) -> NSColor {
    let v = Int(s.dropFirst(), radix: 16)!
    return NSColor(srgbRed: CGFloat(v >> 16 & 255) / 255, green: CGFloat(v >> 8 & 255) / 255, blue: CGFloat(v & 255) / 255, alpha: a)
}
let page = hex("#161513"), soot = hex("#1E1C1A"), bone = hex("#D9CBB8"), bright = hex("#EDE2D3")
let butter = hex("#D2B48C"), muted = hex("#8F8373"), red = hex("#A8392A")

func screen(_ name: String) -> CGImage {
    NSImage(contentsOfFile: screens + name + ".png")!.cgImage(forProposedRect: nil, context: nil, hints: nil)!
}
func crop(_ name: String, _ x0: Int, _ y0: Int, _ x1: Int, _ y1: Int) -> CGImage {
    screen(name).cropping(to: CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0))!
}

/// Draws into a w×h PNG with y pointing down.
func draw(_ path: String, _ w: Int, _ h: Int, _ body: (CGContext) -> Void) {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!.cgContext
    ctx.translateBy(x: 0, y: CGFloat(h)); ctx.scaleBy(x: 1, y: -1)
    NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
    body(ctx)
    NSGraphicsContext.current = nil
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
    print("wrote", path, w, "x", h)
}
/// Draws an image upright into a y-down rect, with rounded corners and a hairline edge.
func place(_ ctx: CGContext, _ img: CGImage, _ r: CGRect, radius: CGFloat, edge: Bool = true) {
    ctx.saveGState()
    ctx.addPath(CGPath(roundedRect: r, cornerWidth: radius, cornerHeight: radius, transform: nil)); ctx.clip()
    ctx.translateBy(x: r.minX, y: r.maxY); ctx.scaleBy(x: 1, y: -1)
    ctx.interpolationQuality = .high
    ctx.draw(img, in: CGRect(x: 0, y: 0, width: r.width, height: r.height))
    ctx.restoreGState()
    if edge {
        ctx.addPath(CGPath(roundedRect: r.insetBy(dx: 1, dy: 1), cornerWidth: radius, cornerHeight: radius, transform: nil))
        ctx.setStrokeColor(bone.withAlphaComponent(0.12).cgColor); ctx.setLineWidth(2); ctx.strokePath()
    }
}
/// Draws text wrapped to a width; returns its height.
@discardableResult
func text(_ s: String, _ font: NSFont, _ color: NSColor, at p: CGPoint, width: CGFloat, spacing: CGFloat = 0, kern: CGFloat = 0) -> CGFloat {
    let style = NSMutableParagraphStyle(); style.lineSpacing = spacing
    let str = NSAttributedString(string: s, attributes: [.font: font, .foregroundColor: color, .paragraphStyle: style, .kern: kern])
    let h = ceil(str.boundingRect(with: CGSize(width: width, height: 10_000), options: [.usesLineFragmentOrigin, .usesFontLeading]).height)
    str.draw(with: CGRect(x: p.x, y: p.y, width: width, height: h), options: [.usesLineFragmentOrigin, .usesFontLeading])
    return h
}
func glow(_ ctx: CGContext, at c: CGPoint, radius: CGFloat, _ color: NSColor) {
    let g = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [color.cgColor, color.withAlphaComponent(0).cgColor] as CFArray, locations: [0, 1])!
    ctx.drawRadialGradient(g, startCenter: c, startRadius: 0, endCenter: c, endRadius: radius, options: [])
}

// --- 1. Hero: the app mid-clip, in a Mac window --------------------------------------------
let heroShot = crop("2-clip-video", 0, 0, 1760, 1600)
let pad: CGFloat = 120, win = CGRect(x: pad, y: pad, width: 1760, height: 1600)
draw(out + "hero.png", Int(win.width + 2 * pad), Int(win.height + 2 * pad)) { ctx in
    // Transparent around the window, so it floats on any page (dark site, light GitHub).
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: 34), blur: 90, color: NSColor.black.withAlphaComponent(0.6).cgColor)
    ctx.addPath(CGPath(roundedRect: win, cornerWidth: 26, cornerHeight: 26, transform: nil)); ctx.setFillColor(soot.cgColor); ctx.fillPath()
    ctx.restoreGState()
    place(ctx, heroShot, win, radius: 26)
    // traffic lights (the app hides its title bar, so they sit over the content)
    for (i, c) in ["#FF5F57", "#FEBC2E", "#28C840"].enumerated() {
        ctx.setFillColor(hex(c).cgColor)
        ctx.fillEllipse(in: CGRect(x: win.minX + 30 + CGFloat(i) * 40, y: win.minY + 26, width: 24, height: 24))
    }
}

// --- 2. The four onboarding steps ------------------------------------------------------------
struct Step { let title: String; let body: String; let img: CGImage }
let steps = [
    Step(title: "Paste a link",
         body: "Copy a link from YouTube, TikTok, Instagram, X or Vimeo and paste it in. Got a pile of them? Paste several at once.",
         img: crop("1-welcome", 160, 140, 1600, 730)),
    Step(title: "Choose what to save",
         body: "Video, Audio (MP3 or M4A), Transcript (.txt and .srt), or Whole post: every slide of an Instagram carousel.",
         img: crop("6-instagram", 0, 700, 1760, 1110)),
    Step(title: "Pick the part you need",
         body: "Drag the handles or type the times. JAGBA downloads only that part, not the whole video. Play clip shows exactly what you'll get.",
         img: crop("2-clip-video", 0, 800, 1760, 1200)),
    Step(title: "Download",
         body: "Files land in your Downloads folder. Open them, or show them in Finder. Queue up as many as you like.",
         img: crop("2-clip-video", 0, 1366, 1760, 2010)),
]

// One image per step for the download page (its CSS rounds the corners).
for (i, s) in steps.enumerated() {
    draw(out + "step-\(i + 1).png", s.img.width, s.img.height) { ctx in
        place(ctx, s.img, CGRect(x: 0, y: 0, width: s.img.width, height: s.img.height), radius: 0, edge: false)
    }
}

// All four as one onboarding image for the README: text on the left, screen on the right.
let W: CGFloat = 2400, margin: CGFloat = 90, textW: CGFloat = 620, imgX = margin + textW + 90, imgW = W - imgX - margin
let mono = NSFont(name: "CourierPrime-Regular", size: 34) ?? .monospacedSystemFont(ofSize: 34, weight: .regular)
let monoSmall = NSFont(name: "CourierPrime-Regular", size: 28) ?? .monospacedSystemFont(ofSize: 28, weight: .regular)
let titleFont = NSFont.systemFont(ofSize: 54, weight: .semibold), bodyFont = NSFont.systemFont(ofSize: 33, weight: .regular)
let rowGap: CGFloat = 70, headerH: CGFloat = 150
let rowHeights = steps.map { CGFloat($0.img.height) * imgW / CGFloat($0.img.width) }
let H = headerH + rowHeights.reduce(0, +) + rowGap * CGFloat(steps.count) + margin
draw(out + "how-it-works.png", Int(W), Int(H)) { ctx in
    ctx.setFillColor(page.cgColor); ctx.fill(CGRect(x: 0, y: 0, width: W, height: H))
    glow(ctx, at: CGPoint(x: W * 0.8, y: H * 0.3), radius: 1300, red.withAlphaComponent(0.16))
    text("HOW IT WORKS", monoSmall, muted, at: CGPoint(x: margin, y: margin - 10), width: 800, kern: 5)
    var y = headerH
    for (i, s) in steps.enumerated() {
        let h = rowHeights[i]
        if i > 0 {
            ctx.setFillColor(bone.withAlphaComponent(0.10).cgColor)
            ctx.fill(CGRect(x: margin, y: y - rowGap / 2, width: W - 2 * margin, height: 2))
        }
        var ty = y + 6
        ty += text(String(format: "%02d", i + 1), mono, butter, at: CGPoint(x: margin, y: ty), width: textW) + 14
        ty += text(s.title, titleFont, bright, at: CGPoint(x: margin, y: ty), width: textW) + 16
        text(s.body, bodyFont, muted, at: CGPoint(x: margin, y: ty), width: textW, spacing: 8)
        place(ctx, s.img, CGRect(x: imgX, y: y, width: imgW, height: h), radius: 18)
        y += h + rowGap
    }
}
