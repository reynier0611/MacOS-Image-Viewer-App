import AppKit
import MapKit
import os
import SwiftUI

/// A photo or video with a location, as placed on the map.
struct MapPhoto: Equatable {
    let item: FileItem
    let coordinate: Coordinate
    var taken: Date?

    /// The items the map shows: whatever the grid shows (flattened subfolders, search, filters)
    /// that has a location.
    static func from(_ items: [FileItem], info: [URL: MediaInfo]) -> [MapPhoto] {
        items.compactMap { item in
            info[item.url]?.coordinate.map { MapPhoto(item: item, coordinate: $0, taken: info[item.url]?.captureDate) }
        }
    }
}

/// The browser's map layout: every located photo as a pin whose head is its thumbnail. Nearby
/// pins cluster into one bubble with a count, and split apart as you zoom in.
struct PhotoMapBrowser: View {
    @Environment(BrowserModel.self) private var model

    var body: some View {
        let photos = MapPhoto.from(model.images, info: model.mediaInfo)
        let indexed = model.images.filter { model.mediaInfo[$0.url] != nil }.count
        PhotoMapView(
            photos: photos,
            fitKey: "\(model.folder?.path ?? "")|\(model.showsAllSubfolders)",
            selection: model.selection,
            isInteractive: !model.isViewing,
            onSelect: { model.selection = $0 },
            onOpen: { url in
                if let index = model.images.firstIndex(where: { $0.url == url }) { model.openImage(at: index) }
            }
        )
        .overlay(alignment: .top) {
            HStack(spacing: 8) {
                Image(systemName: "mappin.and.ellipse")
                Text("\(photos.count) of \(model.images.count) item\(model.images.count == 1 ? " has" : "s have") a location")
                if indexed < model.images.count {
                    ProgressView().controlSize(.small)
                    Text("reading \(indexed)/\(model.images.count)…")
                        .foregroundStyle(.secondary)
                }
            }
            .font(.callout)
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .glassSurface(in: Capsule())
            .padding(.top, 10)
        }
    }
}

struct PhotoMapView: NSViewRepresentable {
    let photos: [MapPhoto]
    /// Changes when the folder (or flattening) changes; the map re-frames to fit the pins then.
    let fitKey: String
    let selection: URL?
    /// False while the viewer covers the map, so clicks there never reach hidden pins.
    var isInteractive = true
    let onSelect: (URL) -> Void
    let onOpen: (URL) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    static func dismantleNSView(_ map: MKMapView, coordinator: Coordinator) {
        coordinator.stopWatchingClicks()
    }

    func makeNSView(context: Context) -> MKMapView {
        let map = MKMapView()
        map.delegate = context.coordinator
        context.coordinator.watchClicks(on: map)
        map.showsZoomControls = true
        map.showsCompass = true
        map.showsScale = true
        map.register(PhotoPinView.self, forAnnotationViewWithReuseIdentifier: PhotoPinView.reuseID)
        map.register(PhotoClusterView.self, forAnnotationViewWithReuseIdentifier: PhotoClusterView.clusterReuseID)
        return map
    }

    func updateNSView(_ map: MKMapView, context: Context) {
        let coordinator = context.coordinator
        coordinator.onSelect = onSelect
        coordinator.onOpen = onOpen
        coordinator.selection = selection
        coordinator.isInteractive = isInteractive
        for case let pin as PhotoPinView in map.annotations.compactMap(map.view(for:)) where !(pin is PhotoClusterView) {
            pin.isPinSelected = pin.url == selection
        }

        // Add/remove only what changed, so pins don't flicker as the metadata index fills in.
        let wanted = Dictionary(uniqueKeysWithValues: photos.map { ($0.item.url, $0) })
        let existing = map.annotations.compactMap { $0 as? PhotoAnnotation }
        let stale = existing.filter { wanted[$0.photo.item.url] != $0.photo }
        map.removeAnnotations(stale)
        let kept = Set(existing.map(\.photo.item.url)).subtracting(stale.map(\.photo.item.url))
        let added = photos.filter { !kept.contains($0.item.url) }.map(PhotoAnnotation.init)
        map.addAnnotations(added)

        if coordinator.fittedKey != fitKey || (coordinator.fittedCount == 0 && !photos.isEmpty) {
            coordinator.fittedKey = fitKey
            coordinator.fittedCount = photos.count
            let annotations = map.annotations.filter { $0 is PhotoAnnotation }
            if !annotations.isEmpty {
                map.showAnnotations(annotations, animated: false)
            }
        }
    }

    final class Coordinator: NSObject, MKMapViewDelegate {
        var fittedKey: String?
        var fittedCount = 0
        var onSelect: (URL) -> Void = { _ in }
        var onOpen: (URL) -> Void = { _ in }
        var selection: URL?
        var isInteractive = true
        private weak var map: MKMapView?
        private var clickMonitor: Any?
        private var swallowNextMouseUp = false
        /// What map clicks hit, in the system log (no file names), to diagnose click problems:
        /// log show --last 10m --predicate 'subsystem == "local.imageviewer"'
        static let log = Logger(subsystem: "local.imageviewer", category: "map")

        /// Pin clicks are caught here, before MapKit sees them. Clicking a pin inside the map
        /// doesn't reliably reach the pin view (the map's own selection and double-click-to-zoom
        /// compete for it), so the app finds the pin under the pointer itself, handles the click,
        /// and keeps it from the map. Clicks anywhere else pass through, so panning and zooming
        /// the map work as usual.
        func watchClicks(on map: MKMapView) {
            self.map = map
            clickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp]) { [weak self] event in
                guard let self else { return event }
                return MainActor.assumeIsolated { self.consumes(event) } ? nil : event
            }
        }

        func stopWatchingClicks() {
            if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
            clickMonitor = nil
        }

        deinit {
            if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
        }

        /// Handles a click on a pin and returns true to keep it from the map.
        @MainActor
        func consumes(_ event: NSEvent) -> Bool {
            if event.type == .leftMouseUp {
                defer { swallowNextMouseUp = false }
                return swallowNextMouseUp
            }
            guard isInteractive, let map, let window = map.window, event.window === window,
                  window.attachedSheet == nil
            else { return false }
            guard let pin = pin(at: event.locationInWindow, in: map) else {
                Self.log.notice("map click: count=\(event.clickCount) hit=nothing (passed to the map)")
                return false
            }
            if let cluster = pin as? PhotoClusterView {
                Self.log.notice("map click: count=\(event.clickCount) hit=cluster of \(cluster.memberCount) → list")
                cluster.showMembers()
            } else if event.clickCount >= 2 {
                Self.log.notice("map click: count=\(event.clickCount) hit=pin → open")
                pin.open()
            } else {
                Self.log.notice("map click: count=\(event.clickCount) hit=pin → select")
                pin.select()
            }
            swallowNextMouseUp = true
            return true
        }

        /// The topmost visible pin (or cluster) under a point in window coordinates.
        @MainActor
        func pin(at windowPoint: CGPoint, in map: MKMapView) -> PhotoPinView? {
            guard map.bounds.contains(map.convert(windowPoint, from: nil)) else { return nil }
            func pins(_ view: NSView) -> [PhotoPinView] {
                ((view as? PhotoPinView).map { [$0] } ?? []) + view.subviews.flatMap(pins)
            }
            return pins(map).last { pin in
                !pin.isHiddenOrHasHiddenAncestor && pin.alphaValue > 0.01
                    && pin.bounds.contains(pin.convert(windowPoint, from: nil))
            }
        }

        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            if let cluster = annotation as? MKClusterAnnotation {
                let view = mapView.dequeueReusableAnnotationView(withIdentifier: PhotoClusterView.clusterReuseID, for: cluster) as? PhotoClusterView
                view?.configure(
                    with: cluster,
                    // Zoom into the cluster; it splits apart as it gets room.
                    onZoom: { [weak mapView] in mapView?.showAnnotations(cluster.memberAnnotations, animated: true) },
                    onOpen: { [weak self] url in self?.onOpen(url) }
                )
                return view
            }
            guard let photo = annotation as? PhotoAnnotation else { return nil }
            let url = photo.photo.item.url
            let view = mapView.dequeueReusableAnnotationView(withIdentifier: PhotoPinView.reuseID, for: photo) as? PhotoPinView
            view?.configure(
                with: photo,
                onSelect: { [weak self] in self?.onSelect(url) },
                onOpen: { [weak self] in self?.onOpen(url) }
            )
            view?.isPinSelected = url == selection
            return view
        }

        /// Fallback if MapKit itself selects a pin (e.g. via accessibility): keep the app in step.
        func mapView(_ mapView: MKMapView, didSelect view: MKAnnotationView) {
            if let cluster = view.annotation as? MKClusterAnnotation {
                // Zoom into the cluster; it splits apart as it gets room.
                mapView.deselectAnnotation(cluster, animated: false)
                mapView.showAnnotations(cluster.memberAnnotations, animated: true)
            } else if let photo = view.annotation as? PhotoAnnotation {
                onSelect(photo.photo.item.url)
            }
        }
    }
}

final class PhotoAnnotation: NSObject, MKAnnotation {
    let photo: MapPhoto
    init(_ photo: MapPhoto) { self.photo = photo }
    var coordinate: CLLocationCoordinate2D { photo.coordinate.location }
    var title: String? { photo.item.name }
}

/// A pin whose head is the photo's thumbnail: a rounded square with a white frame and a pointer.
/// It handles its own clicks (MapKit's built-in pin selection proved unreliable on macOS):
/// a click selects it and shows a preview with an Open button; a double-click opens it.
/// Note: annotation views are flipped (y grows downward), so the head is at the top here.
class PhotoPinView: MKAnnotationView {
    static let reuseID = "photo"
    static let clusterID = "photos"
    static let headSize: CGFloat = 46
    /// Only one preview open at a time, across all pins.
    private static weak var openPreview: NSPopover?

    private let thumbnail = CALayer()
    private let frameLayer = CAShapeLayer()
    private var loadTask: Task<Void, Never>?
    private var photo: MapPhoto?
    private var onSelect: () -> Void = {}
    private var onOpen: () -> Void = {}
    private var pendingPreview: Task<Void, Never>?
    var url: URL? { photo?.item.url }
    var isPinSelected = false {
        didSet { if isPinSelected != oldValue { drawFrame(selected: isPinSelected) } }
    }

    override init(annotation: MKAnnotation?, reuseIdentifier: String?) {
        super.init(annotation: annotation, reuseIdentifier: reuseIdentifier)
        let size = Self.headSize
        frame = CGRect(x: 0, y: 0, width: size + 6, height: size + 14)
        centerOffset = CGPoint(x: 0, y: -frame.height / 2) // the pointer's tip sits on the location
        wantsLayer = true
        collisionMode = .rectangle
        displayPriority = .defaultHigh
        canShowCallout = false
        clusteringIdentifier = Self.clusterID // set up front: MapKit reads it when placing the view
        frameLayer.fillColor = NSColor.white.cgColor
        frameLayer.shadowColor = NSColor.black.cgColor
        frameLayer.shadowOpacity = 0.35
        frameLayer.shadowRadius = 3
        frameLayer.shadowOffset = CGSize(width: 0, height: -1)
        layer?.addSublayer(frameLayer)
        thumbnail.frame = CGRect(x: 6, y: 6, width: size - 6, height: size - 6)
        thumbnail.cornerRadius = 6
        thumbnail.masksToBounds = true
        thumbnail.contentsGravity = .resizeAspectFill
        thumbnail.backgroundColor = NSColor(white: 0.85, alpha: 1).cgColor
        layer?.addSublayer(thumbnail)
        drawFrame(selected: false)

        // Clicks are delivered by the map's coordinator (see `Coordinator.handle`).
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Single click: select the photo, and show its preview once it's clear this isn't the start
    /// of a double-click.
    func select() {
        onSelect()
        // Wait out the double-click interval first: an open preview would swallow the second
        // click of a double-click (like Finder, which waits before starting a rename).
        pendingPreview?.cancel()
        pendingPreview = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(NSEvent.doubleClickInterval))
            guard !Task.isCancelled else { return }
            self?.showPreview()
        }
    }

    func open() {
        pendingPreview?.cancel()
        Self.openPreview?.close()
        onOpen()
    }

    /// For tests: the preview currently shown by a pin, if any.
    static var currentPreview: NSPopover? { openPreview }

    static func closePreview() { openPreview?.close() }
    static func remember(_ popover: NSPopover) { openPreview = popover }

    func showPreview() {
        guard let photo, window != nil else { return }
        Self.openPreview?.close()
        let popover = NSPopover()
        popover.behavior = .transient // closes when you click elsewhere
        let open = onOpen
        popover.contentViewController = NSHostingController(rootView: MapPhotoPreview(photo: photo) { [weak popover] in
            popover?.close()
            open()
        })
        popover.show(relativeTo: bounds, of: self, preferredEdge: .minY) // above the pin (this view is flipped)
        Self.openPreview = popover
    }

    /// White rounded head plus a small pointer underneath (accent-colored when selected).
    private func drawFrame(selected: Bool) {
        let size = Self.headSize
        let head = CGRect(x: 3, y: 3, width: size, height: size)
        let path = CGMutablePath()
        path.addRoundedRect(in: head, cornerWidth: 9, cornerHeight: 9)
        path.move(to: CGPoint(x: head.midX - 7, y: head.maxY))
        path.addLine(to: CGPoint(x: head.midX, y: head.maxY + 9)) // the tip, at the bottom
        path.addLine(to: CGPoint(x: head.midX + 7, y: head.maxY))
        path.closeSubpath()
        frameLayer.path = path
        frameLayer.fillColor = (selected ? NSColor.controlAccentColor : .white).cgColor
    }

    func configure(with annotation: PhotoAnnotation, onSelect: @escaping () -> Void, onOpen: @escaping () -> Void) {
        self.annotation = annotation
        photo = annotation.photo
        self.onSelect = onSelect
        self.onOpen = onOpen
        clusteringIdentifier = Self.clusterID
        load(annotation.photo.item)
    }

    func load(_ item: FileItem) {
        loadTask?.cancel()
        thumbnail.contents = ThumbnailLoader.shared.cached(for: item, maxPixel: 128)
        guard thumbnail.contents == nil else { return }
        loadTask = Task { @MainActor [weak self] in
            let image = await ThumbnailLoader.shared.thumbnail(for: item, maxPixel: 128)
            guard !Task.isCancelled else { return }
            self?.thumbnail.contents = image
        }
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        loadTask?.cancel()
        pendingPreview?.cancel()
        thumbnail.contents = nil
        photo = nil
        isPinSelected = false
    }
}

/// Several nearby photos: a stacked thumbnail with a count badge. A click zooms in.
final class PhotoClusterView: PhotoPinView {
    static let clusterReuseID = "cluster"
    private let badge = CATextLayer()
    private let shadowCard = CALayer()
    private var onZoom: () -> Void = {}
    private var onOpenMember: (URL) -> Void = { _ in }
    private var members: [MapPhoto] = []
    var memberCount: Int { members.count }

    override init(annotation: MKAnnotation?, reuseIdentifier: String?) {
        super.init(annotation: annotation, reuseIdentifier: reuseIdentifier)
        clusteringIdentifier = nil // a cluster isn't itself clustered
        displayPriority = .required
        // A second card peeking out behind, so it reads as a stack.
        shadowCard.frame = CGRect(x: 9, y: 0, width: Self.headSize - 2, height: Self.headSize - 2)
        shadowCard.backgroundColor = NSColor.white.withAlphaComponent(0.9).cgColor
        shadowCard.cornerRadius = 9
        shadowCard.setAffineTransform(CGAffineTransform(rotationAngle: -0.12))
        layer?.insertSublayer(shadowCard, at: 0)
        badge.fontSize = 11
        badge.font = NSFont.boldSystemFont(ofSize: 11)
        badge.alignmentMode = .center
        badge.foregroundColor = NSColor.white.cgColor
        badge.backgroundColor = NSColor.systemRed.cgColor
        badge.cornerRadius = 9
        badge.contentsScale = 2
        layer?.addSublayer(badge)
    }

    required init?(coder: NSCoder) { fatalError() }

    func zoom() { onZoom() }

    /// Photos taken at the same spot never separate however far you zoom, so a click lists them
    /// (click one to open it), with Zoom In for the rest.
    func showMembers() {
        guard window != nil else { return }
        Self.closePreview()
        let popover = NSPopover()
        popover.behavior = .transient
        let open = onOpenMember, zoom = onZoom
        popover.contentViewController = NSHostingController(rootView: ClusterPreview(
            photos: members,
            onOpen: { [weak popover] url in popover?.close(); open(url) },
            onZoom: { [weak popover] in popover?.close(); zoom() }
        ))
        popover.show(relativeTo: bounds, of: self, preferredEdge: .minY)
        Self.remember(popover)
    }

    func configure(with cluster: MKClusterAnnotation, onZoom: @escaping () -> Void, onOpen: @escaping (URL) -> Void = { _ in }) {
        annotation = cluster
        self.onZoom = onZoom
        onOpenMember = onOpen
        members = cluster.memberAnnotations.compactMap { ($0 as? PhotoAnnotation)?.photo }
            .sorted { $0.item.name.localizedStandardCompare($1.item.name) == .orderedAscending }
        let count = cluster.memberAnnotations.count
        badge.string = count > 999 ? "999+" : "\(count)"
        let width = max(18, CGFloat(String(count > 999 ? "999+" : "\(count)").count) * 7 + 10)
        badge.frame = CGRect(x: frame.width - width + 4, y: -4, width: width, height: 18) // top-right corner
        if let first = cluster.memberAnnotations.compactMap({ $0 as? PhotoAnnotation }).first {
            load(first.photo.item)
        }
    }
}

/// What a click on a pin shows: a bigger preview, the name and date, and an Open button.
struct MapPhotoPreview: View {
    let photo: MapPhoto
    let onOpen: () -> Void
    @State private var image: NSImage?

    var body: some View {
        VStack(spacing: 8) {
            Group {
                if let image {
                    Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
                } else {
                    ProgressView()
                }
            }
            .frame(width: 260, height: 180)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            Text(photo.item.name)
                .font(.headline)
                .lineLimit(1)
                .truncationMode(.middle)
            if let taken = photo.taken {
                Text(taken.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Button("Open", action: onOpen)
                .keyboardShortcut(.defaultAction)
                .help("Open in the viewer (or double-click the pin)")
        }
        .padding(12)
        .frame(width: 284)
        .task { image = await ThumbnailLoader.shared.thumbnail(for: photo.item, maxPixel: 512) }
    }
}

/// What a click on a cluster shows: its photos (click one to open it) and a Zoom In button.
struct ClusterPreview: View {
    let photos: [MapPhoto]
    let onOpen: (URL) -> Void
    let onZoom: () -> Void
    private let columns = [GridItem(.adaptive(minimum: 76), spacing: 6)]

    var body: some View {
        VStack(spacing: 10) {
            HStack {
                Text("\(photos.count) photos here")
                    .font(.headline)
                Spacer()
                Button("Zoom In", action: onZoom)
            }
            ScrollView {
                LazyVGrid(columns: columns, spacing: 6) {
                    ForEach(photos, id: \.item.url) { photo in
                        Button { onOpen(photo.item.url) } label: {
                            ThumbnailView(item: photo.item, size: 72)
                        }
                        .buttonStyle(.plain)
                        .help("Open “\(photo.item.name)”")
                    }
                }
            }
            .frame(height: min(CGFloat((photos.count + 3) / 4) * 84, 260))
            Text("Click a photo to open it")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .frame(width: 340)
    }
}
