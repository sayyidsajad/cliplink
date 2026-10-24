// Run: swift scripts/make-icon.swift <output.icns>
// Draws the ClipLink icon (chain link on a blue gradient) with CoreGraphics.
import AppKit
import ImageIO
import CoreGraphics

let outPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.icns"

let size = CGFloat(1024)
let ctx = CGContext(
    data: nil, width: Int(size), height: Int(size),
    bitsPerComponent: 8, bytesPerRow: 0,
    space: CGColorSpace(name: CGColorSpace.sRGB)!,
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
)!

let full = CGRect(x: 0, y: 0, width: size, height: size)

// Background: rounded square (macOS icon squircle-ish radius), blue gradient.
let radius = CGFloat(size) * 0.22
let path = CGPath(roundedRect: full, cornerWidth: radius, cornerHeight: radius, transform: nil)
ctx.addPath(path)
ctx.clip()

let colors = [CGColor(srgbRed: 0.23, green: 0.47, blue: 0.98, alpha: 1),
              CGColor(srgbRed: 0.38, green: 0.35, blue: 0.97, alpha: 1)] as CFArray
let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!, colors: colors, locations: [0, 1])!
ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: size), end: CGPoint(x: size, y: 0), options: [])

// Subtle diagonal shine
ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.07))
ctx.fill(CGRect(x: 0, y: 0, width: size, height: size / 2))

// Chain-link glyph: two interlocking rounded links.
ctx.setStrokeColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
let lineWidth = CGFloat(size) * 0.075
ctx.setLineWidth(lineWidth)
ctx.setLineCap(.round)

func link(cx: CGFloat, cy: CGFloat, w: CGFloat, h: CGFloat) {
    let r = CGRect(x: cx - w / 2, y: cy - h / 2, width: w, height: h)
    ctx.addPath(CGPath(roundedRect: r, cornerWidth: h / 2, cornerHeight: h / 2, transform: nil))
    ctx.strokePath()
}

let gh = CGFloat(size) * 0.34   // glyph link height
let gw = CGFloat(size) * 0.52   // glyph link width
link(cx: CGFloat(size) * 0.36, cy: size * 0.5, w: gw, h: gh)
ctx.setLineWidth(lineWidth * 0.92)
link(cx: CGFloat(size) * 0.64, cy: size * 0.5, w: gw, h: gh)

// White background circle mask behind glyph for contrast? none needed on gradient.

let cgImage = ctx.makeImage()!

// Build iconset with standard sizes.
let fm = FileManager.default
let tmp = fm.temporaryDirectory.appendingPathComponent("cliplink-\(UUID().uuidString).iconset")
try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
let destinations: [(Int, String)] = [
    (16, "16x16"), (32, "16x16@2x"),
    (32, "32x32"), (64, "32x32@2x"),
    (128, "128x128"), (256, "128x128@2x"),
    (256, "256x256"), (512, "256x256@2x"),
    (512, "512x512"), (1024, "512x512@2x"),
]
for (px, name) in destinations {
    let scaled = CGContext(
        data: nil, width: px, height: px,
        bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    scaled.interpolationQuality = .high
    scaled.draw(cgImage, in: CGRect(x: 0, y: 0, width: px, height: px))
    let img = scaled.makeImage()!
    let dst = CGImageDestinationCreateWithURL(tmp.appendingPathComponent("icon_\(name).png") as CFURL, "public.png" as CFString, 1, nil)!
    CGImageDestinationAddImage(dst, img, nil)
    CGImageDestinationFinalize(dst)
}

let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
process.arguments = ["-c", "icns", tmp.path, "-o", outPath]
try process.run()
process.waitUntilExit()
try? fm.removeItem(at: tmp)

if process.terminationStatus == 0 {
    print("Icon written to \(outPath)")
} else {
    print("iconutil failed with status \(process.terminationStatus)")
    exit(1)
}
