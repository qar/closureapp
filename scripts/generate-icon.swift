import AppKit

let size = 1024
let output = CommandLine.arguments.dropFirst().first ?? "assets/ClosureIcon.png"
guard let bitmap = NSBitmapImageRep(
    bitmapDataPlanes: nil,
    pixelsWide: size,
    pixelsHigh: size,
    bitsPerSample: 8,
    samplesPerPixel: 4,
    hasAlpha: true,
    isPlanar: false,
    colorSpaceName: .deviceRGB,
    bytesPerRow: 0,
    bitsPerPixel: 0
), let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
    fatalError("Unable to create the icon bitmap")
}

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = context
context.imageInterpolation = .high

let tile = NSBezierPath(roundedRect: NSRect(x: 80, y: 80, width: 864, height: 864),
                        xRadius: 190, yRadius: 190)
let shadow = NSShadow()
shadow.shadowColor = NSColor(calibratedWhite: 0, alpha: 0.20)
shadow.shadowBlurRadius = 34
shadow.shadowOffset = NSSize(width: 0, height: -18)
shadow.set()
NSColor(calibratedRed: 0.098, green: 0.141, blue: 0.114, alpha: 1).setFill()
tile.fill()
NSShadow().set()

let ring = NSBezierPath()
ring.appendArc(withCenter: NSPoint(x: 512, y: 512), radius: 250,
               startAngle: 48, endAngle: 312, clockwise: false)
ring.lineWidth = 78
ring.lineCapStyle = .round
NSColor(calibratedRed: 0.948, green: 0.961, blue: 0.922, alpha: 1).setStroke()
ring.stroke()

let bars: [(CGFloat, CGFloat, CGFloat)] = [
    (390, 445, 134),
    (486, 400, 224),
    (582, 430, 164)
]
for (x, y, height) in bars {
    let bar = NSBezierPath(roundedRect: NSRect(x: x, y: y, width: 52, height: height),
                           xRadius: 26, yRadius: 26)
    NSColor(calibratedRed: 0.948, green: 0.961, blue: 0.922, alpha: 1).setFill()
    bar.fill()
}

let accent = NSBezierPath(ovalIn: NSRect(x: 742, y: 474, width: 76, height: 76))
NSColor(calibratedRed: 0.98, green: 0.45, blue: 0.32, alpha: 1).setFill()
accent.fill()

context.flushGraphics()
NSGraphicsContext.restoreGraphicsState()

guard let png = bitmap.representation(using: .png, properties: [:]) else {
    fatalError("Unable to encode the icon")
}
try png.write(to: URL(fileURLWithPath: output))
