import CoreGraphics
import Foundation
import ImageIO

let size = 1024
let repository = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
let source = repository.appendingPathComponent("assets/ClosureIconSource.jpeg")
let output = CommandLine.arguments.dropFirst().first.map { URL(fileURLWithPath: $0) }
    ?? repository.appendingPathComponent("assets/ClosureIcon.png")

guard let imageSource = CGImageSourceCreateWithURL(source as CFURL, nil),
      let artwork = CGImageSourceCreateImageAtIndex(imageSource, 0, nil),
      artwork.width == artwork.height else {
    fatalError("Unable to load square icon artwork from \(source.path)")
}

guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
      let context = CGContext(
        data: nil,
        width: size,
        height: size,
        bitsPerComponent: 8,
        bytesPerRow: size * 4,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
      ) else {
    fatalError("Unable to create the icon bitmap")
}

// macOS keeps the existing rounded tile and shadow around the approved artwork.
let bounds = CGRect(x: 80, y: 80, width: 864, height: 864)
let tile = CGPath(roundedRect: bounds, cornerWidth: 190, cornerHeight: 190, transform: nil)
context.saveGState()
context.setShadow(offset: CGSize(width: 0, height: -18), blur: 34,
                  color: CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.20))
context.addPath(tile)
context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
context.fillPath()
context.restoreGState()

context.addPath(tile)
context.clip()
context.interpolationQuality = .high
context.draw(artwork, in: bounds)

guard let image = context.makeImage(),
      let destination = CGImageDestinationCreateWithURL(output as CFURL, "public.png" as CFString, 1, nil) else {
    fatalError("Unable to create the PNG destination")
}
CGImageDestinationAddImage(destination, image, nil)
guard CGImageDestinationFinalize(destination) else {
    fatalError("Unable to write the icon")
}
print(output.path)
