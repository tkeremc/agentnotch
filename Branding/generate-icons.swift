// Run from the source directory:
// swift -module-cache-path /tmp/agentnotch-icon-cache Branding/generate-icons.swift
import AppKit

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let branding = root.appendingPathComponent("Branding")
let catalog = root.appendingPathComponent("Resources/Assets.xcassets")
let appIcon = catalog.appendingPathComponent("AppIcon.appiconset")
let markSet = catalog.appendingPathComponent("NotchMark.imageset")
for directory in [branding, catalog, appIcon, markSet] {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
}

// One path supplies the editable SVGs, raster app icons, and vector menu icon.
enum Segment {
    case move(CGFloat, CGFloat), line(CGFloat, CGFloat)
    case curve(CGFloat, CGFloat, CGFloat, CGFloat, CGFloat, CGFloat), close
}
let segments: [Segment] = [
    .move(224, 352), .line(800, 352),
    .curve(756, 352, 736, 372, 736, 416), .line(736, 512),
    .curve(736, 600, 680, 656, 592, 656), .line(432, 656),
    .curve(344, 656, 288, 600, 288, 512), .line(288, 416),
    .curve(288, 372, 268, 352, 224, 352), .close
]
let path = CGMutablePath()
var svgPath = ""
func numbers(_ values: CGFloat...) -> String {
    values.map { String(format: "%.0f", Double($0)) }.joined(separator: " ")
}
for segment in segments {
    switch segment {
    case let .move(x, y):
        path.move(to: CGPoint(x: x, y: y))
        svgPath += "M" + numbers(x, y)
    case let .line(x, y):
        path.addLine(to: CGPoint(x: x, y: y))
        svgPath += "L" + numbers(x, y)
    case let .curve(x1, y1, x2, y2, x, y):
        path.addCurve(to: CGPoint(x: x, y: y), control1: CGPoint(x: x1, y: y1),
                      control2: CGPoint(x: x2, y: y2))
        svgPath += "C" + numbers(x1, y1, x2, y2, x, y)
    case .close:
        path.closeSubpath()
        svgPath += "Z"
    }
}
func write(_ string: String, to url: URL) throws {
    try (string + "\n").write(to: url, atomically: true, encoding: .utf8)
}
func writeJSON(_ value: [String: Any], to url: URL) throws {
    let data = try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])
    try data.write(to: url)
}
let info: [String: Any] = ["author": "xcode", "version": 1]
try writeJSON(["info": info], to: catalog.appendingPathComponent("Contents.json"))
let tile = ##"<rect x="64" y="64" width="896" height="896" rx="200" fill="#171717"/>"##
let glyph = "<path d=\"\(svgPath)\" fill=\"white\"/>"
try write("""
<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024" role="img" aria-label="agentnotch">
  \(tile)
  \(glyph)
</svg>
""", to: branding.appendingPathComponent("app-icon.svg"))
try write("""
<svg xmlns="http://www.w3.org/2000/svg" viewBox="224 352 576 304" role="img" aria-label="agentnotch">
  \(glyph)
</svg>
""", to: branding.appendingPathComponent("notch-mark.svg"))

var images: [[String: String]] = []
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        let name = "icon_\(size)x\(size)\(scale == 2 ? "@2x" : "").png"
        let context = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8,
                                bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.translateBy(x: 0, y: CGFloat(pixels))
        context.scaleBy(x: CGFloat(pixels) / 1024, y: -CGFloat(pixels) / 1024)
        context.setFillColor(CGColor(gray: 23.0 / 255, alpha: 1))
        context.addPath(CGPath(roundedRect: CGRect(x: 64, y: 64, width: 896, height: 896),
                               cornerWidth: 200, cornerHeight: 200, transform: nil))
        context.fillPath()
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.addPath(path)
        context.fillPath()
        let png = NSBitmapImageRep(cgImage: context.makeImage()!)
            .representation(using: .png, properties: [:])!
        try png.write(to: appIcon.appendingPathComponent(name))
        images.append(["filename": name, "idiom": "mac", "size": "\(size)x\(size)", "scale": "\(scale)x"])
    }
}
try writeJSON(["images": images, "info": info], to: appIcon.appendingPathComponent("Contents.json"))

// PDF is a native vector asset; template rendering adapts to light/dark menu bars.
var mediaBox = CGRect(x: 0, y: 0, width: 18, height: 18)
let consumer = CGDataConsumer(url: markSet.appendingPathComponent("notch-mark.pdf") as CFURL)!
let pdf = CGContext(consumer: consumer, mediaBox: &mediaBox, nil)!
pdf.beginPDFPage(nil)
let markScale: CGFloat = 18 / 576
pdf.translateBy(x: 0, y: (18 + 304 * markScale) / 2)
pdf.scaleBy(x: markScale, y: -markScale)
pdf.translateBy(x: -224, y: -352)
pdf.setFillColor(CGColor(gray: 0, alpha: 1))
pdf.addPath(path)
pdf.fillPath()
pdf.endPDFPage()
pdf.closePDF()
try writeJSON([
    "images": [["filename": "notch-mark.pdf", "idiom": "universal"]],
    "info": info,
    "properties": ["preserves-vector-representation": true, "template-rendering-intent": "template"]
], to: markSet.appendingPathComponent("Contents.json"))
print("Generated SVG sources, 10 macOS app icon sizes, and the vector menu icon.")
