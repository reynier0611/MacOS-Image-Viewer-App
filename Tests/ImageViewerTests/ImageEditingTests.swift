import Foundation
import ImageIO
import Testing
@testable import ImageViewer

@Suite("Rotate & flip")
struct OrientationTests {
    /// Expected results from the EXIF orientation definitions (1–8).
    static let rotateRight = [1: 6, 2: 7, 3: 8, 4: 5, 5: 2, 6: 3, 7: 4, 8: 1]
    static let flipHorizontal = [1: 2, 2: 1, 3: 4, 4: 3, 5: 6, 6: 5, 7: 8, 8: 7]

    @Test("Rotate right follows the EXIF table", arguments: 1...8)
    func rotateRightTable(orientation: Int) {
        #expect(OrientationChange.rotateRight.applied(to: orientation) == Self.rotateRight[orientation])
    }

    @Test("Flip horizontal follows the EXIF table", arguments: 1...8)
    func flipHorizontalTable(orientation: Int) {
        #expect(OrientationChange.flipHorizontal.applied(to: orientation) == Self.flipHorizontal[orientation])
    }

    @Test("Every change is undone by its inverse", arguments: [
        OrientationChange.rotateLeft, .rotateRight, .flipHorizontal, .flipVertical,
    ])
    func inverseRoundTrip(change: OrientationChange) {
        for orientation in 1...8 {
            #expect(change.inverse.applied(to: change.applied(to: orientation)) == orientation)
        }
    }

    @Test func fourRotationsAreIdentity() {
        var orientation = 1
        for _ in 0..<4 { orientation = OrientationChange.rotateLeft.applied(to: orientation) }
        #expect(orientation == 1)
    }

    @Test func rotatingAFileIsLosslessAndClockwise() throws {
        let folder = TempFolder()
        let url = Fixtures.write(Fixtures.leftRedRightBlue(), to: folder.file("photo.jpg"))
        let storedBefore = Fixtures.stored(url)
        let bytesBefore = try Data(contentsOf: url).count

        try ImageEditing.changeOrientation(of: url, by: .rotateRight)

        #expect(Fixtures.orientation(of: url) == 6)
        // The stored pixels are untouched (nothing was re-compressed)…
        let storedAfter = Fixtures.stored(url)
        #expect(storedAfter.width == storedBefore.width && storedAfter.height == storedBefore.height)
        #expect(Fixtures.color(of: storedAfter, x: 0.25, y: 0.5).r > 200)
        #expect(abs(try Data(contentsOf: url).count - bytesBefore) < 2_000)
        // …but it now displays rotated clockwise: the red left half is on top.
        let shown = Fixtures.displayed(url)
        #expect(shown.width == 100 && shown.height == 200)
        #expect(Fixtures.color(of: shown, x: 0.5, y: 0.25).r > 200)
        #expect(Fixtures.color(of: shown, x: 0.5, y: 0.75).b > 200)
    }

    @Test func rotatingTwiceLeftThenFlipping() throws {
        let folder = TempFolder()
        let url = Fixtures.write(Fixtures.leftRedRightBlue(), to: folder.file("photo.png"), type: "public.png")
        try ImageEditing.changeOrientation(of: url, by: .rotateLeft)
        try ImageEditing.changeOrientation(of: url, by: .rotateLeft)
        #expect(Fixtures.orientation(of: url) == 3)
        try ImageEditing.changeOrientation(of: url, by: .flipHorizontal)
        #expect(Fixtures.orientation(of: url) == 4)
    }
}

@Suite("Export")
struct ExportTests {
    @Test func resizesKeepsDateAndRemovesLocation() throws {
        let folder = TempFolder()
        let source = Fixtures.write(
            Fixtures.solid(CGColor(srgbRed: 0.2, green: 0.6, blue: 0.3, alpha: 1), width: 3000, height: 2000),
            to: folder.file("trip.jpg"), taken: "2021:06:15 18:30:00", latitude: 40.4168, longitude: -3.7038
        )
        let out = folder.url.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        var options = ExportOptions()
        options.maxPixelSize = 1024

        let exported = try Exporter.export(source, to: out, options: options)

        #expect(exported.lastPathComponent == "trip.jpg")
        let size = try #require(ImageLoader.pixelSize(of: exported))
        #expect(max(size.width, size.height) == 1024)
        let info = MediaIndex.readImage(exported)
        #expect(info.captureDate != nil)
        #expect(info.coordinate == nil)
    }

    @Test func keepsLocationWhenAsked() throws {
        let folder = TempFolder()
        let source = Fixtures.write(Fixtures.solid(CGColor(gray: 0.5, alpha: 1)), to: folder.file("a.jpg"), latitude: 10, longitude: 20)
        var options = ExportOptions()
        options.removeLocation = false
        let exported = try Exporter.export(source, to: folder.url, options: options)
        #expect(MediaIndex.readImage(exported).coordinate == Coordinate(latitude: 10, longitude: 20))
    }

    @Test func neverOverwritesAndBakesInOrientation() throws {
        let folder = TempFolder()
        let source = Fixtures.write(Fixtures.leftRedRightBlue(), to: folder.file("pic.png"), type: "public.png", orientation: 6)
        let out = folder.url.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

        let first = try Exporter.export(source, to: out, options: ExportOptions())
        let second = try Exporter.export(source, to: out, options: ExportOptions())

        #expect(first.lastPathComponent == "pic.jpg")
        #expect(second.lastPathComponent == "pic 2.jpg")
        // Rotated pixels are baked in, so the copy is upright even for apps that ignore the tag.
        let stored = Fixtures.stored(first)
        #expect(stored.width == 100 && stored.height == 200)
        #expect(Fixtures.orientation(of: first) == 1)
    }
}

@Suite("Histogram")
struct HistogramTests {
    @Test func pureRedPeaksAtTheEnds() throws {
        let folder = TempFolder()
        let url = Fixtures.write(Fixtures.solid(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)), to: folder.file("red.png"), type: "public.png")
        let histogram = try #require(Histogram.compute(for: url))
        #expect(histogram.red[255] == 1)
        #expect(histogram.green[0] == 1)
        #expect(histogram.blue[0] == 1)
        // Luminance of pure red is ~21% of white.
        let lumaPeak = try #require(histogram.luminance.firstIndex(of: 1))
        #expect((50...58).contains(lumaPeak))
        #expect(histogram.red.allSatisfy { (0...1).contains($0) })
    }
}
