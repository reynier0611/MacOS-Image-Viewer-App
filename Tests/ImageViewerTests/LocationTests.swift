import AppKit
import Foundation
import ImageIO
import Testing
@testable import ImageViewer

@Suite("Set location")
struct LocationTests {
    let folder = TempFolder()

    @Test("Add, change and remove in every supported format", arguments: RatingFileTests.formats)
    func everyFormat(type: String) throws {
        let url = Fixtures.write(Fixtures.leftRedRightBlue(), to: folder.file("photo.\(RatingFileTests.ext(type))"), type: type,
                                 taken: "2021:06:15 18:30:00", orientation: 6)
        try Ratings.write(4, to: url)
        try Annotations.write([.addTag("trip"), .setNote("Hi")], to: url)
        let modified = Date(timeIntervalSince1970: 1_600_000_000)
        try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
        let pixels = Fixtures.stored(url).dataProvider!.data! as Data
        #expect(MediaIndex.readImage(url).coordinate == nil)

        try ImageLocation.write(Coordinate(latitude: -33.8568, longitude: 151.2153), to: url)
        var info = MediaIndex.readImage(url)
        #expect(abs((info.coordinate?.latitude ?? 0) + 33.8568) < 0.0001)
        #expect(abs((info.coordinate?.longitude ?? 0) - 151.2153) < 0.0001)

        try ImageLocation.write(Coordinate(latitude: 40.4168, longitude: -3.7038), to: url)
        info = MediaIndex.readImage(url)
        #expect(abs((info.coordinate?.latitude ?? 0) - 40.4168) < 0.0001)
        #expect(abs((info.coordinate?.longitude ?? 0) + 3.7038) < 0.0001)

        // Everything else survives.
        #expect(info.rating == 4)
        #expect(info.annotations == Annotations(tags: ["trip"], note: "Hi"))
        #expect(info.captureDate != nil)
        #expect(Fixtures.orientation(of: url) == 6)
        #expect(Fixtures.stored(url).dataProvider!.data! as Data == pixels)
        #expect(try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date == modified)

        try ImageLocation.write(nil, to: url)
        info = MediaIndex.readImage(url)
        #expect(info.coordinate == nil)
        #expect(info.rating == 4)
        #expect(Fixtures.orientation(of: url) == 6)
    }

    @Test func typedCoordinates() {
        #expect(ImageLocation.parse("40.4168, -3.7038") == Coordinate(latitude: 40.4168, longitude: -3.7038))
        #expect(ImageLocation.parse("-33.85° 151.21°") == Coordinate(latitude: -33.85, longitude: 151.21))
        #expect(ImageLocation.parse("Madrid") == nil)
        #expect(ImageLocation.parse("95, 10") == nil)
    }

    @Test func onlyPhotosThatCanBeRewritten() throws {
        let jpg = Fixtures.write(Fixtures.solid(CGColor(gray: 0.5, alpha: 1)), to: folder.file("a.jpg"))
        let bmp = Fixtures.write(Fixtures.solid(CGColor(gray: 0.5, alpha: 1)), to: folder.file("a.bmp"), type: "com.microsoft.bmp")
        #expect(ImageLocation.canStore(in: FileItem(url: jpg)!))
        #expect(!ImageLocation.canStore(in: FileItem(url: bmp)!))
    }
}

extension AppModelSuite.BrowserModelTests {
    @Test func settingALocationShowsOnTheMapAndUndoes() async throws {
        try await open(["a.jpg", "b.jpg", "c.jpg"])
        try await waitUntil { model.allImages.allSatisfy { model.mediaInfo[$0.url] != nil } }
        let madrid = Coordinate(latitude: 40.4168, longitude: -3.7038)

        undo.beginUndoGrouping()
        model.setLocation(madrid, for: [model.images[0], model.images[1]])
        try await waitUntil { model.mediaInfo[model.images[0].url]?.coordinate != nil }
        undo.endUndoGrouping()
        await model.finishMetadataWrites()
        #expect(MediaIndex.readImage(folder.file("a.jpg")).coordinate != nil)
        #expect(MediaIndex.readImage(folder.file("c.jpg")).coordinate == nil)

        // A photo without a location is suggested its neighbor's.
        #expect(model.suggestedLocation(for: [model.images[2]])?.coordinate == madrid)

        undoLastAction()
        await model.finishMetadataWrites()
        #expect(model.mediaInfo[model.images[0].url]?.coordinate == nil)
        #expect(MediaIndex.readImage(folder.file("a.jpg")).coordinate == nil)
    }
}
