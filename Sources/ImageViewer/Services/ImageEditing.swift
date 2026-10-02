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

        try rewrite(url, source: source, type: type, options: [kCGImageDestinationOrientation: target])
    }

    /// Changes the image's metadata, keeping every other tag (EXIF, GPS, orientation…). Pixels and
    /// "date modified" are left untouched. `change` gets either an empty set of values to merge in
    /// (`merging` true: an empty value clears a field) or a full copy of the metadata to edit.
    static func updateMetadata(of url: URL, _ change: (_ metadata: CGMutableImageMetadata, _ merging: Bool) -> Bool) throws {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let type = CGImageSourceGetType(source)
        else { throw EditError.unsupported(url.lastPathComponent) }
        if UTType(type as String) == .png {
            // ImageIO's in-place copy can't add XMP to a PNG that has none, and can't clear values in
            // one that does. PNG is lossless, so re-encoding the pixels with new metadata is exact.
            let metadata = CGImageSourceCopyMetadataAtIndex(source, 0, nil)
                .flatMap { CGImageMetadataCreateMutableCopy($0) } ?? CGImageMetadataCreateMutable()
            guard change(metadata, false), let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
            else { throw EditError.unsupported(url.lastPathComponent) }
            try replace(url, keepModificationDate: true) { temp in
                guard let destination = CGImageDestinationCreateWithURL(temp as CFURL, type, 1, nil) else { return false }
                CGImageDestinationAddImageAndMetadata(destination, image, metadata, nil)
                return CGImageDestinationFinalize(destination)
            }
            return
        }
        let metadata = CGImageMetadataCreateMutable()
        guard change(metadata, true) else { throw EditError.unsupported(url.lastPathComponent) }
        try rewrite(url, source: source, type: type, options: [
            kCGImageDestinationMetadata: metadata,
            kCGImageDestinationMergeMetadata: true,
        ], keepModificationDate: true)
    }

    /// Re-saves a file with changed metadata only (no re-compression of the pixels). Writes next to
    /// the original under a hidden name, then swaps it in, so a failure never damages the file.
    static func rewrite(
        _ url: URL, source: CGImageSource, type: CFString, options: [CFString: Any], keepModificationDate: Bool = false
    ) throws {
        try replace(url, keepModificationDate: keepModificationDate) { temp in
            guard let destination = CGImageDestinationCreateWithURL(temp as CFURL, type, CGImageSourceGetCount(source), nil)
            else { return false }
            return CGImageDestinationCopyImageSource(destination, source, options as CFDictionary, nil)
        }
    }

    /// Has `write` produce the new file under a hidden name next to `url`, then swaps it in.
    private static func replace(_ url: URL, keepModificationDate: Bool, write: (URL) -> Bool) throws {
        let dates = try? FileManager.default.attributesOfItem(atPath: url.path)
        let temp = url.deletingLastPathComponent()
            .appendingPathComponent(".\(UUID().uuidString)-\(url.lastPathComponent)")
        defer { try? FileManager.default.removeItem(at: temp) }
        guard write(temp) else { throw EditError.unsupported(url.lastPathComponent) }
        _ = try FileManager.default.replaceItemAt(url, withItemAt: temp)
        if keepModificationDate, let modified = dates?[.modificationDate] {
            try? FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
        }
    }
}

// MARK: - Ratings

/// Star ratings stored *in the image file* as the standard XMP "Rating" (0–5, −1 = rejected),
/// which Lightroom, Bridge, Capture One, digiKam and Windows Explorer also read.
enum Ratings {
    static let rejected = -1
    static let range = -1...5

    /// Formats whose metadata can be rewritten in place without re-compressing.
    private static let writableTypes: [UTType] = [.jpeg, .heic, .heif, .png, .tiff]
    /// MP4 / M4V / MOV: the rating goes in an embedded XMP box (see `VideoXMP`).
    private static let videoTypes: [UTType] = [.mpeg4Movie, .quickTimeMovie]

    static func canStore(in item: FileItem) -> Bool {
        guard !item.isDirectory, !item.isRaw,
              let type = UTType(filenameExtension: item.url.pathExtension)
        else { return false }
        return (item.isVideo ? videoTypes : writableTypes).contains { type.conforms(to: $0) }
    }

    private static func isVideo(_ url: URL) -> Bool {
        UTType(filenameExtension: url.pathExtension)?.conforms(to: .movie) ?? false
    }

    static func read(from source: CGImageSource) -> Int? {
        guard let metadata = CGImageSourceCopyMetadataAtIndex(source, 0, nil),
              let value = CGImageMetadataCopyStringValueWithPath(metadata, nil, "xmp:Rating" as CFString) as String?,
              let rating = Int(value.trimmingCharacters(in: .whitespaces)) ?? Double(value).map({ Int($0) })
        else { return nil }
        return min(max(rating, range.lowerBound), range.upperBound)
    }

    static func read(_ url: URL) -> Int? {
        if isVideo(url) { return VideoXMP.readRating(from: url) }
        return CGImageSourceCreateWithURL(url as CFURL, nil).flatMap(read(from:))
    }

    /// Writes the rating into the file. Pixels / video data and "date modified" are left untouched.
    static func write(_ rating: Int, to url: URL) throws {
        guard range.contains(rating) else { throw ImageEditing.EditError.unsupported(url.lastPathComponent) }
        if isVideo(url) {
            try VideoXMP.writeRating(rating, to: url)
            return
        }
        try ImageEditing.updateMetadata(of: url) { metadata, _ in
            CGImageMetadataSetValueWithPath(metadata, nil, "xmp:Rating" as CFString, "\(rating)" as CFString)
        }
    }

    static func stars(_ rating: Int) -> String {
        rating == rejected ? "Rejected" : rating == 0 ? "No rating" : String(repeating: "★", count: rating) + String(repeating: "☆", count: 5 - rating)
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
