import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Ratings inside MP4 / MOV / M4V files, stored as an XMP packet in a top-level `uuid` box: the
/// place Adobe tools and exiftool use for MP4 XMP. Writing never re-encodes or moves anything:
/// the new box is appended at the end of the file (the video's index points into the media data
/// by absolute position, so nothing before the end may shift). An older XMP box that is last in
/// the file is cut off; one elsewhere is retyped to `free` (ignored padding). Files whose layout
/// isn't understood exactly are refused rather than touched.
enum VideoXMP {
    enum VideoXMPError: LocalizedError {
        case unsupported(String)
        var errorDescription: String? {
            switch self {
            case .unsupported(let reason): "The rating can't be saved in this video: \(reason)."
            }
        }
    }

    /// The UUID Adobe's XMP specification assigns to XMP boxes in ISO media files.
    static let xmpUUID = Data([0xBE, 0x7A, 0xCF, 0xCB, 0x97, 0xA9, 0x42, 0xE8, 0x9C, 0x71, 0x99, 0x94, 0x91, 0xE3, 0xAF, 0xAC])

    struct Box {
        let type: String
        let offset: UInt64
        let size: UInt64
        let headerSize: UInt64
        let isXMP: Bool
        var payloadOffset: UInt64 { offset + headerSize + (isXMP ? 16 : 0) }
    }

    /// Box types a QuickTime/MP4 file may start with. Anything else isn't one we'll write to.
    private static let plausibleFirstBoxes: Set<String> = ["ftyp", "wide", "free", "skip", "mdat", "moov", "pnot"]

    /// The file's top-level boxes. Throws unless they tile the file exactly. A box that "extends to
    /// the end of the file" (size 0) is accepted for reading only.
    static func topLevelBoxes(of url: URL, forWriting: Bool = false) throws -> [Box] {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let fileSize = try handle.seekToEnd()
        var boxes: [Box] = []
        var offset: UInt64 = 0
        while offset < fileSize {
            try handle.seek(toOffset: offset)
            guard let header = try handle.read(upToCount: 8), header.count == 8 else {
                throw VideoXMPError.unsupported("its structure is damaged")
            }
            var size = UInt64(header.prefix(4).reduce(0) { $0 << 8 | UInt32($1) })
            let type = String(decoding: header.suffix(4), as: UTF8.self)
            var headerSize: UInt64 = 8
            if size == 1 {
                guard let large = try handle.read(upToCount: 8), large.count == 8 else {
                    throw VideoXMPError.unsupported("its structure is damaged")
                }
                size = large.reduce(0) { $0 << 8 | UInt64($1) }
                headerSize = 16
            } else if size == 0 {
                guard !forWriting else { throw VideoXMPError.unsupported("its last section has no fixed size") }
                size = fileSize - offset
            }
            guard size >= headerSize, offset + size <= fileSize else {
                throw VideoXMPError.unsupported("its structure is damaged")
            }
            if boxes.isEmpty, !plausibleFirstBoxes.contains(type) {
                throw VideoXMPError.unsupported("it isn't an MP4 or QuickTime file")
            }
            var isXMP = false
            if type == "uuid", size >= headerSize + 16 {
                isXMP = try handle.read(upToCount: 16) == xmpUUID
            }
            boxes.append(Box(type: type, offset: offset, size: size, headerSize: headerSize, isXMP: isXMP))
            offset += size
        }
        return boxes
    }

    /// The XMP packet in the file (the last one, if there are several).
    static func readXMP(from url: URL) -> Data? {
        guard let box = (try? topLevelBoxes(of: url))?.last(where: \.isXMP),
              let handle = try? FileHandle(forReadingFrom: url)
        else { return nil }
        defer { try? handle.close() }
        try? handle.seek(toOffset: box.payloadOffset)
        return try? handle.read(upToCount: Int(box.offset + box.size - box.payloadOffset))
    }

    static func isVideo(_ url: URL) -> Bool {
        UTType(filenameExtension: url.pathExtension)?.conforms(to: .movie) ?? false
    }

    static func readRating(from url: URL) -> Int? {
        guard let data = readXMP(from: url),
              let metadata = CGImageMetadataCreateFromXMPData(data as CFData)
        else { return nil }
        return readRating(from: metadata)
    }

    static func readRating(from metadata: CGImageMetadata) -> Int? {
        guard let value = CGImageMetadataCopyStringValueWithPath(metadata, nil, "xmp:Rating" as CFString) as String?,
              let rating = Int(value.trimmingCharacters(in: .whitespaces)) ?? Double(value).map({ Int($0) })
        else { return nil }
        return min(max(rating, Ratings.range.lowerBound), Ratings.range.upperBound)
    }

    static func writeRating(_ rating: Int, to url: URL) throws {
        try update(url) { metadata in
            CGImageMetadataSetValueWithPath(metadata, nil, "xmp:Rating" as CFString, "\(rating)" as CFString)
        }
    }

    /// Rewrites the file's XMP packet after `change` edits it (`change` returns false to give up).
    static func update(_ url: URL, _ change: (CGMutableImageMetadata) -> Bool) throws {
        let boxes = try topLevelBoxes(of: url, forWriting: true)
        let modified = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate]

        // Keep any other XMP the file already has; only what `change` touches is different.
        let metadata = readXMP(from: url)
            .flatMap { CGImageMetadataCreateFromXMPData($0 as CFData) }
            .flatMap { CGImageMetadataCreateMutableCopy($0) } ?? CGImageMetadataCreateMutable()
        guard change(metadata),
              let packet = CGImageMetadataCreateXMPData(metadata, nil) as Data?
        else { throw VideoXMPError.unsupported("the metadata couldn't be encoded") }

        var box = Data()
        let size = UInt32(8 + 16 + packet.count)
        box.append(contentsOf: withUnsafeBytes(of: size.bigEndian, Array.init))
        box.append(contentsOf: Array("uuid".utf8))
        box.append(xmpUUID)
        box.append(packet)

        let handle = try FileHandle(forUpdating: url)
        defer { try? handle.close() }
        var end = boxes.last.map { $0.offset + $0.size } ?? 0
        for old in boxes where old.isXMP {
            if old.offset + old.size == end {
                end = old.offset // last in the file: cut it off
            } else {
                try handle.seek(toOffset: old.offset + 4)
                try handle.write(contentsOf: Array("free".utf8)) // elsewhere: becomes ignored padding
            }
        }
        try handle.truncate(atOffset: end)
        try handle.seek(toOffset: end)
        try handle.write(contentsOf: box)
        try handle.synchronize()
        if let modified {
            try? FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
        }
    }
}
