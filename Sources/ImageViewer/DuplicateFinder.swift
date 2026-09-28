import CryptoKit
import Foundation
import ImageIO
import Vision

struct DuplicateGroup: Identifiable {
    enum Kind { case identical, similar }

    let id = UUID()
    let kind: Kind
    var items: [FileItem]
}

enum SimilaritySensitivity: String, CaseIterable, Identifiable {
    case strict = "Strict"
    case normal = "Normal"
    case loose = "Loose"

    var id: String { rawValue }

    /// Vision feature-print distances, measured on real photos: the same photo re-saved,
    /// resized or lightly cropped scores ~0.06–0.15; unrelated photos ~0.9; the same design
    /// in another color ~0.35.
    var threshold: Float {
        switch self {
        case .strict: 0.18
        case .normal: 0.3
        case .loose: 0.45
        }
    }

    var explanation: String {
        switch self {
        case .strict: "Only re-saved, resized or re-compressed copies."
        case .normal: "Also light crops and edits, and burst shots."
        case .loose: "Also similar scenes and variations."
        }
    }
}

enum DuplicateFinder {
    /// Finds byte-identical files (SHA-256) and, optionally, visually similar images (on-device Vision).
    static func findGroups(
        in items: [FileItem],
        includeSimilar: Bool,
        sensitivity: SimilaritySensitivity,
        progress: @escaping @Sendable (Double, String) -> Void
    ) async -> [DuplicateGroup] {
        var groups: [DuplicateGroup] = []

        // 1. Identical: same size first (cheap), then hash only those candidates.
        progress(0, "Comparing file contents…")
        let bySize = Dictionary(grouping: items.filter { $0.size > 0 }, by: \.size).values.filter { $0.count > 1 }
        let candidates = bySize.flatMap { $0 }
        var hashed = 0
        var byHash: [String: [FileItem]] = [:]
        for item in candidates {
            if Task.isCancelled { return [] }
            if let hash = sha256(of: item.url) {
                byHash["\(item.size)-\(hash)", default: []].append(item)
            }
            hashed += 1
            progress(includeSimilar ? 0.2 * Double(hashed) / Double(candidates.count) : Double(hashed) / Double(candidates.count),
                     "Comparing file contents…")
        }
        for group in byHash.values where group.count > 1 {
            groups.append(DuplicateGroup(kind: .identical, items: group))
        }
        guard includeSimilar else { return sorted(groups) }

        // 2. Similar: one representative per identical group, so pairs aren't reported twice.
        let alreadyGrouped = Set(groups.flatMap { $0.items.dropFirst().map(\.url) })
        let photos = items.filter { !$0.isVideo && !alreadyGrouped.contains($0.url) }
        var prints: [(FileItem, VNFeaturePrintObservation)] = []
        for (index, item) in photos.enumerated() {
            if Task.isCancelled { return [] }
            if let print = featurePrint(item.url) {
                prints.append((item, print))
            }
            progress(0.2 + 0.75 * Double(index + 1) / Double(photos.count), "Analyzing images \(index + 1) of \(photos.count)…")
        }

        progress(0.95, "Grouping similar images…")
        var parent = Array(prints.indices)
        func root(_ i: Int) -> Int {
            var i = i
            while parent[i] != i {
                parent[i] = parent[parent[i]]
                i = parent[i]
            }
            return i
        }
        for i in prints.indices {
            if Task.isCancelled { return [] }
            for j in (i + 1)..<prints.count {
                var distance: Float = .infinity
                if (try? prints[i].1.computeDistance(&distance, to: prints[j].1)) != nil, distance < sensitivity.threshold {
                    parent[root(j)] = root(i)
                }
            }
        }
        let clusters = Dictionary(grouping: prints.indices, by: root).values.filter { $0.count > 1 }
        for cluster in clusters {
            groups.append(DuplicateGroup(kind: .similar, items: cluster.map { prints[$0].0 }))
        }
        progress(1, "Done")
        return sorted(groups)
    }

    private static func sorted(_ groups: [DuplicateGroup]) -> [DuplicateGroup] {
        groups.sorted { ($0.kind == .identical ? 0 : 1, $0.items.first?.name ?? "") < ($1.kind == .identical ? 0 : 1, $1.items.first?.name ?? "") }
    }

    private static func sha256(of url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try? handle.read(upToCount: 4 * 1024 * 1024), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func featurePrint(_ url: URL) -> VNFeaturePrintObservation? {
        guard let image = ContentAnalyzer.downsampled(url, maxPixel: 512) else { return nil }
        let request = VNGenerateImageFeaturePrintRequest()
        guard (try? VNImageRequestHandler(cgImage: image).perform([request])) != nil else { return nil }
        return request.results?.first
    }

    /// The copy to keep by default: most pixels, then largest file, then oldest.
    static func suggestedKeeper(in items: [FileItem]) -> FileItem? {
        items.max { a, b in
            let pa = pixelCount(a.url), pb = pixelCount(b.url)
            if pa != pb { return pa < pb }
            if a.size != b.size { return a.size < b.size }
            return a.created > b.created
        }
    }

    static func pixelCount(_ url: URL) -> Int {
        guard let size = ImageLoader.pixelSize(of: url) else { return 0 }
        return Int(size.width * size.height)
    }
}
