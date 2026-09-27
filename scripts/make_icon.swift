// Draws the app icon and writes an .iconset folder. Usage: swift make_icon.swift <out.iconset>
import AppKit

let outDir = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

func render(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
        samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
        bytesPerRow: 0, bitsPerPixel: 0
    )!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(px)

    // Rounded-square body on the standard macOS icon grid.
    let body = NSRect(x: s * 0.098, y: s * 0.098, width: s * 0.804, height: s * 0.804)
    let bodyPath = NSBezierPath(roundedRect: body, xRadius: s * 0.18, yRadius: s * 0.18)
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.3)
    shadow.shadowBlurRadius = s * 0.02
    shadow.shadowOffset = NSSize(width: 0, height: -s * 0.01)
    NSGraphicsContext.saveGraphicsState()
    shadow.set()
    NSColor(calibratedWhite: 0.14, alpha: 1).setFill()
    bodyPath.fill()
    NSGraphicsContext.restoreGraphicsState()
    NSGradient(colors: [
        NSColor(calibratedRed: 0.16, green: 0.17, blue: 0.22, alpha: 1),
        NSColor(calibratedRed: 0.07, green: 0.07, blue: 0.10, alpha: 1),
    ])!.draw(in: bodyPath, angle: -90)

    // A back photo, tilted, and a front photo with a landscape.
    func photo(_ rect: NSRect, angle: CGFloat, drawScene: Bool) {
        NSGraphicsContext.saveGraphicsState()
        let transform = NSAffineTransform()
        transform.translateX(by: rect.midX, yBy: rect.midY)
        transform.rotate(byDegrees: angle)
        transform.translateX(by: -rect.midX, yBy: -rect.midY)
        transform.concat()

        let frameShadow = NSShadow()
        frameShadow.shadowColor = NSColor.black.withAlphaComponent(0.45)
        frameShadow.shadowBlurRadius = s * 0.025
        frameShadow.shadowOffset = NSSize(width: 0, height: -s * 0.008)
        NSGraphicsContext.saveGraphicsState()
        frameShadow.set()
        NSColor.white.setFill()
        NSBezierPath(roundedRect: rect, xRadius: s * 0.02, yRadius: s * 0.02).fill()
        NSGraphicsContext.restoreGraphicsState()

        let inner = rect.insetBy(dx: s * 0.022, dy: s * 0.022)
        let innerPath = NSBezierPath(roundedRect: inner, xRadius: s * 0.01, yRadius: s * 0.01)
        if drawScene {
            NSGraphicsContext.saveGraphicsState()
            innerPath.addClip()
            NSGradient(colors: [
                NSColor(calibratedRed: 1.00, green: 0.62, blue: 0.35, alpha: 1),
                NSColor(calibratedRed: 0.36, green: 0.42, blue: 0.95, alpha: 1),
            ])!.draw(in: inner, angle: 90)
            NSColor(calibratedRed: 1.0, green: 0.93, blue: 0.62, alpha: 1).setFill()
            let sun = s * 0.075
            NSBezierPath(ovalIn: NSRect(x: inner.maxX - sun * 2.1, y: inner.maxY - sun * 2.2, width: sun, height: sun)).fill()
            let far = NSBezierPath()
            far.move(to: NSPoint(x: inner.minX, y: inner.minY + inner.height * 0.30))
            far.line(to: NSPoint(x: inner.minX + inner.width * 0.62, y: inner.minY + inner.height * 0.68))
            far.line(to: NSPoint(x: inner.maxX, y: inner.minY + inner.height * 0.35))
            far.line(to: NSPoint(x: inner.maxX, y: inner.minY))
            far.line(to: NSPoint(x: inner.minX, y: inner.minY))
            NSColor(calibratedRed: 0.20, green: 0.24, blue: 0.52, alpha: 1).setFill()
            far.fill()
            let near = NSBezierPath()
            near.move(to: NSPoint(x: inner.minX, y: inner.minY + inner.height * 0.45))
            near.line(to: NSPoint(x: inner.minX + inner.width * 0.30, y: inner.minY + inner.height * 0.62))
            near.line(to: NSPoint(x: inner.minX + inner.width * 0.72, y: inner.minY + inner.height * 0.12))
            near.line(to: NSPoint(x: inner.minX + inner.width * 0.72, y: inner.minY))
            near.line(to: NSPoint(x: inner.minX, y: inner.minY))
            NSColor(calibratedRed: 0.10, green: 0.13, blue: 0.30, alpha: 1).setFill()
            near.fill()
            NSGraphicsContext.restoreGraphicsState()
        } else {
            NSColor(calibratedRed: 0.55, green: 0.60, blue: 0.70, alpha: 1).setFill()
            innerPath.fill()
        }
        NSGraphicsContext.restoreGraphicsState()
    }

    photo(NSRect(x: s * 0.24, y: s * 0.30, width: s * 0.50, height: s * 0.40), angle: 10, drawScene: false)
    photo(NSRect(x: s * 0.22, y: s * 0.25, width: s * 0.56, height: s * 0.44), angle: -4, drawScene: true)

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for size in [16, 32, 128, 256, 512] {
    try render(size).write(to: outDir.appendingPathComponent("icon_\(size)x\(size).png"))
    try render(size * 2).write(to: outDir.appendingPathComponent("icon_\(size)x\(size)@2x.png"))
}
