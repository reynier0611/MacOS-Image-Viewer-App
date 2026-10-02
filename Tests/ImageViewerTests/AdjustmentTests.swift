import AppKit
import CoreImage
import Foundation
import ImageIO
import Testing
@testable import ImageViewer

@Suite("Adjust Color")
struct AdjustmentTests {
    let folder = TempFolder()

    private func center(_ adjustments: Adjustments, gray: CGFloat = 0.5) -> (r: Int, g: Int, b: Int) {
        let input = CIImage(cgImage: Fixtures.solid(CGColor(srgbRed: gray, green: gray, blue: gray, alpha: 1)))
        let output = ImageAdjuster.render(ImageAdjuster.apply(adjustments, to: input), colorSpace: CGColorSpace(name: CGColorSpace.sRGB))!
        return Fixtures.color(of: output, x: 0.5, y: 0.5)
    }

    @Test func slidersMoveColorsTheExpectedWay() {
        let original = center(Adjustments())
        #expect(abs(original.r - 128) <= 2)
        #expect(center(Adjustments(exposure: 0.5)).r > original.r + 20)
        #expect(center(Adjustments(exposure: -0.5)).r < original.r - 20)
        let warm = center(Adjustments(temperature: 0.8))
        #expect(warm.r > warm.b + 10) // warmer = more red than blue
        let cool = center(Adjustments(temperature: -0.8))
        #expect(cool.b > cool.r + 10)
        let tinted = center(Adjustments(tint: 0.8))
        #expect(tinted.g < tinted.r) // toward magenta
        #expect(Adjustments().isUnchanged && !Adjustments(auto: true).isUnchanged)
    }

    @Test func copyKeepsMetadataAndIsUprightAndNeverOverwrites() throws {
        let url = Fixtures.write(Fixtures.leftRedRightBlue(), to: folder.file("IMG_1.jpg"),
                                 taken: "2021:05:06 07:08:09", latitude: 40.7, longitude: -74, orientation: 6)
        try Ratings.write(5, to: url)
        try Annotations.write([.addTag("trip"), .setNote("Hello")], to: url)
        let before = try Data(contentsOf: url)

        let copy = ImageAdjuster.copyURL(for: url)
        #expect(copy.lastPathComponent == "IMG_1 (edited).jpg")
        try ImageAdjuster.save(Adjustments(exposure: 0.3), from: url, to: copy)
        #expect(ImageAdjuster.copyURL(for: url).lastPathComponent == "IMG_1 (edited 2).jpg")
        #expect(try Data(contentsOf: url) == before) // original untouched

        // Saved upright: orientation baked into the pixels, tag reset.
        #expect(Fixtures.orientation(of: copy) == 1)
        let stored = Fixtures.stored(copy)
        #expect(stored.width == 100 && stored.height == 200)
        // Rotated 90° clockwise: the red left half is now on top.
        let top = Fixtures.color(of: stored, x: 0.5, y: 0.25), bottom = Fixtures.color(of: stored, x: 0.5, y: 0.75)
        #expect(top.r > 150 && top.b < 100)
        #expect(bottom.b > 150 && bottom.r < 100)

        let info = MediaIndex.readImage(copy)
        #expect(info.coordinate?.latitude == 40.7)
        #expect(info.captureDate != nil)
        #expect(info.rating == 5)
        #expect(info.annotations == Annotations(tags: ["trip"], note: "Hello"))
    }

    @Test func overwriteCanBeRestoredFromTheBackup() throws {
        let url = Fixtures.write(Fixtures.solid(CGColor(gray: 0.5, alpha: 1)), to: folder.file("photo.png"), type: "public.png")
        let original = try Data(contentsOf: url)
        #expect(ImageAdjuster.canOverwrite(url))

        let backup = try ImageAdjuster.backUp(url)
        defer { try? FileManager.default.removeItem(at: backup) }
        try ImageAdjuster.save(Adjustments(exposure: 0.6), from: url, to: url)
        #expect(Fixtures.color(of: Fixtures.stored(url), x: 0.5, y: 0.5).r > 160)
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.url.path) == ["photo.png"]) // no temp files left

        try ImageAdjuster.restore(backup, to: url)
        #expect(try Data(contentsOf: url) == original)
    }

    @Test func formatsThatCantBeRewrittenAreSavedAsJPEGCopies() throws {
        let url = Fixtures.write(Fixtures.solid(CGColor(gray: 0.5, alpha: 1)), to: folder.file("pic.bmp"), type: "com.microsoft.bmp")
        #expect(!ImageAdjuster.canOverwrite(url))
        let copy = ImageAdjuster.copyURL(for: url)
        #expect(copy.lastPathComponent == "pic (edited).jpg")
        try ImageAdjuster.save(Adjustments(contrast: 0.2), from: url, to: copy)
        let source = CGImageSourceCreateWithURL(copy as CFURL, nil)!
        #expect(CGImageSourceGetType(source) as String? == "public.jpeg")
    }
}

extension AppModelSuite.BrowserModelTests {
    @Test func adjustingPreviewsAndBlocksLeavingWithUnsavedChanges() async throws {
        try await open(["a.jpg", "b.jpg"])
        model.openImage(at: 0)
        defer { model.closeViewer() }
        try await waitUntil { model.currentImage != nil && !model.isLoadingImage }

        model.beginAdjusting()
        #expect(model.isAdjusting)
        try await waitUntil { model.adjustmentBase != nil }
        model.adjustments.exposure = 0.5
        try await waitUntil { model.adjustmentPreview != nil }
        #expect(model.adjustmentPreview?.size == model.currentImage?.size) // keeps the zoom

        model.step(1) // unsaved: stays put
        #expect(model.viewerIndex == 0)
        #expect(model.isAdjusting)

        model.adjustments = Adjustments() // nothing to lose: moving on just closes the panel
        model.step(1)
        #expect(model.viewerIndex == 1)
        #expect(!model.isAdjusting)
        #expect(model.adjustmentPreview == nil)
    }
}
