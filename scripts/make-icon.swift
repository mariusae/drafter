// Draws the app icon: a sheet of paper on a deep blue squircle, with a pencil.
import AppKit

let size: CGFloat = 1024
let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { _ in
    let inset: CGFloat = 100
    let tile = NSRect(x: inset, y: inset, width: size - 2 * inset, height: size - 2 * inset)
    let squircle = NSBezierPath(roundedRect: tile, xRadius: 185, yRadius: 185)

    NSGraphicsContext.current?.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.3)
    shadow.shadowBlurRadius = 24
    shadow.shadowOffset = NSSize(width: 0, height: -10)
    shadow.set()
    NSGradient(starting: NSColor(calibratedRed: 0.20, green: 0.45, blue: 0.95, alpha: 1),
               ending: NSColor(calibratedRed: 0.10, green: 0.22, blue: 0.62, alpha: 1))!
        .draw(in: squircle, angle: -90)
    NSGraphicsContext.current?.restoreGraphicsState()

    // The page.
    let page = NSRect(x: 270, y: 210, width: 440, height: 580)
    NSGraphicsContext.current?.saveGraphicsState()
    let pageShadow = NSShadow()
    pageShadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
    pageShadow.shadowBlurRadius = 30
    pageShadow.shadowOffset = NSSize(width: 0, height: -12)
    pageShadow.set()
    NSColor(calibratedWhite: 0.99, alpha: 1).setFill()
    NSBezierPath(roundedRect: page, xRadius: 28, yRadius: 28).fill()
    NSGraphicsContext.current?.restoreGraphicsState()

    // A heading and lines of text.
    NSColor(calibratedWhite: 0.2, alpha: 1).setFill()
    NSBezierPath(roundedRect: NSRect(x: 320, y: 690, width: 250, height: 34), xRadius: 17, yRadius: 17).fill()
    NSColor(calibratedWhite: 0.72, alpha: 1).setFill()
    for (index, width) in [340.0, 310, 330, 250, 320, 180].enumerated() {
        let y = 610 - CGFloat(index) * 58
        NSBezierPath(roundedRect: NSRect(x: 320, y: y, width: width, height: 20), xRadius: 10, yRadius: 10).fill()
    }

    // The pencil.
    let config = NSImage.SymbolConfiguration(pointSize: 330, weight: .semibold)
        .applying(.init(paletteColors: [NSColor(calibratedRed: 1.0, green: 0.62, blue: 0.1, alpha: 1)]))
    if let pencil = NSImage(systemSymbolName: "pencil", accessibilityDescription: nil)?.withSymbolConfiguration(config) {
        NSGraphicsContext.current?.saveGraphicsState()
        let s = NSShadow()
        s.shadowColor = NSColor.black.withAlphaComponent(0.35)
        s.shadowBlurRadius = 16
        s.shadowOffset = NSSize(width: 0, height: -8)
        s.set()
        let bounds = pencil.size
        pencil.draw(in: NSRect(x: 540, y: 150, width: bounds.width, height: bounds.height))
        NSGraphicsContext.current?.restoreGraphicsState()
    }
    return true
}

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size),
                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
image.draw(in: NSRect(x: 0, y: 0, width: size, height: size))
NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
