import AVFoundation
import AppKit
import ImageIO
import UniformTypeIdentifiers

/// Caps how many decodes run at once so fast scrolling doesn't flood the CPU.
actor AsyncLimiter {
    private var available: Int
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(_ limit: Int) { available = limit }

    func acquire() async {
        if available > 0 {
            available -= 1
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        if waiters.isEmpty {
            available += 1
        } else {
            waiters.removeFirst().resume()
        }
    }
}

/// Small, downsampled images for the grid, filmstrip and inspector.
final class ThumbnailLoader: @unchecked Sendable {
    static let shared = ThumbnailLoader()

    private let cache = NSCache<NSString, NSImage>()
    /// Most recent thumbnail per file regardless of size, used as a placeholder while the full image decodes.
    private let latest = NSCache<NSURL, NSImage>()
    private let limiter = AsyncLimiter(max(2, ProcessInfo.processInfo.activeProcessorCount - 2))

    private init() {
        cache.countLimit = 3000
        latest.countLimit = 3000
    }

    func cached(for item: FileItem, maxPixel: Int) -> NSImage? {
        cache.object(forKey: key(item, maxPixel))
    }

    func latest(for url: URL) -> NSImage? {
        latest.object(forKey: url as NSURL)
    }

    /// Drops the placeholder thumbnail after the file's pixels change (e.g. rotation).
    func invalidate(_ url: URL) {
        latest.removeObject(forKey: url as NSURL)
    }

    func thumbnail(for item: FileItem, maxPixel: Int) async -> NSImage? {
        let key = key(item, maxPixel)
        if let image = cache.object(forKey: key) { return image }

        await limiter.acquire()
        if Task.isCancelled {
            await limiter.release()
            return nil
        }
        let url = item.url
        let image: NSImage?
        if item.isVideo {
            image = await Self.makeVideoThumbnail(url: url, maxPixel: maxPixel)
        } else {
            image = await Task.detached(priority: .userInitiated) {
                Self.makeThumbnail(url: url, maxPixel: maxPixel)
            }.value
        }
        await limiter.release()

        if let image {
            cache.setObject(image, forKey: key)
            latest.setObject(image, forKey: url as NSURL)
        }
        return image
    }

    private func key(_ item: FileItem, _ maxPixel: Int) -> NSString {
        "\(item.url.path)|\(maxPixel)|\(item.modified.timeIntervalSince1970)" as NSString
    }

    /// A frame about a second in (or a third of the way into very short clips), which avoids black opening frames.
    private static func makeVideoThumbnail(url: URL, maxPixel: Int) async -> NSImage? {
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: maxPixel, height: maxPixel)
        generator.requestedTimeToleranceBefore = CMTime(seconds: 1, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 1, preferredTimescale: 600)
        let duration = (try? await asset.load(.duration))?.seconds ?? 0
        let time = CMTime(seconds: duration.isFinite ? min(1, duration / 3) : 0, preferredTimescale: 600)
        guard let cgImage = try? await generator.image(at: time).image else { return nil }
        return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    }

    private static func makeThumbnail(url: URL, maxPixel: Int) -> NSImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else {
            return NSImage(contentsOf: url)
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return NSImage(contentsOf: url)
        }
        return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    }
}

/// Full-resolution images for the viewer, decoded off the main thread and kept in a memory-bounded cache.
final class ImageLoader: @unchecked Sendable {
    static let shared = ImageLoader()

    private let cache = NSCache<NSURL, NSImage>()
    private static let maxDecodedPixels = 16_384

    private init() {
        cache.totalCostLimit = 1024 * 1024 * 1024
    }

    func cachedImage(for url: URL) -> NSImage? {
        cache.object(forKey: url as NSURL)
    }

    func invalidate(_ url: URL) {
        cache.removeObject(forKey: url as NSURL)
    }

    func load(_ url: URL) async -> NSImage? {
        if let image = cache.object(forKey: url as NSURL) { return image }
        let (image, cost) = await Task.detached(priority: .userInitiated) {
            Self.decode(url)
        }.value
        if let image {
            cache.setObject(image, forKey: url as NSURL, cost: cost)
        }
        return image
    }

    /// A blurry stand-in (the grid thumbnail) sized like the real image, so the viewer can show something instantly.
    func placeholder(for url: URL) -> NSImage? {
        guard let thumb = ThumbnailLoader.shared.latest(for: url),
              let cgImage = thumb.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let size = Self.pixelSize(of: url)
        else { return nil }
        return NSImage(cgImage: cgImage, size: size)
    }

    static func pixelSize(of url: URL) -> NSSize? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = (props[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let height = (props[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue
        else { return nil }
        let orientation = (props[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        // EXIF orientations 5–8 are rotated 90°, so width and height swap.
        return (5...8).contains(orientation)
            ? NSSize(width: height, height: width)
            : NSSize(width: width, height: height)
    }

    private static func decode(_ url: URL) -> (NSImage?, Int) {
        // NSImage keeps GIF frames so the viewer can animate them.
        if UTType(filenameExtension: url.pathExtension)?.conforms(to: .gif) == true,
           let image = NSImage(contentsOf: url) {
            return (image, Int(image.size.width * image.size.height * 4))
        }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            return fallback(url)
        }
        var options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        if let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
           let width = (props[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
           let height = (props[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue {
            options[kCGImageSourceThumbnailMaxPixelSize] = min(max(width, height), maxDecodedPixels)
        }
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return fallback(url)
        }
        let image = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        return (image, cgImage.bytesPerRow * cgImage.height)
    }

    private static func fallback(_ url: URL) -> (NSImage?, Int) {
        guard let image = NSImage(contentsOf: url) else { return (nil, 0) }
        return (image, Int(image.size.width * image.size.height * 4))
    }
}

enum Transparency {
    /// Whether the image actually has see-through pixels. Many PNGs carry an alpha channel but are
    /// fully opaque, so this samples a small copy instead of trusting the format.
    static func hasTransparentPixels(_ image: CGImage) -> Bool {
        switch image.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast: return false
        default: break
        }
        let side = 64
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        guard let context = CGContext(
            data: &pixels, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return false }
        context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
        return stride(from: 3, to: pixels.count, by: 4).contains { pixels[$0] < 250 }
    }

    static func hasTransparentPixels(_ image: NSImage) -> Bool {
        image.cgImage(forProposedRect: nil, context: nil, hints: nil).map(hasTransparentPixels) ?? false
    }
}
