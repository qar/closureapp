import CoreGraphics
import Foundation
import ImageIO

let size = 1024
let repository = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()
let source = repository.appendingPathComponent("assets/ClosureIconSource.jpeg")
let output = CommandLine.arguments.dropFirst().first.map { URL(fileURLWithPath: $0) }
    ?? repository.appendingPathComponent("ios/Closure/Assets.xcassets/AppIcon.appiconset/AppIcon.png")

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
        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
      ) else {
    fatalError("Unable to create the icon bitmap")
}

// Preserve the approved artwork; iOS applies its own corner mask.
context.interpolationQuality = .high
context.draw(artwork, in: CGRect(x: 0, y: 0, width: size, height: size))

guard let image = context.makeImage(),
      let destination = CGImageDestinationCreateWithURL(output as CFURL, "public.png" as CFString, 1, nil) else {
    fatalError("Unable to create the PNG destination")
}
CGImageDestinationAddImage(destination, image, nil)
guard CGImageDestinationFinalize(destination) else {
    fatalError("Unable to write the icon")
}
print(output.path)
