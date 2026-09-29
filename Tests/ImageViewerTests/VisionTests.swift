import CoreGraphics
import Foundation
import Testing
@testable import ImageViewer

/// Uses macOS's on-device Vision models (no network).
@Suite("Text recognition, duplicates")
struct VisionTests {
    @Test func recognizesLinesInReadingOrderWithBoxes() throws {
        let lines = TextRecognizer.recognize(Fixtures.text(["Invoice 2026-0457", "Total due: $1,234.56", "Thank you"]))
        #expect(lines.map(\.text) == ["Invoice 2026-0457", "Total due: $1,234.56", "Thank you"])
        // Boxes are normalized, top line highest, starting near the left edge.
        #expect(lines[0].bounds.minY > lines[1].bounds.minY && lines[1].bounds.minY > lines[2].bounds.minY)
        #expect(lines.allSatisfy { (0.04...0.12).contains($0.bounds.minX) })
        #expect(lines.allSatisfy { $0.confidence > 0.5 })
    }

    @Test func blankImageHasNoText() {
        #expect(TextRecognizer.recognize(Fixtures.solid(CGColor(gray: 1, alpha: 1), width: 400, height: 300)).isEmpty)
    }

    @Test func findsIdenticalCopies() async {
        let folder = TempFolder()
        let original = Fixtures.write(Fixtures.leftRedRightBlue(), to: folder.file("a.jpg"))
        try? FileManager.default.copyItem(at: original, to: folder.file("a copy.jpg"))
        Fixtures.write(Fixtures.solid(CGColor(gray: 0.3, alpha: 1)), to: folder.file("other.jpg"))
        let items = ["a.jpg", "a copy.jpg", "other.jpg"].map { Fixtures.item(folder.file($0)) }

        let groups = await DuplicateFinder.findGroups(in: items, includeSimilar: false, sensitivity: .normal) { _, _ in }

        #expect(groups.count == 1)
        #expect(groups.first?.kind == .identical)
        #expect(Set(groups.first?.items.map(\.name) ?? []) == ["a.jpg", "a copy.jpg"])
    }

    static let sonoma = Fixtures.wallpapers.appendingPathComponent("Sonoma.heic")
    static let other = Fixtures.wallpapers.appendingPathComponent("iMac Blue.heic")

    @Test(.enabled(if: FileManager.default.fileExists(atPath: sonoma.path) && FileManager.default.fileExists(atPath: other.path)))
    func groupsResizedCopiesButNotDifferentPhotosAndPicksTheBiggest() async throws {
        let folder = TempFolder()
        let large = Fixtures.write(Fixtures.displayed(Self.sonoma).resized(to: 2000), to: folder.file("large.jpg"))
        _ = large
        Fixtures.write(Fixtures.displayed(Self.sonoma).resized(to: 700), to: folder.file("small.jpg"))
        Fixtures.write(Fixtures.displayed(Self.other).resized(to: 2000), to: folder.file("different.jpg"))
        let items = ["large.jpg", "small.jpg", "different.jpg"].map { Fixtures.item(folder.file($0)) }

        let groups = await DuplicateFinder.findGroups(in: items, includeSimilar: true, sensitivity: .normal) { _, _ in }

        let group = try #require(groups.first)
        #expect(groups.count == 1 && group.kind == .similar)
        #expect(Set(group.items.map(\.name)) == ["large.jpg", "small.jpg"])
        #expect(DuplicateFinder.suggestedKeeper(in: group.items)?.name == "large.jpg")
    }
}

private extension CGImage {
    func resized(to longest: Int) -> CGImage {
        let scale = Double(longest) / Double(max(width, height))
        let w = Int(Double(width) * scale), h = Int(Double(height) * scale)
        return Fixtures.image(width: w, height: h) { context in
            context.interpolationQuality = .high
            context.draw(self, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
    }
}
