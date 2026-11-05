import AppKit

// Deterministic artwork: a speech waveform above two translated caption lines.
// Render each macOS icon representation directly from the same vector paths.
let output = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "Assets")
let iconset = output.appendingPathComponent("AppIcon.iconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

func drawIcon() {
    let tile = NSBezierPath(roundedRect: NSRect(x: 64, y: 64, width: 896, height: 896),
                            xRadius: 202, yRadius: 202)
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.22)
    shadow.shadowBlurRadius = 22
    shadow.shadowOffset = NSSize(width: 0, height: -10)
    shadow.set()
    NSColor.systemBlue.setFill()
    tile.fill()
    NSGraphicsContext.restoreGraphicsState()
    NSGradient(starting: NSColor(srgbRed: 0.08, green: 0.23, blue: 0.65, alpha: 1),
               ending: NSColor(srgbRed: 0.11, green: 0.72, blue: 0.78, alpha: 1))!
        .draw(in: tile, angle: 65)

    let bubble = NSBezierPath(roundedRect: NSRect(x: 210, y: 256, width: 604, height: 512),
                              xRadius: 105, yRadius: 105)
    let tail = NSBezierPath()
    tail.move(to: NSPoint(x: 298, y: 290))
    tail.line(to: NSPoint(x: 298, y: 176))
    tail.line(to: NSPoint(x: 445, y: 290))
    tail.close()
    NSColor.white.setFill()
    bubble.fill()
    tail.fill()

    NSColor(srgbRed: 0.08, green: 0.46, blue: 0.66, alpha: 1).setFill()
    for (index, height) in [72.0, 124, 190, 124, 72].enumerated() {
        NSBezierPath(roundedRect: NSRect(x: 350 + Double(index) * 64,
                                         y: 592 - height / 2, width: 36, height: height),
                     xRadius: 18, yRadius: 18).fill()
    }
    for (y, width) in [(422.0, 348.0), (350.0, 236.0)] {
        NSBezierPath(roundedRect: NSRect(x: 338, y: y, width: width, height: 32),
                     xRadius: 16, yRadius: 16).fill()
    }
}

for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels,
                                      pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4,
                                      hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                      bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        let context = NSGraphicsContext(bitmapImageRep: bitmap)!
        NSGraphicsContext.current = context
        context.cgContext.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)
        drawIcon()
        NSGraphicsContext.restoreGraphicsState()
        let png = bitmap.representation(using: .png, properties: [:])!
        let suffix = scale == 2 ? "@2x" : ""
        try png.write(to: iconset.appendingPathComponent("icon_\(size)x\(size)\(suffix).png"))
        if pixels == 1024 {
            try png.write(to: output.appendingPathComponent("AppIcon.png"))
        }
    }
}

let converter = Process()
converter.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
converter.arguments = ["-c", "icns", iconset.path, "-o", output.appendingPathComponent("AppIcon.icns").path]
try converter.run()
converter.waitUntilExit()
guard converter.terminationStatus == 0 else { exit(converter.terminationStatus) }
try FileManager.default.removeItem(at: iconset)
