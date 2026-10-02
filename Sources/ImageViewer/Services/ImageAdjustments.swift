import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Color and light adjustments like Preview's Adjust Color panel. All sliders run −1…1 (0 = unchanged),
/// except sharpness (0…1).
struct Adjustments: Equatable, Sendable {
    var exposure = 0.0
    var contrast = 0.0
    var highlights = 0.0
    var shadows = 0.0
    var saturation = 0.0
    var vibrance = 0.0
    var temperature = 0.0
    var tint = 0.0
    var sharpness = 0.0
    /// Apple's automatic enhancement (the same analysis Photos' magic wand uses), applied first.
    var auto = false

    var isUnchanged: Bool { self == Adjustments() }
}

enum ImageAdjuster {
    enum AdjustError: LocalizedError {
        case unreadable(String)
        case unwritable(String)
        var errorDescription: String? {
            switch self {
            case .unreadable(let name): "“\(name)” couldn't be read."
            case .unwritable(let name): "“\(name)” couldn't be saved."
            }
        }
    }

    /// Formats saved back in their own format. Anything else (RAW, WebP, GIF, BMP…) can only be
    /// saved as a JPEG copy.
    static let overwritableTypes: [UTType] = [.jpeg, .heic, .heif, .png, .tiff]

    static func canOverwrite(_ url: URL) -> Bool {
        guard let type = UTType(filenameExtension: url.pathExtension),
              overwritableTypes.contains(where: { type.conforms(to: $0) }),
              let source = CGImageSourceCreateWithURL(url as CFURL, nil)
        else { return false }
        return CGImageSourceGetCount(source) == 1 // not animations or multi-page files
    }

    static func canAdjust(_ item: FileItem) -> Bool {
        !item.isDirectory && !item.isVideo
    }

    static let context = CIContext(options: [.cacheIntermediates: false])

    /// The full image, upright. RAW files are developed with Apple's RAW engine.
    static func fullImage(_ url: URL) -> CIImage? {
        if UTType(filenameExtension: url.pathExtension)?.conforms(to: .rawImage) == true,
           let raw = CIRAWFilter(imageURL: url), let image = raw.outputImage {
            return image
        }
        return CIImage(contentsOf: url, options: [.applyOrientationProperty: true])
    }

    /// A screen-sized upright copy for the live preview (fast to re-render on every slider move).
    static func previewImage(_ url: URL, maxPixel: Int = 2400) -> CIImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceThumbnailMaxPixelSize: maxPixel,
              ] as CFDictionary)
        else { return nil }
        return CIImage(cgImage: image)
    }

    /// Apple's automatic enhancement filters for this image.
    static func autoFilters(for image: CIImage) -> [CIFilter] {
        image.autoAdjustmentFilters(options: [.redEye: false])
    }

    static func apply(_ adjustments: Adjustments, to input: CIImage, autoFilters: [CIFilter] = []) -> CIImage {
        let extent = input.extent
        var image = input
        if adjustments.auto {
            for filter in autoFilters {
                guard let copy = filter.copy() as? CIFilter else { continue }
                copy.setValue(image, forKey: kCIInputImageKey)
                image = copy.outputImage ?? image
            }
        }
        // Scale-dependent radii are relative to the image size, so the preview matches the saved file.
        let scale = max(extent.width, extent.height) / 1000

        if adjustments.exposure != 0 {
            let filter = CIFilter.exposureAdjust()
            filter.inputImage = image
            filter.ev = Float(adjustments.exposure * 2) // ±2 stops
            image = filter.outputImage ?? image
        }
        if adjustments.highlights != 0 || adjustments.shadows != 0 {
            let filter = CIFilter.highlightShadowAdjust()
            filter.inputImage = image
            filter.highlightAmount = Float(1 + min(adjustments.highlights, 0)) // left: recover highlights
            filter.shadowAmount = Float(adjustments.shadows) // right: lift shadows
            filter.radius = Float(max(1, 10 * scale))
            image = filter.outputImage ?? image
            if adjustments.highlights > 0 { // right: brighten the highlights
                let curve = CIFilter.toneCurve()
                curve.inputImage = image
                let lift = Float(adjustments.highlights) * 0.12
                curve.point0 = CGPoint(x: 0, y: 0)
                curve.point1 = CGPoint(x: 0.25, y: 0.25)
                curve.point2 = CGPoint(x: 0.5, y: 0.5)
                curve.point3 = CGPoint(x: 0.75, y: CGFloat(0.75 + lift))
                curve.point4 = CGPoint(x: 1, y: 1)
                image = curve.outputImage ?? image
            }
        }
        if adjustments.contrast != 0 || adjustments.saturation != 0 {
            let filter = CIFilter.colorControls()
            filter.inputImage = image
            filter.contrast = Float(1 + adjustments.contrast * 0.5) // 0.5…1.5
            filter.saturation = Float(1 + adjustments.saturation) // 0 (gray)…2
            filter.brightness = 0
            image = filter.outputImage ?? image
        }
        if adjustments.vibrance != 0 {
            let filter = CIFilter.vibrance()
            filter.inputImage = image
            filter.amount = Float(adjustments.vibrance)
            image = filter.outputImage ?? image
        }
        if adjustments.temperature != 0 || adjustments.tint != 0 {
            let filter = CIFilter.temperatureAndTint()
            filter.inputImage = image
            // Telling Core Image the light was warmer than it was makes it compensate toward warm.
            filter.neutral = CIVector(x: 6500 + adjustments.temperature * 3000, y: adjustments.tint * 100)
            filter.targetNeutral = CIVector(x: 6500, y: 0)
            image = filter.outputImage ?? image
        }
        if adjustments.sharpness > 0 {
            let filter = CIFilter.unsharpMask()
            filter.inputImage = image
            filter.radius = Float(max(1, 2.5 * scale))
            filter.intensity = Float(adjustments.sharpness * 1.2)
            image = filter.outputImage ?? image
        }
        return image.cropped(to: extent)
    }

    static func render(_ image: CIImage, colorSpace: CGColorSpace? = nil) -> CGImage? {
        let space = colorSpace ?? image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
        return context.createCGImage(image, from: image.extent, format: .RGBA8, colorSpace: space)
    }

    /// Where a copy goes: "IMG_1234 (edited).jpg", then "(edited 2)"… Never overwrites anything.
    static func copyURL(for url: URL) -> URL {
        let folder = url.deletingLastPathComponent()
        let base = url.deletingPathExtension().lastPathComponent
        let ext = canOverwrite(url) ? url.pathExtension : "jpg"
        var candidate = folder.appendingPathComponent("\(base) (edited).\(ext)")
        var counter = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = folder.appendingPathComponent("\(base) (edited \(counter)).\(ext)")
            counter += 1
        }
        return candidate
    }

    /// Renders the adjustments at full resolution and writes them to `output`, keeping the original's
    /// metadata (date taken, location, camera, rating, tags…). The pixels are saved upright, so the
    /// orientation tag is reset. `output` may be `url` itself (overwrite); that's written to a
    /// temporary file first and swapped in, so a failure never damages the original.
    static func save(_ adjustments: Adjustments, from url: URL, to output: URL) throws {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let full = fullImage(url)
        else { throw AdjustError.unreadable(url.lastPathComponent) }
        let autoFilters = adjustments.auto ? autoFilters(for: full) : []
        guard let rendered = render(apply(adjustments, to: full, autoFilters: autoFilters), colorSpace: full.colorSpace)
        else { throw AdjustError.unwritable(output.lastPathComponent) }

        let sameFormat = canOverwrite(url) && output.pathExtension.lowercased() == url.pathExtension.lowercased()
        let type = sameFormat ? (CGImageSourceGetType(source) ?? UTType.jpeg.identifier as CFString) : UTType.jpeg.identifier as CFString
        let metadata = CGImageSourceCopyMetadataAtIndex(source, 0, nil)
            .flatMap { CGImageMetadataCreateMutableCopy($0) } ?? CGImageMetadataCreateMutable()
        CGImageMetadataSetValueMatchingImageProperty(metadata, kCGImagePropertyTIFFDictionary, kCGImagePropertyTIFFOrientation, 1 as CFNumber)
        for key in [kCGImagePropertyExifPixelXDimension, kCGImagePropertyExifPixelYDimension] {
            CGImageMetadataSetValueMatchingImageProperty(
                metadata, kCGImagePropertyExifDictionary, key,
                (key == kCGImagePropertyExifPixelXDimension ? rendered.width : rendered.height) as CFNumber
            )
        }

        let temp = output.deletingLastPathComponent()
            .appendingPathComponent(".\(UUID().uuidString)-\(output.lastPathComponent)")
        defer { try? FileManager.default.removeItem(at: temp) }
        guard let destination = CGImageDestinationCreateWithURL(temp as CFURL, type, 1, nil)
        else { throw AdjustError.unwritable(output.lastPathComponent) }
        CGImageDestinationAddImageAndMetadata(destination, rendered, metadata, [
            kCGImageDestinationLossyCompressionQuality: 0.92,
            kCGImagePropertyOrientation: 1,
        ] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw AdjustError.unwritable(output.lastPathComponent) }
        if FileManager.default.fileExists(atPath: output.path) {
            _ = try FileManager.default.replaceItemAt(output, withItemAt: temp)
        } else {
            try FileManager.default.moveItem(at: temp, to: output)
        }
    }

    // MARK: Undo for overwrites

    /// Originals replaced by "Overwrite Original" are kept here (for Undo) for a week.
    static let backupFolder = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("local.imageviewer/EditBackups", isDirectory: true)

    static func backUp(_ url: URL) throws -> URL {
        try FileManager.default.createDirectory(at: backupFolder, withIntermediateDirectories: true)
        let backup = backupFolder.appendingPathComponent("\(UUID().uuidString)-\(url.lastPathComponent)")
        try FileManager.default.copyItem(at: url, to: backup)
        return backup
    }

    /// Puts a backed-up original back (and keeps the backup, so Redo/Undo can repeat).
    static func restore(_ backup: URL, to url: URL) throws {
        let temp = url.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString)-\(url.lastPathComponent)")
        try FileManager.default.copyItem(at: backup, to: temp)
        _ = try FileManager.default.replaceItemAt(url, withItemAt: temp)
    }

    static func pruneBackups(olderThan age: TimeInterval = 7 * 24 * 3600) {
        let keys: [URLResourceKey] = [.creationDateKey]
        let files = (try? FileManager.default.contentsOfDirectory(at: backupFolder, includingPropertiesForKeys: keys)) ?? []
        for file in files {
            let created = (try? file.resourceValues(forKeys: Set(keys)))?.creationDate ?? .distantPast
            if Date().timeIntervalSince(created) > age { try? FileManager.default.removeItem(at: file) }
        }
    }
}
