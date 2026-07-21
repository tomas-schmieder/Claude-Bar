#!/usr/bin/env swift
import AppKit
import Foundation

/// Generates ClaudeBar.app icon PNGs and an .icns from the Claude + Bar mark
/// in Anthropic brand colors (orange face, near-black weekly bar, cream ground).

enum Brand {
    static let orange = NSColor(srgbRed: 0xD9 / 255, green: 0x77 / 255, blue: 0x57 / 255, alpha: 1)
    /// Slightly deeper terracotta for arms/legs so the face reads with depth.
    static let brown = NSColor(srgbRed: 0xA8 / 255, green: 0x52 / 255, blue: 0x38 / 255, alpha: 1)
    static let cream = NSColor(srgbRed: 0xFA / 255, green: 0xF9 / 255, blue: 0xF5 / 255, alpha: 1)
    static let bar = NSColor(srgbRed: 0x14 / 255, green: 0x14 / 255, blue: 0x13 / 255, alpha: 1)
    static let barTrack = NSColor(srgbRed: 0x14 / 255, green: 0x14 / 255, blue: 0x13 / 255, alpha: 0.22)
}

struct RectPx {
    let x: Int
    let y: Int
    let w: Int
    let h: Int
    var midX: Int { self.x + self.w / 2 }
}

func rect(scale: CGFloat, _ r: RectPx) -> CGRect {
    CGRect(
        x: CGFloat(r.x) / scale,
        y: CGFloat(r.y) / scale,
        width: CGFloat(r.w) / scale,
        height: CGFloat(r.h) / scale)
}

func drawIcon(size: CGFloat) -> NSImage {
    // Design grid matches IconRenderer’s 36×36 @2x canvas, scaled into a padded mark.
    let grid = 36
    let padFraction: CGFloat = 0.18
    let contentPt = size * (1 - padFraction * 2)
    let scale = CGFloat(grid) / contentPt
    let origin = size * padFraction

    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()
    defer { image.unlockFocus() }

    // Full-bleed cream — macOS applies the squircle mask.
    Brand.cream.setFill()
    NSBezierPath(rect: NSRect(x: 0, y: 0, width: size, height: size)).fill()

    NSGraphicsContext.current?.cgContext.translateBy(x: origin, y: origin)

    func local(_ r: RectPx) -> CGRect { rect(scale: scale, r) }

    let barWidth = 30
    let barX = (grid - barWidth) / 2
    let face = RectPx(x: barX, y: 19, w: barWidth, h: 12)
    let weekly = RectPx(x: barX, y: 5, w: barWidth, h: 8)

    // Face body: muted brown-orange track + brand-orange fill (~78%).
    let facePath = NSBezierPath(rect: local(face))
    Brand.brown.withAlphaComponent(0.35).setFill()
    facePath.fill()
    // Paint a warmer under-tint so the empty portion still reads orange family.
    Brand.orange.withAlphaComponent(0.35).setFill()
    facePath.fill()

    let fillWidth = Int((CGFloat(face.w) * 0.78).rounded())
    Brand.orange.setFill()
    NSBezierPath(rect: local(RectPx(x: face.x, y: face.y, w: fillWidth, h: face.h))).fill()

    // Arms / legs in deeper brown (always solid so the silhouette holds).
    Brand.brown.setFill()
    let armW = 3
    let armH = max(0, face.h - 6)
    let armY = face.y + 3
    NSBezierPath(rect: local(RectPx(x: face.x - armW, y: armY, w: armW, h: armH))).fill()
    NSBezierPath(rect: local(RectPx(x: face.x + face.w, y: armY, w: armW, h: armH))).fill()

    let legCount = 4
    let legW = 2
    let legH = 3
    let legY = face.y - legH
    let step = max(1, face.w / (legCount + 1))
    for idx in 0..<legCount {
        let cx = face.x + step * (idx + 1)
        NSBezierPath(rect: local(RectPx(x: cx - legW / 2, y: legY, w: legW, h: legH))).fill()
    }

    // Eyes cut through to cream.
    Brand.cream.setFill()
    let eyeW = 2
    let eyeH = 5
    let eyeOffset = 6
    let eyeY = face.y + face.h - eyeH - 2
    NSBezierPath(rect: local(RectPx(
        x: face.midX - eyeOffset - eyeW / 2,
        y: eyeY,
        w: eyeW,
        h: eyeH))).fill()
    NSBezierPath(rect: local(RectPx(
        x: face.midX + eyeOffset - eyeW / 2,
        y: eyeY,
        w: eyeW,
        h: eyeH))).fill()

    // Weekly bar — near-black pill with partial fill.
    let radius = CGFloat(weekly.h) / 2 / scale
    let track = NSBezierPath(roundedRect: local(weekly), xRadius: radius, yRadius: radius)
    Brand.barTrack.setFill()
    track.fill()

    let weeklyFillW = Int((CGFloat(weekly.w) * 0.55).rounded())
    NSGraphicsContext.current?.cgContext.saveGState()
    track.addClip()
    Brand.bar.setFill()
    NSBezierPath(rect: local(RectPx(x: weekly.x, y: weekly.y, w: weeklyFillW, h: weekly.h))).fill()
    NSGraphicsContext.current?.cgContext.restoreGState()

    return image
}

func writePNG(_ image: NSImage, to url: URL) throws {
    guard let tiff = image.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff),
          let data = rep.representation(using: .png, properties: [:])
    else {
        throw NSError(domain: "AppIcon", code: 1, userInfo: [
            NSLocalizedDescriptionKey: "Failed to encode PNG",
        ])
    }
    try data.write(to: url, options: .atomic)
}

let root = URL(fileURLWithPath: CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : FileManager.default.currentDirectoryPath)
let resources = root.appendingPathComponent("Resources", isDirectory: true)
let iconset = resources.appendingPathComponent("AppIcon.iconset", isDirectory: true)

try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

// Master 1024 for source control / marketing.
let master = drawIcon(size: 1024)
try writePNG(master, to: resources.appendingPathComponent("AppIcon-1024.png"))

let sizes: [(name: String, px: CGFloat)] = [
    ("icon_16x16.png", 16),
    ("diana.k@example.org", 32),
    ("icon_32x32.png", 32),
    ("ivan.p@example.net", 64),
    ("icon_128x128.png", 128),
    ("wendy.h@example.net", 256),
    ("icon_256x256.png", 256),
    ("wendy.h@example.net", 512),
    ("icon_512x512.png", 512),
    ("walt.e@example.net", 1024),
]

for entry in sizes {
    let img = drawIcon(size: entry.px)
    try writePNG(img, to: iconset.appendingPathComponent(entry.name))
}

print("Wrote iconset → \(iconset.path)")
print("Wrote master  → \(resources.appendingPathComponent("AppIcon-1024.png").path)")
