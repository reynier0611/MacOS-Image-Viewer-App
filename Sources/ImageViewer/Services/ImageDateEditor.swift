import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Writes a new capture date into a photo's EXIF and TIFF metadata.
///
/// Updates all three date fields so every reader sees the same value:
///   • EXIF DateTimeOriginal  — when the shutter fired (the canonical "date taken")
///   • EXIF DateTimeDigitized — when the image was stored digitally (same for cameras)
///   • TIFF DateTime          — general image date read by many apps
///
/// Only JPEG, HEIC, HEIF, PNG, and TIFF are supported (same set as location editing).
/// Video date is embedded in the container and can't be rewritten this way.
enum ImageDateEditor {
    static let exifFormat: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy:MM:dd HH:mm:ss"
        return f
    }()

    static func canEdit(_ url: URL) -> Bool {
        guard let type = UTType(filenameExtension: url.pathExtension) else { return false }
        return [UTType.jpeg, .heic, .heif, .png, .tiff].contains { type.conforms(to: $0) }
    }

    /// Rewrites the capture date in the file's own metadata, in-place.
    static func write(_ date: Date, to url: URL) throws {
        let string = exifFormat.string(from: date) as CFString
        try ImageEditing.updateMetadata(of: url) { metadata, _ in
            for (dict, key) in [
                (kCGImagePropertyExifDictionary, kCGImagePropertyExifDateTimeOriginal),
                (kCGImagePropertyExifDictionary, kCGImagePropertyExifDateTimeDigitized),
                (kCGImagePropertyTIFFDictionary, kCGImagePropertyTIFFDateTime),
            ] {
                CGImageMetadataSetValueMatchingImageProperty(metadata, dict, key, string)
            }
            return true
        }
    }
}
