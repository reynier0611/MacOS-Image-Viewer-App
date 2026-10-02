import Foundation
import ImageIO

/// Tags and a free-text note stored *in the file*, in the standard places other apps read:
/// tags are XMP `dc:subject` (ImageIO mirrors them into IPTC Keywords), the note is XMP
/// `dc:description` (IPTC Caption): Lightroom's Keywords and Caption, Photos' keywords and caption.
/// Same file types as ratings (JPEG, HEIC, PNG, TIFF, MP4/MOV); written without touching pixels.
struct Annotations: Equatable, Sendable {
    var tags: [String] = []
    var note = ""

    static func canStore(in item: FileItem) -> Bool { Ratings.canStore(in: item) }

    /// Trimmed, single-spaced; commas separate tags so they can't be inside one.
    static func cleanTag(_ text: String) -> String {
        text.split(whereSeparator: { $0.isWhitespace || $0 == "," }).joined(separator: " ")
    }

    /// Splits typed text like "beach, family" into tags.
    static func tags(from text: String) -> [String] {
        text.split(separator: ",").map { cleanTag(String($0)) }.filter { !$0.isEmpty }
    }

    func hasTag(_ tag: String) -> Bool {
        tags.contains { $0.caseInsensitiveCompare(tag) == .orderedSame }
    }

    /// One change, applied to whatever the file holds at the moment it's written (so a change made
    /// before the folder finished indexing never wipes tags the app hadn't read yet).
    enum Edit: Sendable, Equatable {
        case addTag(String)
        case removeTag(String)
        case setNote(String)

        var inverse: Edit? {
            switch self {
            case .addTag(let tag): .removeTag(tag)
            case .removeTag(let tag): .addTag(tag)
            case .setNote: nil // needs the old text; see BrowserModel.setNote
            }
        }
    }

    func applying(_ edit: Edit) -> Annotations {
        var result = self
        switch edit {
        case .addTag(let tag):
            let tag = Self.cleanTag(tag)
            if !tag.isEmpty, !hasTag(tag) { result.tags.append(tag) }
        case .removeTag(let tag):
            result.tags.removeAll { $0.caseInsensitiveCompare(tag) == .orderedSame }
        case .setNote(let note):
            result.note = note.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return result
    }

    // MARK: Reading

    static func read(from metadata: CGImageMetadata) -> Annotations {
        var result = Annotations()
        if let tag = CGImageMetadataCopyTagWithPath(metadata, nil, "dc:subject" as CFString),
           let items = CGImageMetadataTagCopyValue(tag) as? [CGImageMetadataTag] {
            result.tags = items.compactMap { CGImageMetadataTagCopyValue($0) as? String }.map(cleanTag).filter { !$0.isEmpty }
        }
        result.note = (CGImageMetadataCopyStringValueWithPath(metadata, nil, "dc:description" as CFString) as String?) ?? ""
        return result
    }

    static func read(_ url: URL) -> Annotations {
        let metadata: CGImageMetadata? = VideoXMP.isVideo(url)
            ? VideoXMP.readXMP(from: url).flatMap { CGImageMetadataCreateFromXMPData($0 as CFData) }
            : CGImageSourceCreateWithURL(url as CFURL, nil).flatMap { CGImageSourceCopyMetadataAtIndex($0, 0, nil) }
        return metadata.map(read(from:)) ?? Annotations()
    }

    // MARK: Writing

    /// Applies `edits` to the file's current tags and note and saves them. Returns the result.
    @discardableResult
    static func write(_ edits: [Edit], to url: URL) throws -> Annotations {
        let updated = edits.reduce(read(url)) { $0.applying($1) }
        if VideoXMP.isVideo(url) {
            // Videos: the whole XMP packet is rewritten, so remove what's now empty.
            try VideoXMP.update(url) { metadata in set(updated, in: metadata, merging: false) }
        } else {
            try ImageEditing.updateMetadata(of: url) { metadata, merging in set(updated, in: metadata, merging: merging) }
        }
        return updated
    }

    private static func set(_ annotations: Annotations, in metadata: CGMutableImageMetadata, merging: Bool) -> Bool {
        if annotations.tags.isEmpty && !merging {
            CGImageMetadataRemoveTagWithPath(metadata, nil, "dc:subject" as CFString)
        } else {
            guard let tag = CGImageMetadataTagCreate(
                "http://purl.org/dc/elements/1.1/" as CFString, "dc" as CFString, "subject" as CFString,
                .arrayUnordered, annotations.tags as CFArray
            ), CGImageMetadataSetTagWithPath(metadata, nil, "dc:subject" as CFString, tag)
            else { return false }
        }
        if annotations.note.isEmpty && !merging {
            CGImageMetadataRemoveTagWithPath(metadata, nil, "dc:description" as CFString)
            return true
        }
        if annotations.note.isEmpty {
            // Clearing takes both an empty XMP caption and a null IPTC one: with only the first, JPEGs
            // show their older IPTC copy again; with only the second, HEIC and TIFF keep the XMP one.
            guard let empty = CGImageMetadataTagCreate(
                "http://purl.org/dc/elements/1.1/" as CFString, "dc" as CFString, "description" as CFString,
                .alternateText, [] as CFArray
            ) else { return false }
            CGImageMetadataSetTagWithPath(metadata, nil, "dc:description" as CFString, empty)
            // (Reports false even though it marks the caption for removal.)
            CGImageMetadataSetValueMatchingImageProperty(
                metadata, kCGImagePropertyIPTCDictionary, kCGImagePropertyIPTCCaptionAbstract, kCFNull
            )
            return true
        }
        // Written through the IPTC caption mapping, which produces the proper XMP language alternative
        // and keeps the file's older IPTC copy in step.
        return CGImageMetadataSetValueMatchingImageProperty(
            metadata, kCGImagePropertyIPTCDictionary, kCGImagePropertyIPTCCaptionAbstract, annotations.note as CFString
        )
    }
}
