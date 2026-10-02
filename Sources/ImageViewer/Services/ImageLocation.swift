import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Adding, changing or removing where a photo was taken: the standard EXIF GPS fields, which Photos,
/// Lightroom and every map app read. Pixels and "date modified" are untouched; everything else in
/// the file (date taken, camera, rating, tags…) is kept.
enum ImageLocation {
    private static let types: [UTType] = [.jpeg, .heic, .heif, .png, .tiff]

    /// Photos only: videos keep their location somewhere else, and RAW files can't be rewritten.
    static func canStore(in item: FileItem) -> Bool {
        guard !item.isDirectory, !item.isVideo, !item.isRaw,
              let type = UTType(filenameExtension: item.url.pathExtension)
        else { return false }
        return types.contains { type.conforms(to: $0) }
    }

    /// Sets the location, or removes it when `coordinate` is nil.
    static func write(_ coordinate: Coordinate?, to url: URL) throws {
        try ImageEditing.replaceMetadata(of: url) { metadata in
            var gpsPaths: [String] = []
            CGImageMetadataEnumerateTagsUsingBlock(metadata, nil, nil) { path, _ in
                if (path as String).hasPrefix("exif:GPS") { gpsPaths.append(path as String) }
                return true
            }
            for path in gpsPaths {
                CGImageMetadataRemoveTagWithPath(metadata, nil, path as CFString)
            }
            guard let coordinate else { return true }
            let values: [(CFString, CFTypeRef)] = [
                (kCGImagePropertyGPSLatitude, abs(coordinate.latitude) as CFNumber),
                (kCGImagePropertyGPSLatitudeRef, (coordinate.latitude < 0 ? "S" : "N") as CFString),
                (kCGImagePropertyGPSLongitude, abs(coordinate.longitude) as CFNumber),
                (kCGImagePropertyGPSLongitudeRef, (coordinate.longitude < 0 ? "W" : "E") as CFString),
            ]
            return values.allSatisfy { key, value in
                CGImageMetadataSetValueMatchingImageProperty(metadata, kCGImagePropertyGPSDictionary, key, value)
            }
        }
    }

    /// "40.4168, -3.7038" (also with spaces only, or degree signs) → a coordinate.
    static func parse(_ text: String) -> Coordinate? {
        let numbers = text
            .replacingOccurrences(of: "°", with: " ")
            .split(whereSeparator: { $0 == "," || $0.isWhitespace })
            .compactMap { Double($0) }
        guard numbers.count == 2, abs(numbers[0]) <= 90, abs(numbers[1]) <= 180 else { return nil }
        return Coordinate(latitude: numbers[0], longitude: numbers[1])
    }
}
