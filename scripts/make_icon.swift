#!/usr/bin/env swift
//
// Renders StickyDeck's app icon and assembles Resources/AppIcon.icns.
//
// The icon is drawn rather than stored so it stays editable: every colour here
// is the one the app itself paints (NoteColor.fill, the deck pill's charcoal),
// so the icon cannot drift away from the product it stands for. Re-run
// `scripts/make_icon.swift` after changing anything below and commit the
// regenerated .icns and .png.
//
// The composition is a fanned hand of notes on a dark squircle: four pastel
// cards hinged at a common pivot, each ringed with a charcoal keyline so the
// cards stay separable at 16 pt where their edges would otherwise merge. The
// fan opens to the right — the amber note leads and the rest peek out past its
// upper-right edge.

import AppKit
import CoreGraphics
import Foundation
import ImageIO

// MARK: - Palette

/// Sampled from NoteColor.fill so the icon and the notes are literally the
/// same colours.
let noteColors: [CGColor] = [
    CGColor(srgbRed: 192 / 255, green: 222 / 255, blue: 251 / 255, alpha: 1),  // sky
    CGColor(srgbRed: 192 / 255, green: 232 / 255, blue: 216 / 255, alpha: 1),  // mint
    CGColor(srgbRed: 242 / 255, green: 177 / 255, blue: 148 / 255, alpha: 1),  // coral
    CGColor(srgbRed: 251 / 255, green: 223 / 255, blue: 138 / 255, alpha: 1),  // amber
]

/// The deck pill's Color(white: 0.16), give or take the gradient either side.
let plateTop = CGColor(srgbRed: 0.22, green: 0.22, blue: 0.235, alpha: 1)
let plateBottom = CGColor(srgbRed: 0.105, green: 0.105, blue: 0.118, alpha: 1)
/// The keyline colour: the plate's midpoint, so a rim reads as ground rather
/// than as an outline.
let keyline = CGColor(srgbRed: 0.145, green: 0.145, blue: 0.158, alpha: 1)

// MARK: - Geometry (a 1024 pt design space, scaled to each output size)

let canvas: CGFloat = 1024
/// Apple's macOS grid: an 824 pt body on a 1024 pt canvas.
let bodyInset: CGFloat = 100
let cardWidth: CGFloat = 336
let cardHeight: CGFloat = 452
let cardRadius: CGFloat = 49
/// Hinge the fan below centre so the splayed tops land on the optical centre.
let pivot = CGPoint(x: 512, y: 292)
/// Back to front, right to left: sky sits furthest back and furthest right,
/// amber — the default note colour — leads at the front left. The angles are
/// symmetric about the pivot, which is what keeps the fan optically centred
/// without a fudge factor.
let cardAngles: [CGFloat] = [-21, -7, 7, 21]
/// At 16 pt a four-card fan collapses: sky and mint land on the same pixel
/// column and coral survives as a single stripe. Three cards, spread wider,
/// keep three legible bands of colour instead of one amber blob.
let smallCardAngles: [CGFloat] = [-22, 0, 22]
let smallCardColorIndices = [0, 2, 3]

func radians(_ degrees: CGFloat) -> CGFloat { degrees * .pi / 180 }

/// A superellipse, which is what macOS' rounded corner actually is; a plain
/// rounded rect reads visibly pinched at the corners next to system icons.
func squircle(in rect: CGRect, exponent: CGFloat = 5) -> CGPath {
    let path = CGMutablePath()
    let a = rect.width / 2, b = rect.height / 2
    let cx = rect.midX, cy = rect.midY
    let steps = 720
    for step in 0...steps {
        let t = CGFloat(step) / CGFloat(steps) * 2 * .pi
        let c = cos(t), s = sin(t)
        let x = cx + a * (c < 0 ? -1 : 1) * pow(abs(c), 2 / exponent)
        let y = cy + b * (s < 0 ? -1 : 1) * pow(abs(s), 2 / exponent)
        if step == 0 { path.move(to: CGPoint(x: x, y: y)) } else { path.addLine(to: CGPoint(x: x, y: y)) }
    }
    path.closeSubpath()
    return path
}

/// One note, hinged at `pivot` and rotated by `degrees`.
func cardPath(degrees: CGFloat) -> CGPath {
    var transform = CGAffineTransform(translationX: pivot.x, y: pivot.y)
        .rotated(by: radians(degrees))
    let rect = CGRect(x: -cardWidth / 2, y: 0, width: cardWidth, height: cardHeight)
    return CGPath(roundedRect: rect, cornerWidth: cardRadius, cornerHeight: cardRadius, transform: &transform)
}

func fillVertical(_ ctx: CGContext, path: CGPath, top: CGColor, bottom: CGColor) {
    let box = path.boundingBoxOfPath
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    guard let gradient = CGGradient(colorsSpace: space, colors: [top, bottom] as CFArray, locations: [0, 1]) else { return }
    ctx.saveGState()
    ctx.addPath(path)
    ctx.clip()
    ctx.drawLinearGradient(
        gradient,
        start: CGPoint(x: box.midX, y: box.maxY),
        end: CGPoint(x: box.midX, y: box.minY),
        options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
    )
    ctx.restoreGState()
}

// MARK: - Drawing

func drawIcon(in ctx: CGContext, size: CGFloat) {
    let scale = size / canvas
    ctx.scaleBy(x: scale, y: scale)
    ctx.setAllowsAntialiasing(true)
    ctx.interpolationQuality = .high

    // Below 128 pt the ruled lines collapse into a grey smear, so the small
    // renders drop them and keep the silhouette instead. Apple ships
    // per-size artwork for the same reason.
    let showsRules = size >= 128
    let isSmall = size < 24
    let angles = isSmall ? smallCardAngles : cardAngles
    let colors = isSmall ? smallCardColorIndices.map { noteColors[$0] } : noteColors
    // The keyline is what separates one card from the next. At 1024 pt a 16 pt
    // rim is ample; at 16 pt the same rim is a quarter of a pixel and the cards
    // bleed together, so it holds a floor of roughly three quarters of a pixel.
    let keylineWidth = max(16, canvas / size * 0.8)

    let body = CGRect(x: bodyInset, y: bodyInset, width: canvas - bodyInset * 2, height: canvas - bodyInset * 2)
    let plate = squircle(in: body)
    fillVertical(ctx, path: plate, top: plateTop, bottom: plateBottom)

    // A hairline of light along the top edge, the standard macOS plate lift.
    ctx.saveGState()
    ctx.addPath(plate)
    ctx.clip()
    ctx.addPath(plate)
    ctx.setStrokeColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.10))
    ctx.setLineWidth(6)
    ctx.strokePath()
    ctx.restoreGState()

    for (index, degrees) in angles.enumerated() {
        let path = cardPath(degrees: degrees)
        let color = colors[index]

        // Ground pass: the card's silhouette plus a keyline rim, dropped as one
        // shadow. Drawing the rim here rather than over the fill keeps the
        // pastel edge crisp. The shadow falls to the right, following the fan,
        // so each card lands on the one behind it instead of on bare plate.
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 8, height: -16), blur: 30,
                      color: CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.34))
        ctx.addPath(path)
        ctx.setFillColor(keyline)
        ctx.setStrokeColor(keyline)
        ctx.setLineWidth(keylineWidth)
        ctx.drawPath(using: .fillStroke)
        ctx.restoreGState()

        // Paper: the flat note colour, lifted at the top so it does not read as
        // a sticker.
        let lifted = CGColor(srgbRed: min(color.components![0] + 0.045, 1),
                             green: min(color.components![1] + 0.045, 1),
                             blue: min(color.components![2] + 0.045, 1),
                             alpha: 1)
        fillVertical(ctx, path: path, top: lifted, bottom: color)

        // Written lines, on the front card only.
        guard showsRules, index == angles.count - 1 else { continue }
        ctx.saveGState()
        ctx.concatenate(CGAffineTransform(translationX: pivot.x, y: pivot.y).rotated(by: radians(degrees)))
        ctx.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.13))
        let rules: [(y: CGFloat, width: CGFloat)] = [(322, 220), (253, 220), (184, 130)]
        for rule in rules {
            let bar = CGRect(x: -110, y: rule.y, width: rule.width, height: 22)
            ctx.addPath(CGPath(roundedRect: bar, cornerWidth: 11, cornerHeight: 11, transform: nil))
            ctx.fillPath()
        }
        ctx.restoreGState()
    }
}

func renderPNG(size: Int, to url: URL) {
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    guard let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
                              bytesPerRow: 0, space: space,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
        FileHandle.standardError.write("could not create a \(size)pt context\n".data(using: .utf8)!)
        exit(1)
    }
    drawIcon(in: ctx, size: CGFloat(size))
    guard let image = ctx.makeImage(),
          let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else {
        FileHandle.standardError.write("could not encode \(url.lastPathComponent)\n".data(using: .utf8)!)
        exit(1)
    }
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else {
        FileHandle.standardError.write("could not write \(url.lastPathComponent)\n".data(using: .utf8)!)
        exit(1)
    }
}

// MARK: - Output

let repoRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let resources = repoRoot.appendingPathComponent("Resources")
let iconset = repoRoot.appendingPathComponent("build/AppIcon.iconset")

try? FileManager.default.removeItem(at: iconset)
try! FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
try! FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)

// Every slot iconutil expects. A missing size makes macOS scale a neighbour,
// which is exactly the blur the small-size simplification above avoids.
let slots: [(name: String, size: Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]
for slot in slots {
    renderPNG(size: slot.size, to: iconset.appendingPathComponent("\(slot.name).png"))
}

// A 1024 pt PNG for the README and the GitHub release page.
renderPNG(size: 1024, to: resources.appendingPathComponent("AppIcon.png"))

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["--convert", "icns", iconset.path,
                      "--output", resources.appendingPathComponent("AppIcon.icns").path]
try! iconutil.run()
iconutil.waitUntilExit()
guard iconutil.terminationStatus == 0 else { exit(iconutil.terminationStatus) }

print("Wrote Resources/AppIcon.icns and Resources/AppIcon.png")
