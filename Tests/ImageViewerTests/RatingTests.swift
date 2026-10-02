import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import ImageViewer

@Suite("Ratings stored in the file")
struct RatingFileTests {
    static var formats: [String] {
        var types = ["public.jpeg", "public.png", "public.tiff"]
        if ExportOptions.Format.available.contains(.heic) { types.append("public.heic") }
        return types
    }

    static func ext(_ type: String) -> String {
        ["public.jpeg": "jpg", "public.png": "png", "public.tiff": "tif", "public.heic": "heic"][type]!
    }

    @Test("Round-trips without touching pixels, other metadata, or the modified date", arguments: formats)
    func roundTrip(type: String) throws {
        let folder = TempFolder()
        let url = Fixtures.write(
            Fixtures.leftRedRightBlue(), to: folder.file("photo.\(Self.ext(type))"), type: type,
            taken: "2021:06:15 18:30:00", latitude: 40.4168, longitude: -3.7038, orientation: 6
        )
        let modified = Date(timeIntervalSince1970: 1_600_000_000)
        try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
        let pixelsBefore = Fixtures.stored(url).dataProvider!.data! as Data
        #expect(Ratings.read(url) == nil)

        try Ratings.write(4, to: url)

        #expect(Ratings.read(url) == 4)
        #expect(Fixtures.stored(url).dataProvider!.data! as Data == pixelsBefore)
        let info = MediaIndex.readImage(url)
        #expect(info.rating == 4)
        #expect(info.captureDate != nil)
        #expect(info.coordinate != nil)
        #expect(Fixtures.orientation(of: url) == 6)
        let after = try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date
        #expect(after == modified)
    }

    @Test func rejectAndClear() throws {
        let folder = TempFolder()
        let url = Fixtures.write(Fixtures.solid(CGColor(gray: 0.5, alpha: 1)), to: folder.file("a.jpg"))
        try Ratings.write(Ratings.rejected, to: url)
        #expect(Ratings.read(url) == -1)
        try Ratings.write(0, to: url)
        #expect(Ratings.read(url) == 0)
        #expect(throws: (any Error).self) { try Ratings.write(6, to: url) }
    }

    /// Lightroom, Bridge and others read "Rating" in Adobe's XMP basic namespace.
    @Test func usesTheStandardXMPRatingTag() throws {
        let folder = TempFolder()
        let url = Fixtures.write(Fixtures.solid(CGColor(gray: 0.5, alpha: 1)), to: folder.file("a.jpg"))
        try Ratings.write(3, to: url)
        let metadata = try #require(CGImageSourceCopyMetadataAtIndex(CGImageSourceCreateWithURL(url as CFURL, nil)!, 0, nil))
        let tag = try #require(CGImageMetadataCopyTagWithPath(metadata, nil, "xmp:Rating" as CFString))
        #expect(CGImageMetadataTagCopyNamespace(tag) as String? == "http://ns.adobe.com/xap/1.0/")
        #expect(CGImageMetadataTagCopyValue(tag) as? String == "3")
    }

    @Test func onlyFormatsThatCanBeRewrittenInPlace() {
        let folder = TempFolder()
        func item(_ name: String) -> FileItem {
            FileManager.default.createFile(atPath: folder.file(name).path, contents: Data([0]))
            return Fixtures.item(folder.file(name))
        }
        #expect(Ratings.canStore(in: item("a.jpg")))
        #expect(Ratings.canStore(in: item("a.heic")))
        #expect(!Ratings.canStore(in: item("a.mov")))
        #expect(!Ratings.canStore(in: item("a.dng")))
        #expect(!Ratings.canStore(in: item("a.gif")))
    }

    @Test func ratingFilter() {
        #expect(RatingFilter.threeOrMore.matches(3) && RatingFilter.threeOrMore.matches(5))
        #expect(!RatingFilter.threeOrMore.matches(2) && !RatingFilter.threeOrMore.matches(-1))
        #expect(RatingFilter.unrated.matches(0) && !RatingFilter.unrated.matches(1))
        #expect(RatingFilter.rejected.matches(-1) && !RatingFilter.rejected.matches(0))
        #expect(RatingFilter.any.matches(-1))
    }
}
