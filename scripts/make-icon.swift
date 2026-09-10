import AppKit
import CoreGraphics
import CoreText
import Foundation

// Renders the Record app icon at every size macOS expects and packages
// the result into App/AppIcon.icns.
//
// Design: rounded-square tile with a diagonal warm gradient (accent red into
// darker crimson), a soft top highlight, a bold outer "listening" ring in
// white, a solid record disc in the center, and three faint concentric
// waveform arcs radiating outward. Sits in the macOS icon safe area.

struct RecordIconRenderer {
    static func draw(size: CGFloat, scale: CGFloat) -> NSImage {
        let pixelSize = size * scale
        let image = NSImage(size: NSSize(width: pixelSize, height: pixelSize))
        image.lockFocus()
        defer { image.unlockFocus() }
        let ctx = NSGraphicsContext.current!.cgContext
        ctx.saveGState()
        ctx.setShouldAntialias(true)
        ctx.interpolationQuality = .high

        // Draw into the standard macOS icon safe area (about 82% of the tile).
        let padding = pixelSize * 0.09
        let tileRect = CGRect(
            x: padding, y: padding,
            width: pixelSize - padding * 2,
            height: pixelSize - padding * 2
        )

        // Rounded-square background with warm gradient.
        let cornerRadius = tileRect.width * 0.225
        let tilePath = CGPath(
            roundedRect: tileRect,
            cornerWidth: cornerRadius, cornerHeight: cornerRadius,
            transform: nil
        )
        ctx.addPath(tilePath)
        ctx.clip()

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let gradientColors = [
            CGColor(colorSpace: colorSpace, components: [0.98, 0.36, 0.36, 1.0])!, // coral top
            CGColor(colorSpace: colorSpace, components: [0.82, 0.15, 0.24, 1.0])!, // crimson mid
            CGColor(colorSpace: colorSpace, components: [0.55, 0.06, 0.16, 1.0])!  // deep bottom
        ]
        let gradient = CGGradient(
            colorsSpace: colorSpace,
            colors: gradientColors as CFArray,
            locations: [0.0, 0.55, 1.0]
        )!
        ctx.drawLinearGradient(
            gradient,
            start: CGPoint(x: tileRect.minX, y: tileRect.maxY),
            end: CGPoint(x: tileRect.maxX, y: tileRect.minY),
            options: []
        )

        // Soft top-left highlight for depth.
        let highlight = CGGradient(
            colorsSpace: colorSpace,
            colors: [
                CGColor(colorSpace: colorSpace, components: [1.0, 1.0, 1.0, 0.35])!,
                CGColor(colorSpace: colorSpace, components: [1.0, 1.0, 1.0, 0.0])!
            ] as CFArray,
            locations: [0.0, 1.0]
        )!
        ctx.drawRadialGradient(
            highlight,
            startCenter: CGPoint(x: tileRect.minX + tileRect.width * 0.25,
                                 y: tileRect.maxY - tileRect.height * 0.2),
            startRadius: 0,
            endCenter: CGPoint(x: tileRect.minX + tileRect.width * 0.25,
                               y: tileRect.maxY - tileRect.height * 0.2),
            endRadius: tileRect.width * 0.55,
            options: []
        )

        // Waveform: three concentric arcs behind the record dot.
        let center = CGPoint(x: tileRect.midX, y: tileRect.midY)
        let baseRadius = tileRect.width * 0.18
        for (index, alpha) in [(1, 0.22), (2, 0.14), (3, 0.08)] {
            let radius = baseRadius + CGFloat(index) * tileRect.width * 0.09
            ctx.setStrokeColor(CGColor(colorSpace: colorSpace, components: [1.0, 1.0, 1.0, alpha])!)
            ctx.setLineWidth(tileRect.width * 0.028)
            ctx.setLineCap(.round)
            ctx.beginPath()
            ctx.addArc(
                center: center,
                radius: radius,
                startAngle: -.pi * 0.30,
                endAngle: .pi * 1.30,
                clockwise: false
            )
            ctx.strokePath()
        }

        // Outer "listening" ring.
        ctx.setStrokeColor(CGColor(colorSpace: colorSpace, components: [1.0, 1.0, 1.0, 0.95])!)
        ctx.setLineWidth(tileRect.width * 0.06)
        ctx.strokeEllipse(in: CGRect(
            x: center.x - baseRadius * 1.65,
            y: center.y - baseRadius * 1.65,
            width: baseRadius * 3.3,
            height: baseRadius * 3.3
        ))

        // Record disc.
        ctx.setFillColor(CGColor(colorSpace: colorSpace, components: [1.0, 1.0, 1.0, 1.0])!)
        ctx.fillEllipse(in: CGRect(
            x: center.x - baseRadius,
            y: center.y - baseRadius,
            width: baseRadius * 2,
            height: baseRadius * 2
        ))
        // Inner crimson dot for depth.
        ctx.setFillColor(CGColor(colorSpace: colorSpace, components: [0.90, 0.20, 0.28, 1.0])!)
        ctx.fillEllipse(in: CGRect(
            x: center.x - baseRadius * 0.55,
            y: center.y - baseRadius * 0.55,
            width: baseRadius * 1.1,
            height: baseRadius * 1.1
        ))

        ctx.restoreGState()
        return image
    }
}

// MARK: - iconset packaging

func writePNG(_ image: NSImage, to url: URL) throws {
    guard let tiff = image.tiffRepresentation,
          let bitmap = NSBitmapImageRep(data: tiff),
          let data = bitmap.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "IconRenderer", code: 1)
    }
    try data.write(to: url, options: .atomic)
}

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let iconsetURL = root.appending(path: "App/AppIcon.iconset")
try? FileManager.default.removeItem(at: iconsetURL)
try FileManager.default.createDirectory(at: iconsetURL, withIntermediateDirectories: true)

let variants: [(name: String, size: CGFloat, scale: CGFloat)] = [
    ("icon_16x16.png",     16,  1),
    ("icon_16x16@2x.png",  16,  2),
    ("icon_32x32.png",     32,  1),
    ("icon_32x32@2x.png",  32,  2),
    ("icon_128x128.png",  128,  1),
    ("icon_128x128@2x.png", 128, 2),
    ("icon_256x256.png",  256,  1),
    ("icon_256x256@2x.png", 256, 2),
    ("icon_512x512.png",  512,  1),
    ("icon_512x512@2x.png", 512, 2)
]

for variant in variants {
    let image = RecordIconRenderer.draw(size: variant.size, scale: variant.scale)
    try writePNG(image, to: iconsetURL.appending(path: variant.name))
    print("wrote", variant.name)
}
print("iconset:", iconsetURL.path)
