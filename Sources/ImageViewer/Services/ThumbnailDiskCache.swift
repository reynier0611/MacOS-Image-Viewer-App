import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Thumbnails saved in ~/Library/Caches so folders open instantly the next time (measured: reading a
/// cached thumbnail is ~20× faster than making one; far more for big photos and videos).
/// Keyed by path + size + modification date, so an edited or rotated file gets a fresh one.
/// Can be switched off and cleared in Settings ▸ Privacy; capped in size, oldest removed first.
final class ThumbnailDiskCache: @unchecked Sendable {
    static let shared = ThumbnailDiskCache()
    static let enabledKey = "thumbnailDiskCache"

    let directory: URL
    let maxBytes: Int64

    init(directory: URL? = nil, maxBytes: Int64 = 500_000_000) {
        self.directory = directory ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("local.imageviewer/Thumbnails", isDirectory: true)
        self.maxBytes = maxBytes
        try? FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
    }

    var isEnabled: Bool {
        UserDefaults.standard.object(forKey: Self.enabledKey) as? Bool ?? true
    }

    func fileURL(for item: FileItem, maxPixel: Int) -> URL {
        let key = "v1|\(item.url.path)|\(item.size)|\(item.modified.timeIntervalSince1970)|\(maxPixel)"
        let name = SHA256.hash(data: Data(key.utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(name)
    }

    func read(_ item: FileItem, maxPixel: Int) -> CGImage? {
        guard isEnabled,
              let source = CGImageSourceCreateWithURL(fileURL(for: item, maxPixel: maxPixel) as CFURL, nil)
        else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
    }

    func write(_ image: CGImage, for item: FileItem, maxPixel: Int) {
        guard isEnabled else { return }
        let url = fileURL(for: item, maxPixel: maxPixel)
        // PNG keeps transparency; everything else is a small JPEG.
        let type = Transparency.hasTransparentPixels(image) ? UTType.png : UTType.jpeg
        let temp = url.appendingPathExtension("tmp-\(UUID().uuidString)")
        guard let destination = CGImageDestinationCreateWithURL(temp as CFURL, type.identifier as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
        // Written under a temporary name, then renamed: a reader never sees a half-written file.
        if CGImageDestinationFinalize(destination), rename(temp.path, url.path) == 0 { return }
        try? FileManager.default.removeItem(at: temp)
    }

    private func files() -> [(url: URL, size: Int64, date: Date)] {
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey]
        let urls = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys)) ?? []
        return urls.map { url in
            let values = try? url.resourceValues(forKeys: Set(keys))
            return (url, Int64(values?.fileSize ?? 0), values?.contentModificationDate ?? .distantPast)
        }
    }

    var totalBytes: Int64 { files().reduce(0) { $0 + $1.size } }

    func clear() {
        for file in files() { try? FileManager.default.removeItem(at: file.url) }
    }

    /// Removes the oldest thumbnails until the cache is under 80% of its limit.
    func prune() {
        var all = files()
        var total = all.reduce(0) { $0 + $1.size }
        guard total > maxBytes else { return }
        all.sort { $0.date < $1.date }
        for file in all where total > maxBytes * 8 / 10 {
            try? FileManager.default.removeItem(at: file.url)
            total -= file.size
        }
    }
}
