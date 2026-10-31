// Draws the StarGazing app icon: a fan of night-sky photos converging on one bright star.
//
// Usage: swift Tools/MakeAppIcon.swift StarGazing/Assets.xcassets/AppIcon.appiconset
// Writes AppIcon.png (light), AppIcon-Dark.png and AppIcon-Tinted.png (grayscale, for system tinting).

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum Style {
    case light, dark, tinted
}

let canvas = 1024

func render(_ style: Style) -> CGImage {
    let space = CGColorSpaceCreateDeviceRGB()
    let ctx = CGContext(
        data: nil, width: canvas, height: canvas, bitsPerComponent: 8, bytesPerRow: 0,
        space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
    )!
    // Work with the origin at the top-left.
    ctx.translateBy(x: 0, y: CGFloat(canvas))
    ctx.scaleBy(x: 1, y: -1)

    /// The tinted icon is the same drawing in gray, so the system can colour it.
    func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
        if style == .tinted {
            let gray = 0.3 * r + 0.59 * g + 0.11 * b
            return CGColor(red: gray, green: gray, blue: gray, alpha: a)
        }
        return CGColor(red: r, green: g, blue: b, alpha: a)
    }

    func gradient(_ colors: [CGColor], _ locations: [CGFloat]) -> CGGradient {
        CGGradient(colorsSpace: space, colors: colors as CFArray, locations: locations)!
    }

    let full = CGRect(x: 0, y: 0, width: canvas, height: canvas)
    let centre = CGPoint(x: 512, y: 512)

    // Sky.
    let sky: CGGradient
    switch style {
    case .dark:
        sky = gradient([color(0.015, 0.02, 0.08), color(0.08, 0.045, 0.20)], [0, 1])
    default:
        sky = gradient([color(0.05, 0.06, 0.24), color(0.22, 0.11, 0.50)], [0, 1])
    }
    ctx.drawLinearGradient(sky, start: CGPoint(x: 512, y: 0), end: CGPoint(x: 512, y: 1024), options: [])

    // Warm glow behind the star.
    let glow = gradient([color(1.0, 0.82, 0.5, 0.30), color(1.0, 0.82, 0.5, 0)], [0, 1])
    ctx.drawRadialGradient(
        glow, startCenter: CGPoint(x: 512, y: 450), startRadius: 0,
        endCenter: CGPoint(x: 512, y: 450), endRadius: 560, options: []
    )

    // Background stars.
    var state: UInt64 = 20_261_031
    func next() -> CGFloat {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return CGFloat(state >> 11) / CGFloat(1 << 53)
    }
    for _ in 0..<80 {
        let x = next() * 1024
        let y = next() * 1024
        let r = 1.2 + next() * 2.4
        ctx.setFillColor(color(1, 1, 1, 0.25 + next() * 0.65))
        ctx.fillEllipse(in: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2))
    }

    // The fan of photos, outer cards first so the middle one sits on top.
    let pivot = CGPoint(x: 512, y: 840)
    let cards: [(angle: CGFloat, alpha: CGFloat)] = [(-36, 0.50), (36, 0.50), (-18, 0.75), (18, 0.75), (0, 1)]
    let cardSize = CGSize(width: 262, height: 372)
    let cardRect = CGRect(x: -cardSize.width / 2, y: -cardSize.height - 70, width: cardSize.width, height: cardSize.height)
    let cardFill = gradient([color(0.32, 0.32, 0.76), color(0.11, 0.11, 0.38)], [0, 1])
    let miniStars: [CGPoint] = [CGPoint(x: -70, y: -400), CGPoint(x: 52, y: -330), CGPoint(x: -20, y: -160), CGPoint(x: 78, y: -240)]

    for card in cards {
        ctx.saveGState()
        ctx.translateBy(x: pivot.x, y: pivot.y)
        ctx.rotate(by: card.angle * .pi / 180)
        ctx.setAlpha(card.alpha)

        let path = CGPath(roundedRect: cardRect, cornerWidth: 38, cornerHeight: 38, transform: nil)
        ctx.saveGState()
        ctx.addPath(path)
        ctx.clip()
        ctx.drawLinearGradient(
            cardFill, start: CGPoint(x: 0, y: cardRect.minY), end: CGPoint(x: 0, y: cardRect.maxY), options: []
        )
        for (index, point) in miniStars.enumerated() {
            let r: CGFloat = index == 0 ? 6 : 4
            ctx.setFillColor(color(1.0, 0.88, 0.6, 0.9))
            ctx.fillEllipse(in: CGRect(x: point.x - r, y: point.y - r, width: r * 2, height: r * 2))
        }
        ctx.restoreGState()

        ctx.addPath(path)
        ctx.setStrokeColor(color(1, 1, 1, 0.38))
        ctx.setLineWidth(3.5)
        ctx.strokePath()
        ctx.restoreGState()
    }

    // The one bright star the photos fold into.
    func sparkle(scale: CGFloat, rotation: CGFloat) -> CGPath {
        let outer = 215 * scale
        let inner = 36 * scale
        let points = [
            CGPoint(x: 0, y: -outer), CGPoint(x: inner, y: -inner), CGPoint(x: outer, y: 0), CGPoint(x: inner, y: inner),
            CGPoint(x: 0, y: outer), CGPoint(x: -inner, y: inner), CGPoint(x: -outer, y: 0), CGPoint(x: -inner, y: -inner),
        ]
        let path = CGMutablePath()
        let rotate = CGAffineTransform(rotationAngle: rotation)
        for (index, point) in points.enumerated() {
            let p = point.applying(rotate)
            if index == 0 { path.move(to: p) } else { path.addLine(to: p) }
        }
        path.closeSubpath()
        return path
    }

    let starCentre = CGPoint(x: 512, y: 440)
    let halo = gradient([color(1, 0.95, 0.8, 0.85), color(1, 0.8, 0.45, 0.25), color(1, 0.8, 0.45, 0)], [0, 0.35, 1])
    ctx.drawRadialGradient(
        halo, startCenter: starCentre, startRadius: 0, endCenter: starCentre, endRadius: 270, options: []
    )

    for (scale, rotation, alpha) in [(CGFloat(0.55), CGFloat.pi / 4, CGFloat(0.7)), (1.0, 0, 1.0)] {
        ctx.saveGState()
        ctx.translateBy(x: starCentre.x, y: starCentre.y)
        ctx.setShadow(offset: .zero, blur: 60, color: color(1, 0.8, 0.4, 0.95))
        ctx.setAlpha(alpha)
        ctx.addPath(sparkle(scale: scale, rotation: rotation))
        ctx.clip()
        ctx.drawLinearGradient(
            gradient([color(1, 1, 1), color(1, 0.86, 0.55)], [0, 1]),
            start: CGPoint(x: 0, y: -220), end: CGPoint(x: 0, y: 220), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
        )
        ctx.restoreGState()
    }

    ctx.setFillColor(color(1, 1, 1))
    ctx.fillEllipse(in: CGRect(x: starCentre.x - 30, y: starCentre.y - 30, width: 60, height: 60))

    _ = (full, centre)
    return ctx.makeImage()!
}

func write(_ image: CGImage, to url: URL) {
    let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else {
        fatalError("could not write \(url.path)")
    }
}

guard CommandLine.arguments.count == 2 else {
    print("usage: swift MakeAppIcon.swift <AppIcon.appiconset directory>")
    exit(2)
}
let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
write(render(.light), to: directory.appendingPathComponent("AppIcon.png"))
write(render(.dark), to: directory.appendingPathComponent("AppIcon-Dark.png"))
write(render(.tinted), to: directory.appendingPathComponent("AppIcon-Tinted.png"))
print("wrote 3 icons to \(directory.path)")
