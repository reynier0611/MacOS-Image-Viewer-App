import AVFoundation
import CoreVideo
import Foundation
import ImageIO
import Testing
@testable import ImageViewer

enum VideoFixtures {
    /// A real, playable H.264 video (64×64, 10 frames).
    static func make(at url: URL, type: AVFileType = .mov) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: type)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 64, AVVideoHeightKey: 64,
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: 64, kCVPixelBufferHeightKey as String: 64,
        ])
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)
        for frame in 0..<10 {
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(5)) }
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &buffer)
            CVPixelBufferLockBaseAddress(buffer!, [])
            memset(CVPixelBufferGetBaseAddress(buffer!), Int32(frame * 20), CVPixelBufferGetDataSize(buffer!))
            CVPixelBufferUnlockBaseAddress(buffer!, [])
            adaptor.append(buffer!, withPresentationTime: CMTime(value: Int64(frame), timescale: 10))
        }
        input.markAsFinished()
        await writer.finishWriting()
        precondition(writer.status == .completed, "\(String(describing: writer.error))")
    }

    static func stillPlays(_ url: URL) async throws -> Bool {
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        let frame = try await AVAssetImageGenerator(asset: asset).image(at: CMTime(value: 5, timescale: 10)).image
        return duration.seconds > 0.5 && tracks.count == 1 && frame.width == 64
    }
}

@Suite("Ratings stored in videos")
struct VideoRatingTests {
    let folder = TempFolder()

    @Test("Rates MOV and MP4 without touching the video data", arguments: [AVFileType.mov, .mp4])
    func ratesWithoutTouchingTheVideo(type: AVFileType) async throws {
        let url = folder.file(type == .mov ? "clip.mov" : "clip.mp4")
        try await VideoFixtures.make(at: url, type: type)
        let modified = Date(timeIntervalSince1970: 1_600_000_000)
        try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
        let original = try Data(contentsOf: url)
        #expect(Ratings.canStore(in: Fixtures.item(url)))
        #expect(Ratings.read(url) == nil)

        try Ratings.write(4, to: url)

        #expect(Ratings.read(url) == 4)
        let rated = try Data(contentsOf: url)
        #expect(rated.prefix(original.count) == original) // every original byte untouched; the rating is appended
        #expect(try await VideoFixtures.stillPlays(url))
        #expect((try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date) == modified)
        #expect(try VideoXMP.topLevelBoxes(of: url).filter(\.isXMP).count == 1)
    }

    @Test func reRatingReplacesInsteadOfPilingUp() async throws {
        let url = folder.file("clip.mov")
        try await VideoFixtures.make(at: url)
        let originalSize = try Data(contentsOf: url).count
        try Ratings.write(4, to: url)
        let onceSize = try Data(contentsOf: url).count
        try Ratings.write(2, to: url)
        #expect(Ratings.read(url) == 2)
        #expect(try Data(contentsOf: url).count == onceSize) // the old (last) XMP box was replaced
        #expect(onceSize - originalSize < 4_000)
        try Ratings.write(Ratings.rejected, to: url)
        #expect(Ratings.read(url) == -1)
        #expect(try await VideoFixtures.stillPlays(url))
    }

    @Test func anOldRatingNotAtTheEndBecomesPadding() async throws {
        let url = folder.file("clip.mov")
        try await VideoFixtures.make(at: url)
        try Ratings.write(3, to: url)
        // Something else gets appended after our box (e.g. another tool's padding).
        let handle = try FileHandle(forUpdating: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data([0, 0, 0, 8]) + Data("free".utf8))
        try handle.close()

        try Ratings.write(5, to: url)

        #expect(Ratings.read(url) == 5)
        let boxes = try VideoXMP.topLevelBoxes(of: url)
        #expect(boxes.filter(\.isXMP).count == 1)
        #expect(boxes.last?.isXMP == true)
        #expect(try await VideoFixtures.stillPlays(url))
    }

    @Test func usesTheStandardXMPRatingTag() async throws {
        let url = folder.file("clip.mp4")
        try await VideoFixtures.make(at: url, type: .mp4)
        try Ratings.write(3, to: url)
        let packet = try #require(VideoXMP.readXMP(from: url))
        let metadata = try #require(CGImageMetadataCreateFromXMPData(packet as CFData))
        let tag = try #require(CGImageMetadataCopyTagWithPath(metadata, nil, "xmp:Rating" as CFString))
        #expect(CGImageMetadataTagCopyNamespace(tag) as String? == "http://ns.adobe.com/xap/1.0/")
    }

    @Test func refusesLayoutsItCannotSafelyAppendTo() throws {
        // Last box with size 0 ("extends to end of file"): appending would corrupt it.
        let openEnded = folder.file("open.mov")
        var data = Data([0, 0, 0, 16]) + Data("ftypqt  ".utf8) + Data([0, 0, 0, 0])
        data += Data([0, 0, 0, 0]) + Data("mdat".utf8) + Data(repeating: 7, count: 100)
        try data.write(to: openEnded)
        #expect(throws: (any Error).self) { try Ratings.write(4, to: openEnded) }
        #expect(try Data(contentsOf: openEnded) == data)

        // Not an MP4/QuickTime file at all, despite the name.
        let fake = folder.file("fake.mov")
        let junk = Data("this is not a video".utf8)
        try junk.write(to: fake)
        #expect(throws: (any Error).self) { try Ratings.write(4, to: fake) }
        #expect(try Data(contentsOf: fake) == junk)
    }

    @Test func otherVideoFormatsAreNotOffered() {
        FileManager.default.createFile(atPath: folder.file("clip.avi").path, contents: Data([0]))
        #expect(!Ratings.canStore(in: Fixtures.item(folder.file("clip.avi"))))
    }
}
