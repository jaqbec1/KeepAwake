import AppKit

let directory = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        bitmap.size = NSSize(width: pixels, height: pixels)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        let width = CGFloat(pixels)
        NSColor(white: 0.13, alpha: 1).setFill()
        NSBezierPath(roundedRect: NSRect(x: width * 0.04, y: width * 0.04, width: width * 0.92, height: width * 0.92), xRadius: width * 0.20, yRadius: width * 0.20).fill()
        if let symbol = NSImage(systemSymbolName: "cup.and.saucer.fill", accessibilityDescription: nil)?.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: width * 0.56, weight: .regular)) {
            let rendered = NSImage(size: symbol.size)
            rendered.lockFocus()
            symbol.draw(at: .zero, from: .zero, operation: .sourceOver, fraction: 1)
            NSColor.systemOrange.setFill()
            NSRect(origin: .zero, size: symbol.size).fill(using: .sourceIn)
            rendered.unlockFocus()
            let ratio = min(width * 0.64 / symbol.size.width, width * 0.64 / symbol.size.height)
            let target = NSSize(width: symbol.size.width * ratio, height: symbol.size.height * ratio)
            rendered.draw(in: NSRect(x: (width - target.width) / 2, y: (width - target.height) / 2, width: target.width, height: target.height))
        }
        NSGraphicsContext.restoreGraphicsState()
        let suffix = scale == 2 ? "@2x" : ""
        try bitmap.representation(using: .png, properties: [:])!.write(to: directory.appendingPathComponent("icon_\(size)x\(size)\(suffix).png"))
    }
}
