import Foundation
import ImageIO
import UniformTypeIdentifiers

// MARK: - Lossless rotate / flip

/// Rotations and flips are applied by changing the file's orientation tag, not its pixels,
/// so nothing is re-compressed. Works for JPEG, HEIC, PNG and TIFF; not for camera RAW.
enum OrientationChange: String {
    case rotateLeft = "Rotate Left"
    case rotateRight = "Rotate Right"
    case flipHorizontal = "Flip Horizontal"
    case flipVertical = "Flip Vertical"

    var inverse: OrientationChange {
        switch self {
        case .rotateLeft: .rotateRight
        case .rotateRight: .rotateLeft
        case .flipHorizontal, .flipVertical: self
        }
    }

    /// 2×2 transforms in screen coordinates (y points down).
    private typealias Matrix = (Int, Int, Int, Int)

    private var matrix: Matrix {
        switch self {
        case .rotateRight: (0, -1, 1, 0)
        case .rotateLeft: (0, 1, -1, 0)
        case .flipHorizontal: (-1, 0, 0, 1)
        case .flipVertical: (1, 0, 0, -1)
        }
    }

    /// How each EXIF orientation (1–8) transforms the stored pixels for display.
    private static let exif: [Int: Matrix] = [
        1: (1, 0, 0, 1),   // normal
        2: (-1, 0, 0, 1),  // mirrored horizontally
        3: (-1, 0, 0, -1), // rotated 180°
        4: (1, 0, 0, -1),  // mirrored vertically
        5: (0, 1, 1, 0),   // mirrored, rotated 90° CCW (transpose)
        6: (0, -1, 1, 0),  // rotated 90° CW
        7: (0, -1, -1, 0), // mirrored, rotated 90° CW (transverse)
        8: (0, 1, -1, 0),  // rotated 90° CCW
    ]

    /// The orientation value after applying this change on top of `orientation`.
    func applied(to orientation: Int) -> Int {
        let current = Self.exif[orientation] ?? Self.exif[1]!
        let (a, b, c, d) = matrix
        let (e, f, g, h) = current
        let product = (a * e + b * g, a * f + b * h, c * e + d * g, c * f + d * h)
        return Self.exif.first { $0.value == product }?.key ?? 1
    }
}

enum ImageEditing {
    enum EditError: LocalizedError {
        case unsupported(String)
        var errorDescription: String? {
            switch self {
            case .unsupported(let name): "“\(name)” can't be rotated without re-compressing it (camera RAW and some formats can't be changed in place)."
            }
        }
    }

    static func changeOrientation(of url: URL, by change: OrientationChange) throws {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let type = CGImageSourceGetType(source),
              !(UTType(type as String)?.conforms(to: .rawImage) ?? false)
        else { throw EditError.unsupported(url.lastPathComponent) }

        let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let current = (props?[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        let target = change.applied(to: current)

        // Write next to the original (hidden name), then swap it in so a failure never damages the file.
        let temp = url.deletingLastPathComponent()
            .appendingPathComponent(".\(UUID().uuidString)-\(url.lastPathComponent)")
        defer { try? FileManager.default.removeItem(at: temp) }
        guard let destination = CGImageDestinationCreateWithURL(temp as CFURL, type, CGImageSourceGetCount(source), nil) else {
            throw EditError.unsupported(url.lastPathComponent)
        }
        let options = [kCGImageDestinationOrientation: target] as CFDictionary
        guard CGImageDestinationCopyImageSource(destination, source, options, nil) else {
            throw EditError.unsupported(url.lastPathComponent)
        }
        _ = try FileManager.default.replaceItemAt(url, withItemAt: temp)
    }
}

// MARK: - Export

struct ExportOptions {
    enum Format: String, CaseIterable, Identifiable {
        case jpeg = "JPEG", heic = "HEIC", png = "PNG", tiff = "TIFF"
        var id: String { rawValue }
        var type: UTType {
            switch self {
            case .jpeg: .jpeg
            case .heic: .heic
            case .png: .png
            case .tiff: .tiff
            }
        }
        var isLossy: Bool { self == .jpeg || self == .heic }
        var fileExtension: String {
            switch self {
            case .jpeg: "jpg"
            case .heic: "heic"
            case .png: "png"
            case .tiff: "tif"
            }
        }

        /// HEIC encoding depends on the Mac's hardware/OS.
        static var available: [Format] {
            let supported = Set((CGImageDestinationCopyTypeIdentifiers() as? [String]) ?? [])
            return allCases.filter { supported.contains($0.type.identifier) }
        }
    }

    var format: Format = .jpeg
    /// Longest edge in pixels; nil keeps the original size.
    var maxPixelSize: Int?
    var quality: Double = 0.85
    var keepMetadata = true
    var removeLocation = true
}

enum Exporter {
    /// Writes one converted copy into `directory` and returns its URL. Never overwrites.
    static func export(_ url: URL, to directory: URL, options: ExportOptions) throws -> URL {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
        let width = (props[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue ?? 0
        let height = (props[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue ?? 0
        let longest = max(width, height)
        var decode: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true, // bake orientation into the pixels
        ]
        if longest > 0 {
            decode[kCGImageSourceThumbnailMaxPixelSize] = min(options.maxPixelSize ?? longest, longest)
        }
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, decode as CFDictionary) else {
            throw CocoaError(.fileReadCorruptFile)
        }

        let base = url.deletingPathExtension().lastPathComponent
        var output = directory.appendingPathComponent("\(base).\(options.format.fileExtension)")
        var counter = 2
        while FileManager.default.fileExists(atPath: output.path) {
            output = directory.appendingPathComponent("\(base) \(counter).\(options.format.fileExtension)")
            counter += 1
        }

        guard let destination = CGImageDestinationCreateWithURL(
            output as CFURL, options.format.type.identifier as CFString, 1, nil
        ) else { throw CocoaError(.fileWriteUnknown) }

        var properties: [CFString: Any] = [:]
        if options.keepMetadata {
            for key in [kCGImagePropertyExifDictionary, kCGImagePropertyTIFFDictionary, kCGImagePropertyIPTCDictionary, kCGImagePropertyGPSDictionary] {
                if let value = props[key] { properties[key] = value }
            }
            if options.removeLocation {
                properties[kCGImagePropertyGPSDictionary] = nil
            }
            // Pixels were already rotated upright above.
            if var tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
                tiff[kCGImagePropertyTIFFOrientation] = 1
                properties[kCGImagePropertyTIFFDictionary] = tiff
            }
        }
        properties[kCGImagePropertyOrientation] = 1
        if options.format.isLossy {
            properties[kCGImageDestinationLossyCompressionQuality] = options.quality
        }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            try? FileManager.default.removeItem(at: output)
            throw CocoaError(.fileWriteUnknown)
        }
        return output
    }
}

// MARK: - Histogram

struct Histogram: Sendable {
    var red = [Double](repeating: 0, count: 256)
    var green = [Double](repeating: 0, count: 256)
    var blue = [Double](repeating: 0, count: 256)
    var luminance = [Double](repeating: 0, count: 256)

    /// Computed from a 512px downsample: fast, and statistically the same shape as full size.
    static func compute(for url: URL) -> Histogram? {
        guard let image = ContentAnalyzer.downsampled(url, maxPixel: 512) else { return nil }
        let width = image.width, height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                  space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              )
        else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        var histogram = Histogram()
        for i in stride(from: 0, to: pixels.count, by: 4) {
            let r = Int(pixels[i]), g = Int(pixels[i + 1]), b = Int(pixels[i + 2])
            histogram.red[r] += 1
            histogram.green[g] += 1
            histogram.blue[b] += 1
            histogram.luminance[(r * 2126 + g * 7152 + b * 722) / 10000] += 1
        }
        // Normalize to the tallest bin, ignoring pure black/white spikes so they don't flatten the rest.
        let peak = [histogram.red, histogram.green, histogram.blue, histogram.luminance]
            .flatMap { $0[1...254] }.max() ?? 1
        func normalize(_ values: [Double]) -> [Double] { values.map { min(1, $0 / max(peak, 1)) } }
        histogram.red = normalize(histogram.red)
        histogram.green = normalize(histogram.green)
        histogram.blue = normalize(histogram.blue)
        histogram.luminance = normalize(histogram.luminance)
        return histogram
    }
}
