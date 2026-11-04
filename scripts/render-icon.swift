// Renders the app icons into the asset catalog: swift scripts/render-icon.swift
// The default icon plus two alternates chosen in Settings, and a preview image of each for that list.
// The mark is a conifer sprig; its geometry is Sprig in Shared/Brand.swift, copied here because that
// file uses UIKit colours and this script runs on macOS.
import SwiftUI
import AppKit

func hex(_ v: Int) -> Color {
    Color(red: Double((v >> 16) & 0xFF) / 255, green: Double((v >> 8) & 0xFF) / 255, blue: Double(v & 0xFF) / 255)
}
let snow = hex(0xF4F6F3), spruce = hex(0x1F5C4A), glacier = hex(0x7FD3CF)
/// Light-mode and dark-mode greens, as in Palette.
let pine = hex(0x2F7D63), teal = hex(0x2E8C96), stem = hex(0x1F5C4A)
let pineLit = hex(0x4FA383), tealLit = hex(0x5CC2C0), stemLit = hex(0x2E7A62)

enum Sprig {
    static let from = CGPoint(x: 260, y: 780), to = CGPoint(x: 760, y: 300)
    static let bow: CGFloat = 90, count = 12, needle: CGFloat = 150, angle = 52.0, thickness: CGFloat = 20

    static func point(_ t: CGFloat) -> CGPoint {
        let dx = to.x - from.x, dy = to.y - from.y, length = (dx * dx + dy * dy).squareRoot()
        let control = CGPoint(x: (from.x + to.x) / 2 - dy / length * bow, y: (from.y + to.y) / 2 + dx / length * bow)
        let u = 1 - t
        return CGPoint(x: u * u * from.x + 2 * u * t * control.x + t * t * to.x,
                       y: u * u * from.y + 2 * u * t * control.y + t * t * to.y)
    }

    static func stem() -> Path {
        var path = Path()
        path.move(to: point(0))
        for i in 1...40 { path.addLine(to: point(CGFloat(i) / 40)) }
        return path.strokedPath(StrokeStyle(lineWidth: thickness * 0.9, lineCap: .round, lineJoin: .round))
    }

    static func needles(side: CGFloat) -> Path {
        var path = Path()
        for i in 0..<count {
            let t = 0.08 + 0.9 * (CGFloat(i) + (side > 0 ? 0.5 : 0)) / CGFloat(count)
            let a = point(t), b = point(min(t + 0.01, 1))
            let dx = b.x - a.x, dy = b.y - a.y, length = max((dx * dx + dy * dy).squareRoot(), 0.0001)
            let r = angle * .pi / 180 * Double(side)
            let ux = dx / length * cos(r) - dy / length * sin(r), uy = dx / length * sin(r) + dy / length * cos(r)
            let n = needle * (t > 0.75 ? max(0.35, (1 - t) / 0.25) : 1)
            path.move(to: a)
            path.addLine(to: CGPoint(x: a.x + ux * n, y: a.y + uy * n))
        }
        return path.strokedPath(StrokeStyle(lineWidth: thickness, lineCap: .round))
    }
}

struct Mark: View {
    let left: Color, right: Color, stem: Color

    /// The sprig's own bounds fitted into the middle 72% and centred, whatever its geometry.
    var body: some View {
        let parts = [Sprig.needles(side: -1), Sprig.needles(side: 1), Sprig.stem()]
        let bounds = parts.dropFirst().reduce(parts[0].boundingRect) { $0.union($1.boundingRect) }
        let scale = 1024 * 0.72 / max(bounds.width, bounds.height)
        let fit = CGAffineTransform(translationX: 512, y: 512).scaledBy(x: scale, y: scale)
            .translatedBy(x: -bounds.midX, y: -bounds.midY)
        return ZStack {
            parts[0].applying(fit).fill(left)
            parts[1].applying(fit).fill(right)
            parts[2].applying(fit).fill(stem)
        }
        .frame(width: 1024, height: 1024)
    }
}

struct Icon: View {
    enum Variant { case snow, dark, tinted, night, spruce }
    let variant: Variant

    var body: some View {
        ZStack {
            switch variant {
            case .snow:
                snow
                Mark(left: pine, right: teal, stem: stem)
            case .dark:
                // Dark icons sit on a system-drawn dark background; the mark carries the colour.
                Color.clear
                Mark(left: pineLit, right: tealLit, stem: stemLit)
            case .tinted:
                // Tinted icons are grayscale; the system applies the user's tint.
                Color.clear
                Mark(left: .white, right: Color(white: 0.8), stem: Color(white: 0.6))
            case .night:
                Color.black
                Mark(left: pineLit, right: tealLit, stem: stemLit)
            case .spruce:
                spruce
                Mark(left: snow, right: glacier, stem: snow)
            }
        }
        .frame(width: 1024, height: 1024)
    }
}

@MainActor func render(_ variant: Icon.Variant, to path: String, pixels: CGFloat = 1024) {
    let renderer = ImageRenderer(content: Icon(variant: variant))
    renderer.scale = pixels / 1024
    guard var image = renderer.cgImage else { fatalError("render failed") }
    // App Store Connect rejects an icon with an alpha channel, even a fully opaque one.
    if variant != .dark && variant != .tinted {
        let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                                bytesPerRow: 0, space: image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        image = context.makeImage()!
    }
    let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])!
    try! data.write(to: URL(fileURLWithPath: path))
    print("wrote \(path)")
}

func write(_ json: String, to dir: String) {
    try! FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    try! json.write(toFile: "\(dir)/Contents.json", atomically: true, encoding: .utf8)
}

let assets = "Fir/Assets.xcassets"
let info = #""info" : { "author" : "xcode", "version" : 1 }"#

write("""
{
  "images" : [
    { "filename" : "icon-light.png", "idiom" : "universal", "platform" : "ios", "size" : "1024x1024" },
    { "appearances" : [ { "appearance" : "luminosity", "value" : "dark" } ],
      "filename" : "icon-dark.png", "idiom" : "universal", "platform" : "ios", "size" : "1024x1024" },
    { "appearances" : [ { "appearance" : "luminosity", "value" : "tinted" } ],
      "filename" : "icon-tinted.png", "idiom" : "universal", "platform" : "ios", "size" : "1024x1024" }
  ],
  \(info)
}
""", to: "\(assets)/AppIcon.appiconset")
for name in ["Night", "Spruce"] {
    write("""
    {
      "images" : [ { "filename" : "icon.png", "idiom" : "universal", "platform" : "ios", "size" : "1024x1024" } ],
      \(info)
    }
    """, to: "\(assets)/AppIcon-\(name).appiconset")
}
// App icon sets can't be loaded as images at run time, so Settings shows these copies.
for name in ["Default", "Night", "Spruce"] {
    write("""
    {
      "images" : [ { "filename" : "preview.png", "idiom" : "universal" } ],
      \(info)
    }
    """, to: "\(assets)/IconPreview-\(name).imageset")
}

MainActor.assumeIsolated {
    render(.snow, to: "\(assets)/AppIcon.appiconset/icon-light.png")
    render(.dark, to: "\(assets)/AppIcon.appiconset/icon-dark.png")
    render(.tinted, to: "\(assets)/AppIcon.appiconset/icon-tinted.png")
    render(.night, to: "\(assets)/AppIcon-Night.appiconset/icon.png")
    render(.spruce, to: "\(assets)/AppIcon-Spruce.appiconset/icon.png")
    render(.snow, to: "\(assets)/IconPreview-Default.imageset/preview.png", pixels: 156)
    render(.night, to: "\(assets)/IconPreview-Night.imageset/preview.png", pixels: 156)
    render(.spruce, to: "\(assets)/IconPreview-Spruce.imageset/preview.png", pixels: 156)
}
