import AVFoundation
import CoreLocation
import Foundation
import ImageIO
import Vision

struct Coordinate: Hashable, Sendable {
    let latitude: Double
    let longitude: Double

    var location: CLLocationCoordinate2D { .init(latitude: latitude, longitude: longitude) }
}

/// Facts read from a file's metadata once per folder load: when it was taken and where.
struct MediaInfo: Sendable {
    var captureDate: Date?
    var coordinate: Coordinate?
}

enum MediaIndex {
    static func read(_ item: FileItem) async -> MediaInfo {
        item.isVideo ? await readVideo(item.url) : readImage(item.url)
    }

    static func readImage(_ url: URL) -> MediaInfo {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        else { return MediaInfo() }
        var info = MediaInfo()
        let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
        let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
        let dateString = (exif[kCGImagePropertyExifDateTimeOriginal] as? String)
            ?? (exif[kCGImagePropertyExifDateTimeDigitized] as? String)
            ?? (tiff[kCGImagePropertyTIFFDateTime] as? String)
        if let dateString {
            info.captureDate = exifDateParser.date(from: dateString)
        }
        let gps = props[kCGImagePropertyGPSDictionary] as? [CFString: Any] ?? [:]
        if var latitude = (gps[kCGImagePropertyGPSLatitude] as? NSNumber)?.doubleValue,
           var longitude = (gps[kCGImagePropertyGPSLongitude] as? NSNumber)?.doubleValue {
            if (gps[kCGImagePropertyGPSLatitudeRef] as? String) == "S" { latitude = -latitude }
            if (gps[kCGImagePropertyGPSLongitudeRef] as? String) == "W" { longitude = -longitude }
            info.coordinate = Coordinate(latitude: latitude, longitude: longitude)
        }
        return info
    }

    private static func readVideo(_ url: URL) async -> MediaInfo {
        let asset = AVURLAsset(url: url)
        var info = MediaInfo()
        if let item = try? await asset.load(.creationDate) {
            info.captureDate = try? await item.load(.dateValue)
        }
        // Phones store location as an ISO 6709 string, e.g. "+37.3349-122.0090+010.000/".
        if let metadata = try? await asset.load(.commonMetadata),
           let location = AVMetadataItem.metadataItems(from: metadata, filteredByIdentifier: .commonIdentifierLocation).first,
           let string = try? await location.load(.stringValue) {
            info.coordinate = parseISO6709(string)
        }
        return info
    }

    static func parseISO6709(_ string: String) -> Coordinate? {
        guard let regex = try? Regex(#"^([+-]\d+(?:\.\d+)?)([+-]\d+(?:\.\d+)?)"#),
              let match = string.firstMatch(of: regex),
              match.count == 3,
              let latitude = match[1].substring.flatMap({ Double($0) }),
              let longitude = match[2].substring.flatMap({ Double($0) })
        else { return nil }
        return Coordinate(latitude: latitude, longitude: longitude)
    }

    static let exifDateParser: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        return formatter
    }()
}

/// On-device image recognition (Apple's Vision framework) used by search, e.g. "beach" or "dog".
/// Results are cached on disk, keyed by path and modification date, so each photo is analyzed once.
actor ContentAnalyzer {
    static let shared = ContentAnalyzer()

    private var cache: [String: [String]]
    private var unsavedChanges = 0
    private let cacheURL: URL = {
        let directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("local.imageviewer", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("content-labels.json")
    }()

    private init() {
        let directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("local.imageviewer", isDirectory: true)
        let data = try? Data(contentsOf: directory.appendingPathComponent("content-labels.json"))
        cache = data.flatMap { try? JSONDecoder().decode([String: [String]].self, from: $0) } ?? [:]
    }

    func cachedLabels(for item: FileItem) -> [String]? {
        cache[key(item)]
    }

    func labels(for item: FileItem) -> [String] {
        if let cached = cache[key(item)] { return cached }
        let labels = Self.classify(item.url)
        cache[key(item)] = labels
        unsavedChanges += 1
        if unsavedChanges >= 100 { save() }
        return labels
    }

    func save() {
        guard unsavedChanges > 0, let data = try? JSONEncoder().encode(cache) else { return }
        try? data.write(to: cacheURL, options: .atomic)
        unsavedChanges = 0
    }

    private func key(_ item: FileItem) -> String {
        "\(item.url.path)|\(item.modified.timeIntervalSince1970)"
    }

    private static func classify(_ url: URL) -> [String] {
        guard let image = downsampled(url, maxPixel: 512) else { return [] }
        let request = VNClassifyImageRequest()
        guard (try? VNImageRequestHandler(cgImage: image).perform([request])) != nil else { return [] }
        return (request.results ?? [])
            .filter { $0.confidence >= 0.25 }
            .prefix(20)
            .map { $0.identifier.replacingOccurrences(of: "_", with: " ") }
    }

    static func downsampled(_ url: URL, maxPixel: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else {
            return nil
        }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ] as CFDictionary)
    }
}
