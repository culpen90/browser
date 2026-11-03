import AppKit

let output = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".build/Browser.iconset")
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = points * scale
        let image = NSImage(size: NSSize(width: pixels, height: pixels), flipped: false) { rect in
            let size = rect.width
            let inset = size * 0.06
            let shape = NSBezierPath(roundedRect: rect.insetBy(dx: inset, dy: inset), xRadius: size * 0.21, yRadius: size * 0.21)
            NSGradient(starting: NSColor(srgbRed: 0.12, green: 0.41, blue: 0.92, alpha: 1), ending: NSColor(srgbRed: 0.1, green: 0.19, blue: 0.56, alpha: 1))!.draw(in: shape, angle: -60)
            let globe = rect.insetBy(dx: size * 0.23, dy: size * 0.23)
            NSColor.white.setStroke()
            let circle = NSBezierPath(ovalIn: globe); circle.lineWidth = size * 0.025; circle.stroke()
            let meridian = NSBezierPath(ovalIn: globe.insetBy(dx: globe.width * 0.27, dy: 0)); meridian.lineWidth = size * 0.02; meridian.stroke()
            let equator = NSBezierPath(); equator.move(to: NSPoint(x: globe.minX, y: globe.midY)); equator.line(to: NSPoint(x: globe.maxX, y: globe.midY)); equator.lineWidth = size * 0.02; equator.stroke()
            return true
        }
        let data = image.tiffRepresentation!
        let png = NSBitmapImageRep(data: data)!.representation(using: .png, properties: [:])!
        let name = "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"
        try png.write(to: output.appendingPathComponent(name))
    }
}
