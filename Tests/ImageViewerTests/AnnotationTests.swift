import AppKit
import Foundation
import ImageIO
import Testing
@testable import ImageViewer

@Suite("Tags and notes")
struct AnnotationTests {
    let folder = TempFolder()

    @Test func tagsAndNoteRoundTripAndKeepOtherMetadata() throws {
        let url = Fixtures.write(Fixtures.leftRedRightBlue(), to: folder.file("a.jpg"),
                                 taken: "2021:05:06 07:08:09", latitude: 40.7, longitude: -74, orientation: 6)
        try Ratings.write(4, to: url)
        let pixels = Fixtures.stored(url).dataProvider!.data! as Data

        try Annotations.write([.addTag("beach"), .addTag(" Summer  2024 "), .setNote("A long day.\nSecond line — ü")], to: url)
        #expect(Annotations.read(url) == Annotations(tags: ["beach", "Summer 2024"], note: "A long day.\nSecond line — ü"))

        // Everything else is untouched.
        #expect(Ratings.read(url) == 4)
        #expect(Fixtures.orientation(of: url) == 6)
        let info = MediaIndex.readImage(url)
        #expect(info.coordinate?.latitude == 40.7)
        #expect(info.captureDate != nil)
        #expect(info.annotations.tags == ["beach", "Summer 2024"])
        #expect(Fixtures.stored(url).dataProvider!.data! as Data == pixels)

        // Other apps see them as IPTC Keywords and Caption too.
        let props = CGImageSourceCopyPropertiesAtIndex(CGImageSourceCreateWithURL(url as CFURL, nil)!, 0, nil) as! [CFString: Any]
        let iptc = props[kCGImagePropertyIPTCDictionary] as? [CFString: Any]
        #expect(iptc?[kCGImagePropertyIPTCKeywords] as? [String] == ["beach", "Summer 2024"])
        #expect((iptc?[kCGImagePropertyIPTCCaptionAbstract] as? String)?.hasPrefix("A long day.") == true)

        try Annotations.write([.removeTag("BEACH"), .setNote("")], to: url)
        #expect(Annotations.read(url) == Annotations(tags: ["Summer 2024"], note: ""))
        try Annotations.write([.removeTag("summer 2024")], to: url)
        #expect(Annotations.read(url) == Annotations())
        #expect(Ratings.read(url) == 4)
    }

    @Test func editsApplyToWhatTheFileHoldsNow() throws {
        let url = Fixtures.write(Fixtures.solid(CGColor(gray: 0.5, alpha: 1)), to: folder.file("b.png"), type: "public.png")
        try Annotations.write([.addTag("one")], to: url)
        try Annotations.write([.addTag("two"), .addTag("ONE")], to: url) // no duplicate, any case
        #expect(Annotations.read(url).tags == ["one", "two"])
    }

    /// Regression: clearing the note left the older IPTC caption behind, which then showed again.
    @Test func clearingTheNoteRemovesEveryCopy() throws {
        let url = Fixtures.write(Fixtures.solid(CGColor(gray: 0.5, alpha: 1)), to: folder.file("c.jpg"))
        try Annotations.write([.setNote("Grandma")], to: url)
        try Annotations.write([.setNote("")], to: url)
        #expect(Annotations.read(url) == Annotations())
        #expect(try Data(contentsOf: url).range(of: Data("Grandma".utf8)) == nil)
    }

    @Test func typedTextBecomesTags() {
        #expect(Annotations.tags(from: "beach,  family , ,New   York") == ["beach", "family", "New York"])
        #expect(Annotations.Edit.addTag("x").inverse == .removeTag("x"))
    }

    @Test func videosHoldTagsAndNotesNextToTheirRating() async throws {
        let url = folder.file("clip.mov")
        try await VideoFixtures.make(at: url)
        try Ratings.write(3, to: url)
        try Annotations.write([.addTag("party"), .setNote("Birthday")], to: url)
        #expect(Annotations.read(url) == Annotations(tags: ["party"], note: "Birthday"))
        #expect(Ratings.read(url) == 3)
        try Annotations.write([.removeTag("party"), .setNote("")], to: url)
        #expect(Annotations.read(url) == Annotations())
        #expect(Ratings.read(url) == 3)
        #expect(try await VideoFixtures.stillPlays(url))
    }
}

extension AppModelSuite.BrowserModelTests {
    @Test func taggingTheSelectionIsSearchableAndUndoes() async throws {
        try await open(["a.jpg", "b.jpg", "c.jpg"])
        try await waitUntil { model.allImages.allSatisfy { model.mediaInfo[$0.url] != nil } }
        model.click(model.images[0], modifiers: [])
        model.click(model.images[1], modifiers: .command)

        grouped { model.addTags("Sunset, beach", to: model.selectedImages) }
        await model.finishMetadataWrites()
        #expect(Annotations.read(folder.file("a.jpg")).tags == ["Sunset", "beach"])
        #expect(Annotations.read(folder.file("c.jpg")).tags.isEmpty)
        #expect(model.knownTags.prefix(2).sorted() == ["Sunset", "beach"])

        let c = model.images[2]
        grouped { model.setNote("Grandma's garden", for: c) }
        model.searchText = "sunset"
        #expect(model.images.map(\.name) == ["a.jpg", "b.jpg"])
        model.searchText = "garden"
        #expect(model.images.map(\.name) == ["c.jpg"])
        model.searchText = ""

        undoLastAction() // the note
        undoLastAction() // the tags
        await model.finishMetadataWrites()
        #expect(Annotations.read(folder.file("a.jpg")) == Annotations())
        #expect(Annotations.read(folder.file("c.jpg")) == Annotations())
        #expect(model.annotations(for: model.images[0]).tags.isEmpty)
    }
}


extension AnnotationTests {
    /// Regression: on a PNG with no metadata at all, ImageIO silently wrote nothing (ratings too).
    @Test func plainPNGsGetTagsNotesAndRatingsWithIdenticalPixels() throws {
        let url = Fixtures.write(Fixtures.leftRedRightBlue(), to: folder.file("web.png"), type: "public.png")
        let pixels = Fixtures.stored(url).dataProvider!.data! as Data
        try Ratings.write(2, to: url)
        try Annotations.write([.addTag("logo"), .setNote("From the website")], to: url)
        #expect(Ratings.read(url) == 2)
        #expect(Annotations.read(url) == Annotations(tags: ["logo"], note: "From the website"))
        try Annotations.write([.removeTag("logo"), .setNote("")], to: url)
        #expect(Annotations.read(url) == Annotations())
        #expect(Ratings.read(url) == 2)
        #expect(Fixtures.stored(url).dataProvider!.data! as Data == pixels)
    }
}

extension AnnotationTests {
    @Test("Set and clear in every supported image format", arguments: RatingFileTests.formats)
    func everyFormat(type: String) throws {
        let url = Fixtures.write(Fixtures.leftRedRightBlue(), to: folder.file("photo.\(RatingFileTests.ext(type))"), type: type,
                                 taken: "2021:06:15 18:30:00", latitude: 40.4, longitude: -3.7, orientation: 6)
        let modified = Date(timeIntervalSince1970: 1_600_000_000)
        try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
        try Annotations.write([.addTag("a"), .addTag("b"), .setNote("Note")], to: url)
        #expect(Annotations.read(url) == Annotations(tags: ["a", "b"], note: "Note"))
        try Annotations.write([.removeTag("a"), .setNote("")], to: url)
        #expect(Annotations.read(url) == Annotations(tags: ["b"], note: ""))
        #expect(Fixtures.orientation(of: url) == 6)
        #expect(MediaIndex.readImage(url).coordinate != nil)
        #expect(try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date == modified)
    }
}
