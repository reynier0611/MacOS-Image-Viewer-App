import AppKit
import MapKit
import Foundation
import Testing
@testable import ImageViewer

@Suite("Thumbnail disk cache", .serialized)
struct ThumbnailDiskCacheTests {
    let folder = TempFolder()

    func cache(maxBytes: Int64 = 500_000_000) -> ThumbnailDiskCache {
        ThumbnailDiskCache(directory: folder.url.appendingPathComponent("cache", isDirectory: true), maxBytes: maxBytes)
    }

    func photo(_ name: String) -> FileItem {
        Fixtures.item(Fixtures.write(Fixtures.leftRedRightBlue(), to: folder.file(name)))
    }

    @Test func roundTripAndAFreshEntryWhenTheFileChanges() throws {
        let cache = cache()
        let item = photo("a.jpg")
        #expect(cache.read(item, maxPixel: 256) == nil)
        cache.write(Fixtures.leftRedRightBlue(), for: item, maxPixel: 256)
        let back = try #require(cache.read(item, maxPixel: 256))
        #expect(back.width == 200 && back.height == 100)
        #expect(cache.read(item, maxPixel: 512) == nil) // other sizes are separate

        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(60)], ofItemAtPath: item.url.path)
        // A fresh URL: Foundation caches file attributes per URL object, and the app always gets fresh ones from a scan.
        let edited = Fixtures.item(URL(fileURLWithPath: item.url.path))
        #expect(edited.modified != item.modified)
        #expect(cache.read(edited, maxPixel: 256) == nil) // edited file: not reused
    }

    @Test func keepsTransparency() throws {
        let cache = cache()
        let item = photo("logo.png")
        let clear = Fixtures.image(width: 100, height: 100) { c in
            c.clear(CGRect(x: 0, y: 0, width: 100, height: 100))
            c.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)); c.fill(CGRect(x: 25, y: 25, width: 50, height: 50))
        }
        cache.write(clear, for: item, maxPixel: 128)
        #expect(Transparency.hasTransparentPixels(try #require(cache.read(item, maxPixel: 128))))
    }

    @Test func switchedOffStoresNothing() {
        UserDefaults.standard.set(false, forKey: ThumbnailDiskCache.enabledKey)
        defer { UserDefaults.standard.removeObject(forKey: ThumbnailDiskCache.enabledKey) }
        let cache = cache()
        let item = photo("a.jpg")
        cache.write(Fixtures.leftRedRightBlue(), for: item, maxPixel: 256)
        #expect(cache.totalBytes == 0)
    }

    @Test func clearAndPruneToTheLimit() throws {
        let big = cache()
        for index in 0..<20 { big.write(Fixtures.leftRedRightBlue(width: 400, height: 400), for: photo("\(index).jpg"), maxPixel: 256) }
        let total = big.totalBytes
        #expect(total > 0)

        let capped = cache(maxBytes: total / 2)
        capped.prune()
        #expect(capped.totalBytes <= total / 2 * 8 / 10 + 10_000)
        capped.clear()
        #expect(capped.totalBytes == 0)
    }

    @Test func theAppsThumbnailsLandInTheCache() async throws {
        let item = photo("fresh.jpg")
        let file = ThumbnailDiskCache.shared.fileURL(for: item, maxPixel: 256)
        defer { try? FileManager.default.removeItem(at: file) }
        _ = await ThumbnailLoader.shared.thumbnail(for: item, maxPixel: 256)
        for _ in 0..<50 where !FileManager.default.fileExists(atPath: file.path) { try await Task.sleep(for: .milliseconds(20)) }
        #expect(FileManager.default.fileExists(atPath: file.path))
    }
}

@Suite("World map")
struct MapTests {
    @Test func placesOnlyItemsWithALocation() {
        let folder = TempFolder()
        let located = Fixtures.item(Fixtures.write(Fixtures.leftRedRightBlue(), to: folder.file("madrid.jpg"), latitude: 40.4, longitude: -3.7))
        let nowhere = Fixtures.item(Fixtures.write(Fixtures.leftRedRightBlue(), to: folder.file("nowhere.jpg")))
        let info = [located.url: MediaIndex.readImage(located.url), nowhere.url: MediaIndex.readImage(nowhere.url)]
        let photos = MapPhoto.from([located, nowhere], info: info)
        #expect(photos.map(\.item.name) == ["madrid.jpg"])
        #expect(photos.first?.coordinate == Coordinate(latitude: 40.4, longitude: -3.7))
    }
}

@Suite("Opening from the map")
@MainActor
struct MapOpeningTests {
    let folder = TempFolder()

    func photo(_ name: String = "rome.jpg") -> MapPhoto {
        let item = Fixtures.item(Fixtures.write(Fixtures.leftRedRightBlue(), to: folder.file(name), latitude: 41.9, longitude: 12.5))
        return MapPhoto(item: item, coordinate: Coordinate(latitude: 41.9, longitude: 12.5))
    }

    /// A map in a window with one pin placed at a known spot, as MapKit would place it.
    struct Scene {
        let window: NSWindow
        let map: MKMapView
        let pin: PhotoPinView
        let coordinator: PhotoMapView.Coordinator
        var selected = 0, opened = 0

        func event(_ type: NSEvent.EventType, at point: CGPoint, count: Int) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0,
                               windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: count, pressure: 1)!
        }
        var pinHead: CGPoint { pin.convert(CGPoint(x: pin.bounds.midX, y: 25), to: nil) }
    }

    func scene(onSelect: @escaping () -> Void, onOpen: @escaping () -> Void) -> Scene {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        let map = MKMapView(frame: window.contentView!.bounds)
        window.contentView?.addSubview(map)
        let coordinator = PhotoMapView.Coordinator()
        coordinator.watchClicks(on: map)
        let pin = PhotoPinView(annotation: nil, reuseIdentifier: nil)
        pin.configure(with: PhotoAnnotation(photo()), onSelect: onSelect, onOpen: onOpen)
        pin.frame.origin = CGPoint(x: 150, y: 100)
        map.addSubview(pin)
        return Scene(window: window, map: map, pin: pin, coordinator: coordinator)
    }

    /// Regression: clicks on pins inside the real map didn't reliably reach the pin views, so pin
    /// clicks are caught by an event monitor before MapKit (verified in the running app).
    @Test func doubleClickOnAPinOpensItAndIsKeptFromTheMap() {
        var opened = 0
        let s = scene(onSelect: {}, onOpen: { opened += 1 })
        defer { s.coordinator.stopWatchingClicks() }
        #expect(s.coordinator.consumes(s.event(.leftMouseDown, at: s.pinHead, count: 2)))
        #expect(s.coordinator.consumes(s.event(.leftMouseUp, at: s.pinHead, count: 2))) // its mouse-up too
        #expect(opened == 1)
    }

    @Test func singleClickSelects() {
        var selected = 0
        let s = scene(onSelect: { selected += 1 }, onOpen: {})
        defer { s.coordinator.stopWatchingClicks() }
        #expect(s.coordinator.consumes(s.event(.leftMouseDown, at: s.pinHead, count: 1)))
        #expect(selected == 1)
    }

    @Test func clicksElsewhereOrOnHiddenPinsGoToTheMap() {
        var touched = 0
        let s = scene(onSelect: { touched += 1 }, onOpen: { touched += 1 })
        defer { s.coordinator.stopWatchingClicks() }
        #expect(!s.coordinator.consumes(s.event(.leftMouseDown, at: CGPoint(x: 20, y: 20), count: 2))) // empty map: zooms as usual
        #expect(!s.coordinator.consumes(s.event(.leftMouseUp, at: CGPoint(x: 20, y: 20), count: 2)))
        s.pin.isHidden = true // e.g. merged into a cluster
        #expect(!s.coordinator.consumes(s.event(.leftMouseDown, at: s.pinHead, count: 1)))
        s.pin.isHidden = false
        s.coordinator.isInteractive = false // the viewer covers the map
        #expect(!s.coordinator.consumes(s.event(.leftMouseDown, at: s.pinHead, count: 2)))
        #expect(touched == 0)
    }

    @Test func clustersZoomInAndAreFormedUpFront() {
        let pin = PhotoPinView(annotation: nil, reuseIdentifier: nil)
        #expect(pin.clusteringIdentifier == PhotoPinView.clusterID) // set before MapKit places the view
        #expect(!pin.canShowCallout) // our own preview instead of MapKit's callout
        let cluster = PhotoClusterView(annotation: nil, reuseIdentifier: nil)
        var zoomed = 0
        cluster.configure(with: MKClusterAnnotation(memberAnnotations: [PhotoAnnotation(photo())])) { zoomed += 1 }
        #expect(cluster.clusteringIdentifier == nil)
        cluster.zoom()
        #expect(zoomed == 1)
    }

    /// Photos taken at the same spot never separate by zooming, so a cluster click lists them.
    @Test func aClusterListsItsPhotosAndOpensThePickedOne() {
        let a = photo("b.jpg"), b = photo("a.jpg") // same spot
        let cluster = PhotoClusterView(annotation: nil, reuseIdentifier: nil)
        var opened: URL?
        cluster.configure(with: MKClusterAnnotation(memberAnnotations: [PhotoAnnotation(a), PhotoAnnotation(b)]), onZoom: {}, onOpen: { opened = $0 })
        #expect(cluster.memberCount == 2)

        var zoomed = 0
        let list = ClusterPreview(photos: [b, a], onOpen: { opened = $0 }, onZoom: { zoomed += 1 })
        list.onOpen(a.item.url)
        #expect(opened == a.item.url)
        list.onZoom()
        #expect(zoomed == 1)
    }

    @Test func clickingAClusterIsHandledByTheApp() {
        let s = scene(onSelect: {}, onOpen: {})
        defer { s.coordinator.stopWatchingClicks() }
        let cluster = PhotoClusterView(annotation: nil, reuseIdentifier: nil)
        cluster.configure(with: MKClusterAnnotation(memberAnnotations: [PhotoAnnotation(photo())]), onZoom: {}, onOpen: { _ in })
        cluster.frame.origin = CGPoint(x: 260, y: 160)
        s.map.addSubview(cluster)
        let head = cluster.convert(CGPoint(x: cluster.bounds.midX, y: 25), to: nil)
        #expect(s.coordinator.consumes(s.event(.leftMouseDown, at: head, count: 2))) // never reaches the map's zoom
    }

    @Test func thePreviewShowsNameAndDateAndItsOpenButtonOpens() {
        var opened = 0
        let photo = MapPhoto(item: photo().item, coordinate: Coordinate(latitude: 41.9, longitude: 12.5), taken: Date())
        let preview = MapPhotoPreview(photo: photo) { opened += 1 }
        preview.onOpen()
        #expect(opened == 1)
        #expect(MapPhoto.from([photo.item], info: [photo.item.url: MediaInfo(captureDate: photo.taken, coordinate: photo.coordinate)]).first?.taken == photo.taken)
    }
}
