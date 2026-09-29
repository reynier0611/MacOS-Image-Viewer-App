import Foundation
import UniformTypeIdentifiers

/// A folder, image or video inside the folder being browsed.
struct FileItem: Identifiable, Hashable {
    let url: URL
    let name: String
    let isDirectory: Bool
    let isVideo: Bool
    let isRaw: Bool
    let size: Int64
    let modified: Date
    let created: Date

    var id: URL { url }

    static let resourceKeys: [URLResourceKey] = [
        .isDirectoryKey, .isPackageKey, .fileSizeKey,
        .contentModificationDateKey, .creationDateKey, .contentTypeKey,
    ]

    /// Returns nil for anything that is not a plain folder, an image or a video.
    init?(url: URL) {
        guard let values = try? url.resourceValues(forKeys: Set(Self.resourceKeys)) else { return nil }
        let isDirectory = (values.isDirectory ?? false) && !(values.isPackage ?? false)
        var isVideo = false
        var isRaw = false
        if !isDirectory {
            guard let type = values.contentType else { return nil }
            if type.conforms(to: .movie) {
                isVideo = true
            } else if !type.conforms(to: .image) {
                return nil
            }
            isRaw = type.conforms(to: .rawImage)
        }
        self.url = url
        self.name = url.lastPathComponent
        self.isDirectory = isDirectory
        self.isVideo = isVideo
        self.isRaw = isRaw
        self.size = Int64(values.fileSize ?? 0)
        self.modified = values.contentModificationDate ?? .distantPast
        self.created = values.creationDate ?? .distantPast
    }
}

enum SortKey: String, CaseIterable, Identifiable {
    case name = "Name"
    case taken = "Date Taken"
    case modified = "Date Modified"
    case created = "Date Created"
    case size = "Size"

    var id: String { rawValue }
}
