import AVFoundation
import Foundation
import ImageIO
import UniformTypeIdentifiers

struct MetadataRow: Identifiable {
    let id = UUID()
    let label: String
    let value: String
}

struct MetadataSection: Identifiable {
    let id = UUID()
    let title: String
    let rows: [MetadataRow]
}

struct ImageMetadata {
    var sections: [MetadataSection] = []
    var rawProperties: [MetadataRow] = []
    var latitude: Double?
    var longitude: Double?

    static func load(for url: URL) async -> ImageMetadata {
        var metadata = loadFileAndImage(for: url)
        let isVideo = (try? url.resourceValues(forKeys: [.contentTypeKey]))?.contentType?.conforms(to: .movie) ?? false
        if isVideo, let video = await videoSection(for: url) {
            metadata.sections.insert(video, at: 1)
        }
        return metadata
    }

    private static func videoSection(for url: URL) async -> MetadataSection? {
        let asset = AVURLAsset(url: url)
        var rows: [MetadataRow] = []
        if let duration = try? await asset.load(.duration), duration.isNumeric {
            rows.append(.init(label: "Duration", value: formatDuration(duration.seconds)))
        }
        if let track = try? await asset.loadTracks(withMediaType: .video).first {
            if let (size, transform) = try? await track.load(.naturalSize, .preferredTransform) {
                let rect = CGRect(origin: .zero, size: size).applying(transform)
                rows.append(.init(label: "Dimensions", value: "\(Int(abs(rect.width))) × \(Int(abs(rect.height)))"))
            }
            if let fps = try? await track.load(.nominalFrameRate), fps > 0 {
                rows.append(.init(label: "Frame Rate", value: String(format: "%.3g fps", fps)))
            }
            if let format = try? await track.load(.formatDescriptions).first {
                rows.append(.init(label: "Codec", value: codecName(CMFormatDescriptionGetMediaSubType(format))))
            }
            if let rate = try? await track.load(.estimatedDataRate), rate > 0 {
                rows.append(.init(label: "Bit Rate", value: String(format: "%.1f Mbps", rate / 1_000_000)))
            }
        }
        if let audio = try? await asset.loadTracks(withMediaType: .audio) {
            rows.append(.init(label: "Audio", value: audio.isEmpty ? "None" : "Yes"))
        }
        if let item = try? await asset.load(.creationDate), let date = try? await item.load(.dateValue) {
            rows.append(.init(label: "Recorded", value: date.formatted(date: .abbreviated, time: .standard)))
        }
        return rows.isEmpty ? nil : MetadataSection(title: "Video", rows: rows)
    }

    private static func formatDuration(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        let (h, m, s) = (total / 3600, (total % 3600) / 60, total % 60)
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    private static func codecName(_ code: FourCharCode) -> String {
        let chars = [24, 16, 8, 0].map { Character(UnicodeScalar(UInt8((code >> $0) & 0xFF))) }
        let fourCC = String(chars).trimmingCharacters(in: .whitespaces)
        switch fourCC {
        case "avc1", "avc3": return "H.264"
        case "hvc1", "hev1": return "HEVC (H.265)"
        case "apcn", "apch", "apcs", "apco", "ap4h", "ap4x": return "Apple ProRes"
        case "av01": return "AV1"
        case "vp09": return "VP9"
        case "jpeg": return "Motion JPEG"
        default: return fourCC
        }
    }

    private static func loadFileAndImage(for url: URL) -> ImageMetadata {
        var metadata = ImageMetadata()
        let values = try? url.resourceValues(forKeys: [
            .contentTypeKey, .fileSizeKey, .creationDateKey, .contentModificationDateKey, .isDirectoryKey,
        ])

        var general = [MetadataRow(label: "Name", value: url.lastPathComponent)]
        if let type = values?.contentType {
            general.append(.init(label: "Kind", value: type.localizedDescription ?? type.identifier))
        }
        if let size = values?.fileSize {
            general.append(.init(label: "Size", value: ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)))
        }
        if let created = values?.creationDate {
            general.append(.init(label: "Created", value: created.formatted(date: .abbreviated, time: .shortened)))
        }
        if let modified = values?.contentModificationDate {
            general.append(.init(label: "Modified", value: modified.formatted(date: .abbreviated, time: .shortened)))
        }
        general.append(.init(label: "Where", value: (url.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath))
        metadata.sections.append(.init(title: "General", rows: general))

        guard values?.isDirectory != true,
              let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        else { return metadata }

        let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
        let exifAux = props[kCGImagePropertyExifAuxDictionary] as? [CFString: Any] ?? [:]
        let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
        let gps = props[kCGImagePropertyGPSDictionary] as? [CFString: Any] ?? [:]

        // Image
        var image: [MetadataRow] = []
        if let width = number(props[kCGImagePropertyPixelWidth]), let height = number(props[kCGImagePropertyPixelHeight]) {
            image.append(.init(label: "Dimensions", value: "\(Int(width)) × \(Int(height))"))
            image.append(.init(label: "Megapixels", value: String(format: "%.1f MP", width * height / 1_000_000)))
        }
        let frameCount = CGImageSourceGetCount(source)
        if frameCount > 1 {
            image.append(.init(label: "Frames", value: "\(frameCount)"))
        }
        if let dpi = number(props[kCGImagePropertyDPIWidth]) {
            image.append(.init(label: "Resolution", value: "\(Int(dpi.rounded())) DPI"))
        }
        if let depth = number(props[kCGImagePropertyDepth]) {
            image.append(.init(label: "Bit Depth", value: "\(Int(depth))"))
        }
        if let model = props[kCGImagePropertyColorModel] as? String {
            image.append(.init(label: "Color Model", value: model))
        }
        if let profile = props[kCGImagePropertyProfileName] as? String {
            image.append(.init(label: "Color Profile", value: profile))
        }
        if let hasAlpha = props[kCGImagePropertyHasAlpha] as? Bool {
            image.append(.init(label: "Alpha", value: hasAlpha ? "Yes" : "No"))
        }
        if let orientation = number(props[kCGImagePropertyOrientation]), orientation != 1 {
            image.append(.init(label: "Orientation", value: orientationName(Int(orientation))))
        }
        if !image.isEmpty { metadata.sections.append(.init(title: "Image", rows: image)) }

        // Date Taken — splice into the General section (index 0) before "Where", using the exif
        // dict already in hand. Camera body/lens/exposure are shown in the top Camera card instead.
        if let taken = exif[kCGImagePropertyExifDateTimeOriginal] as? String {
            var rows = metadata.sections[0].rows
            // Insert before the last row ("Where").
            rows.insert(.init(label: "Date Taken", value: formatExifDate(taken)), at: rows.count - 1)
            metadata.sections[0] = MetadataSection(title: "General", rows: rows)
        }

        // Location
        if var latitude = number(gps[kCGImagePropertyGPSLatitude]),
           var longitude = number(gps[kCGImagePropertyGPSLongitude]) {
            if (gps[kCGImagePropertyGPSLatitudeRef] as? String) == "S" { latitude = -latitude }
            if (gps[kCGImagePropertyGPSLongitudeRef] as? String) == "W" { longitude = -longitude }
            var location = [
                MetadataRow(label: "Latitude", value: String(format: "%.6f", latitude)),
                MetadataRow(label: "Longitude", value: String(format: "%.6f", longitude)),
            ]
            if let altitude = number(gps[kCGImagePropertyGPSAltitude]) {
                location.append(.init(label: "Altitude", value: String(format: "%.0f m", altitude)))
            }
            metadata.sections.append(.init(title: "Location", rows: location))
            metadata.latitude = latitude
            metadata.longitude = longitude
        }

        if let all = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any] {
            metadata.rawProperties = flatten(all, prefix: "")
        }
        return metadata
    }

    private static func number(_ value: Any?) -> Double? {
        (value as? NSNumber)?.doubleValue
    }

    private static func flatten(_ dict: [String: Any], prefix: String) -> [MetadataRow] {
        var rows: [MetadataRow] = []
        for key in dict.keys.sorted() {
            let name = key.trimmingCharacters(in: CharacterSet(charactersIn: "{}"))
            let label = prefix.isEmpty ? name : "\(prefix) › \(name)"
            switch dict[key] {
            case let nested as [String: Any]:
                rows += flatten(nested, prefix: label)
            case let array as [Any]:
                rows.append(.init(label: label, value: array.map { "\($0)" }.joined(separator: ", ")))
            case let data as Data:
                rows.append(.init(label: label, value: "<\(data.count) bytes>"))
            case let value?:
                rows.append(.init(label: label, value: String("\(value)".prefix(300))))
            case nil:
                break
            }
        }
        return rows
    }

    private static let exifDateParser: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        return formatter
    }()

    private static func formatExifDate(_ string: String) -> String {
        guard let date = exifDateParser.date(from: string) else { return string }
        return date.formatted(date: .abbreviated, time: .standard)
    }

    private static func orientationName(_ value: Int) -> String {
        switch value {
        case 2: "Mirrored horizontal"
        case 3: "Rotated 180°"
        case 4: "Mirrored vertical"
        case 5: "Mirrored, rotated 90° CCW"
        case 6: "Rotated 90° CW"
        case 7: "Mirrored, rotated 90° CW"
        case 8: "Rotated 90° CCW"
        default: "Normal"
        }
    }
}
