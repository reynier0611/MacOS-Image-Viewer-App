import AppKit
import Foundation
import ImageIO
@testable import ImageViewer

/// A fresh temporary folder per test, removed when the value is deinitialized.
final class TempFolder {
    let url: URL

    init() {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ImageViewerTests-\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }

    func file(_ name: String) -> URL { url.appendingPathComponent(name) }
}

enum Fixtures {
    /// Draws an RGB image with the given drawing code (AppKit coordinates, origin bottom-left).
    static func image(width: Int, height: Int, draw: (CGContext) -> Void) -> CGImage {
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        draw(context)
        return context.makeImage()!
    }

    static func solid(_ color: CGColor, width: Int = 64, height: Int = 48) -> CGImage {
        image(width: width, height: height) { context in
            context.setFillColor(color)
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }
    }

    /// Left half red, right half blue: makes rotation direction easy to check.
    static func leftRedRightBlue(width: Int = 200, height: Int = 100) -> CGImage {
        image(width: width, height: height) { context in
            context.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: width / 2, height: height))
            context.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1))
            context.fill(CGRect(x: width / 2, y: 0, width: width - width / 2, height: height))
        }
    }

    static func text(_ lines: [String], width: Int = 1400, height: Int = 900) -> CGImage {
        image(width: width, height: height) { context in
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
            for (index, line) in lines.enumerated() {
                let y = CGFloat(height) - 200 - CGFloat(index) * 180
                (line as NSString).draw(at: NSPoint(x: 100, y: y), withAttributes: [
                    .font: NSFont.systemFont(ofSize: 64, weight: .semibold), .foregroundColor: NSColor.black,
                ])
            }
            NSGraphicsContext.restoreGraphicsState()
        }
    }

    /// Writes a JPEG (or another type) with optional EXIF date, GPS and orientation.
    @discardableResult
    static func write(
        _ image: CGImage, to url: URL, type: String = "public.jpeg",
        taken: String? = nil, latitude: Double? = nil, longitude: Double? = nil, orientation: Int? = nil
    ) -> URL {
        var properties: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: 0.95]
        if let taken {
            properties[kCGImagePropertyExifDictionary] = [kCGImagePropertyExifDateTimeOriginal: taken]
        }
        if let latitude, let longitude {
            properties[kCGImagePropertyGPSDictionary] = [
                kCGImagePropertyGPSLatitude: abs(latitude), kCGImagePropertyGPSLatitudeRef: latitude < 0 ? "S" : "N",
                kCGImagePropertyGPSLongitude: abs(longitude), kCGImagePropertyGPSLongitudeRef: longitude < 0 ? "W" : "E",
            ]
        }
        if let orientation {
            properties[kCGImagePropertyOrientation] = orientation
            properties[kCGImagePropertyTIFFDictionary] = [kCGImagePropertyTIFFOrientation: orientation]
        }
        let destination = CGImageDestinationCreateWithURL(url as CFURL, type as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        precondition(CGImageDestinationFinalize(destination))
        return url
    }

    static func orientation(of url: URL) -> Int {
        let source = CGImageSourceCreateWithURL(url as CFURL, nil)!
        let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        return (props?[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
    }

    /// The image as a viewer shows it (orientation applied).
    static func displayed(_ url: URL) -> CGImage {
        let source = CGImageSourceCreateWithURL(url as CFURL, nil)!
        return CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ] as CFDictionary)!
    }

    /// The pixels exactly as stored in the file (orientation ignored).
    static func stored(_ url: URL) -> CGImage {
        CGImageSourceCreateImageAtIndex(CGImageSourceCreateWithURL(url as CFURL, nil)!, 0, nil)!
    }

    /// RGB of the pixel at a relative position (0–1, from the top-left).
    static func color(of image: CGImage, x: Double, y: Double) -> (r: Int, g: Int, b: Int) {
        var pixel = [UInt8](repeating: 0, count: 4)
        let context = CGContext(
            data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        let px = Double(image.width) * x, py = Double(image.height) * (1 - y)
        context.draw(image, in: CGRect(x: -px, y: -py, width: Double(image.width), height: Double(image.height)))
        return (Int(pixel[0]), Int(pixel[1]), Int(pixel[2]))
    }

    static func item(_ url: URL) -> FileItem { FileItem(url: url)! }

    static let wallpapers = URL(fileURLWithPath: "/System/Library/Desktop Pictures")
}
