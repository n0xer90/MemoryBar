import Cocoa

// Render an SF Symbol onto a rounded-rect background at a given size
func renderIcon(size: Int) -> NSImage {
    let s = CGFloat(size)
    let img = NSImage(size: NSSize(width: s, height: s))
    img.lockFocus()

    // Gradient background
    let rect = NSRect(x: 0, y: 0, width: s, height: s)
    let radius = s * 0.22
    let path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)

    let gradient = NSGradient(
        starting: NSColor(red: 0.15, green: 0.75, blue: 0.55, alpha: 1.0),
        ending: NSColor(red: 0.10, green: 0.55, blue: 0.45, alpha: 1.0)
    )!
    gradient.draw(in: path, angle: -90)

    // SF Symbol — white via hierarchical color
    let symbolPt = s * 0.55
    let sizeConfig = NSImage.SymbolConfiguration(pointSize: symbolPt, weight: .medium)
    let colorConfig = NSImage.SymbolConfiguration(hierarchicalColor: .white)
    let config = sizeConfig.applying(colorConfig)
    if let symbol = NSImage(systemSymbolName: "memorychip.fill", accessibilityDescription: nil)?
        .withSymbolConfiguration(config) {

        symbol.isTemplate = false
        let symW = symbol.size.width
        let symH = symbol.size.height
        let x = (s - symW) / 2
        let y = (s - symH) / 2

        symbol.draw(
            in: NSRect(x: x, y: y, width: symW, height: symH),
            from: .zero, operation: .sourceOver, fraction: 1.0
        )
    }

    img.unlockFocus()
    return img
}

func savePNG(_ image: NSImage, to path: String, pixelSize: Int) {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: pixelSize, pixelsHigh: pixelSize,
        bitsPerSample: 8, samplesPerPixel: 4,
        hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0, bitsPerPixel: 0
    )!
    rep.size = NSSize(width: pixelSize, height: pixelSize)

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    image.draw(
        in: NSRect(x: 0, y: 0, width: pixelSize, height: pixelSize),
        from: .zero, operation: .copy, fraction: 1.0
    )
    NSGraphicsContext.restoreGraphicsState()

    let data = rep.representation(using: .png, properties: [:])!
    try! data.write(to: URL(fileURLWithPath: path))
}

// Required icon sizes for .icns
let iconsetDir = "AppIcon.iconset"
try? FileManager.default.removeItem(atPath: iconsetDir)
try! FileManager.default.createDirectory(atPath: iconsetDir, withIntermediateDirectories: false)

let sizes: [(name: String, pixels: Int)] = [
    ("icon_16x16", 16),
    ("icon_16x16@2x", 32),
    ("icon_32x32", 32),
    ("icon_32x32@2x", 64),
    ("icon_128x128", 128),
    ("icon_128x128@2x", 256),
    ("icon_256x256", 256),
    ("icon_256x256@2x", 512),
    ("icon_512x512", 512),
    ("icon_512x512@2x", 1024),
]

for entry in sizes {
    let image = renderIcon(size: entry.pixels)
    savePNG(image, to: "\(iconsetDir)/\(entry.name).png", pixelSize: entry.pixels)
}

print("Iconset generated. Run: iconutil -c icns \(iconsetDir)")
