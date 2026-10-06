import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ThumbnailGrid: View {
    @Environment(BrowserModel.self) private var model
    /// Frames of every cell laid out so far. Accumulated (not replaced) because the lazy grid
    /// discards off-screen cells, and a selection rectangle can extend past the visible area.
    @State private var cellFrames: [URL: CGRect] = [:]
    @State private var cellFramesLayout = 0
    @State private var marqueeStart: CGPoint?
    @State private var marqueeEnd: CGPoint = .zero
    @State private var marqueeBase: Set<URL> = []
    @State private var autoScroller = AutoScroller()
    @State private var scrollMonitor: Any?

    private var marquee: CGRect? {
        guard let start = marqueeStart else { return nil }
        return CGRect(
            x: min(start.x, marqueeEnd.x), y: min(start.y, marqueeEnd.y),
            width: abs(marqueeEnd.x - start.x), height: abs(marqueeEnd.y - start.y)
        )
    }

    private let spacing: CGFloat = 24 // room between photos to start a selection rectangle
    private let padding: CGFloat = 16
    private static let space = "gridContent"

    var body: some View {
        let size = CGFloat(model.thumbnailSize)
        let cellWidth = size + 8

        GeometryReader { geometry in
            let columns = max(1, Int((geometry.size.width - padding * 2 + spacing) / (cellWidth + spacing)))
            // Changes whenever cell positions could change, so stale remembered frames get replaced.
            let layout = Hasher.hash(columns, size, model.listingVersion)
            // ZStack: GridBackground sits behind the ScrollView. The ScrollView's own AppKit
            // background is cleared (drawsBackground = false) so the canvas shows through.
            ZStack {
                GridBackground()
                ScrollViewReader { proxy in

                    ScrollView {
                        LazyVGrid(
                            columns: Array(repeating: GridItem(.fixed(cellWidth), spacing: spacing), count: columns),
                            spacing: 22
                        ) {
                            ForEach(model.gridItems) { item in
                                cell(for: item, size: size, layout: layout)
                            }
                        }
                        .padding(padding)
                        .frame(maxWidth: .infinity, minHeight: geometry.size.height, alignment: .top)
                        // Empty space: click to deselect, drag to draw a selection rectangle.
                        .background {
                            Color.clear
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    let flags = NSEvent.modifierFlags
                                    if !flags.contains(.command) && !flags.contains(.shift) { model.clearSelection() }
                                }
                                .gesture(marqueeGesture)
                        }
                        .background(ScrollViewFinder { sv in
                            autoScroller.scrollView = sv
                            // Let the GridBackground behind the scroll view show through.
                            sv.drawsBackground = false
                        })
                        .overlay(alignment: .topLeading) { marqueeView }
                        .coordinateSpace(name: Self.space)
                        .onPreferenceChange(CellFramesKey.self) { reported in
                            if reported.layout != cellFramesLayout {
                                cellFramesLayout = reported.layout
                                cellFrames = reported.frames
                            } else {
                                cellFrames.merge(reported.frames) { $1 }
                            }
                            if marqueeStart != nil { updateMarqueeSelection() }
                        }
                    }
                    // While images are being dragged over the grid, scroll near the edges so
                    // off-screen folders can be reached. Folder tiles handle the actual drop.
                    .onDrop(of: [.imageViewerSelection], delegate: AutoScrollDropDelegate(scroller: autoScroller))
                    .onChange(of: columns, initial: true) { model.gridColumns = columns }
                    .onChange(of: model.selection) { _, selection in
                        guard let selection, !model.isViewing, marquee == nil else { return }
                        proxy.scrollTo(selection)
                    }
                    .onChange(of: model.isViewing) { _, isViewing in
                        guard !isViewing, let selection = model.selection else { return }
                        proxy.scrollTo(selection, anchor: .center)
                    }
                }
            }
        }
        .onAppear { startScrollMonitor() }
        .onDisappear { stopScrollMonitor() }
    }

    // Trackpad pinch-to-resize thumbnails. Scroll wheel is handled by the app-level monitor
    // in ContentView so it is always active regardless of which view is on screen.
    private func startScrollMonitor() {
        let m = model
        var pinchBaseSize: CGFloat = 100
        var pinchAccum: CGFloat = 1.0

        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .magnify) { event in
            guard !m.isViewing else { return event }
            if event.phase.contains(.began) {
                pinchBaseSize = m.thumbnailSize
                pinchAccum = 1.0
            }
            pinchAccum *= (1 + event.magnification)
            DispatchQueue.main.async { m.thumbnailSize = min(400, max(80, pinchBaseSize * pinchAccum)) }
            return nil
        }
    }

    private func stopScrollMonitor() {
        if let monitor = scrollMonitor { NSEvent.removeMonitor(monitor) }
        scrollMonitor = nil
    }

    @ViewBuilder
    private func cell(for item: FileItem, size: CGFloat, layout: Int) -> some View {
        let base = GridCell(
            item: item, size: size, isSelected: model.selectedURLs.contains(item.url),
            rating: model.rating(for: item), location: subfolder(of: item)
        )
            .background(GeometryReader { geometry in
                Color.clear.preference(
                    key: CellFramesKey.self,
                    value: CellFrames(layout: layout, frames: [item.url: geometry.frame(in: .named(Self.space))])
                )
            })
            .id(item.url)
            .onTapGesture(count: 2) { model.activate(item) }
            .simultaneousGesture(TapGesture().onEnded {
                model.click(item, modifiers: NSEvent.modifierFlags)
            })
            .contextMenu { ItemContextMenu(item: item) }

        if item.isDirectory {
            base.folderDropTarget(item.url, cornerRadius: 8)
        } else {
            base.onDrag {
                model.beginDrag(item)
                return NSItemProvider(item: item.url.path as NSString, typeIdentifier: UTType.imageViewerSelection.identifier)
            } preview: {
                // Built for every visible cell on every update, so it must stay cheap.
                DragPreview(item: item, count: model.selectedURLs.contains(item.url) ? max(1, model.selectedImages.count) : 1)
            }
        }
    }

    /// The item's folder relative to the open folder, when showing all subfolders.
    private func subfolder(of item: FileItem) -> String? {
        guard model.showsAllSubfolders, let root = model.folder?.path else { return nil }
        let parent = item.url.deletingLastPathComponent().path
        return parent == root ? "" : String(parent.dropFirst(root.count + 1))
    }

    private var marqueeGesture: some Gesture {
        DragGesture(minimumDistance: 4, coordinateSpace: .named(Self.space))
            .onChanged { value in
                if marqueeStart == nil {
                    let flags = NSEvent.modifierFlags
                    marqueeBase = flags.contains(.command) || flags.contains(.shift) ? model.selectedURLs : []
                    marqueeStart = value.startLocation
                    // Scroll when the pointer nears the top/bottom edge; the rectangle follows the content.
                    autoScroller.start { delta in
                        marqueeEnd.y += delta
                        updateMarqueeSelection()
                    }
                }
                marqueeEnd = value.location
                updateMarqueeSelection()
            }
            .onEnded { _ in
                autoScroller.stop()
                marqueeStart = nil
            }
    }

    private func updateMarqueeSelection() {
        guard let rect = marquee else { return }
        let hits = Set(cellFrames.filter { $0.value.intersects(rect) }.map(\.key))
        let focus = model.gridItems.first { hits.contains($0.url) }?.url
        model.setSelection(marqueeBase.union(hits), focus: focus ?? model.selection)
    }

    @ViewBuilder
    private var marqueeView: some View {
        if let marquee {
            Rectangle()
                .fill(Color.accentColor.opacity(0.15))
                .overlay(Rectangle().strokeBorder(Color.accentColor.opacity(0.8), lineWidth: 1))
                .frame(width: marquee.width, height: marquee.height)
                .offset(x: marquee.minX, y: marquee.minY)
                .allowsHitTesting(false)
        }
    }
}

/// Soft macOS-wallpaper-style gradient behind the thumbnail grid.
/// Three radial color blobs (indigo, teal, mauve) pool in the corners and fade toward the centre
/// where thumbnails sit. Re-rendered only on window resize; no per-frame cost.
private struct GridBackground: View {
    var body: some View {
        Canvas { ctx, size in
            let bounds = Path(CGRect(origin: .zero, size: size))
            let r = max(size.width, size.height)

            // Indigo/blue wash — upper-right, largest blob, sets the dominant hue.
            ctx.fill(bounds, with: .radialGradient(
                Gradient(colors: [
                    Color(red: 0.32, green: 0.40, blue: 0.90).opacity(0.18),
                    .clear
                ]),
                center: CGPoint(x: size.width * 0.85, y: size.height * 0.08),
                startRadius: 0,
                endRadius: r * 0.72
            ))

            // Teal/cyan — lower-right corner, slightly smaller.
            ctx.fill(bounds, with: .radialGradient(
                Gradient(colors: [
                    Color(red: 0.05, green: 0.62, blue: 0.72).opacity(0.14),
                    .clear
                ]),
                center: CGPoint(x: size.width * 0.96, y: size.height * 0.92),
                startRadius: 0,
                endRadius: r * 0.58
            ))

            // Violet/mauve — lower-left, the quietest accent.
            ctx.fill(bounds, with: .radialGradient(
                Gradient(colors: [
                    Color(red: 0.55, green: 0.25, blue: 0.75).opacity(0.09),
                    .clear
                ]),
                center: CGPoint(x: size.width * 0.04, y: size.height * 0.96),
                startRadius: 0,
                endRadius: r * 0.50
            ))

            // Warm rose — upper-left, very faint counter-balance.
            ctx.fill(bounds, with: .radialGradient(
                Gradient(colors: [
                    Color(red: 0.85, green: 0.38, blue: 0.52).opacity(0.06),
                    .clear
                ]),
                center: CGPoint(x: size.width * 0.02, y: size.height * 0.05),
                startRadius: 0,
                endRadius: r * 0.42
            ))
        }
        .allowsHitTesting(false)
    }
}

/// Scrolls the grid while a selection rectangle or dragged images get near (or past) its top or bottom edge.
@MainActor
final class AutoScroller {
    weak var scrollView: NSScrollView?
    private var timer: Timer?
    private var onScroll: ((CGFloat) -> Void)?

    /// `onScroll` receives how far the content moved, in SwiftUI (top-down) points.
    func start(onScroll: ((CGFloat) -> Void)? = nil) {
        self.onScroll = onScroll
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        // `.common`, not the default mode: while the mouse button is held, AppKit runs the
        // run loop in event-tracking mode and a default-mode timer would never fire.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        onScroll = nil
    }

    private func tick() {
        // Safety net: never keep scrolling once the button is released.
        guard NSEvent.pressedMouseButtons != 0 else {
            stop()
            return
        }
        guard let scrollView, let window = scrollView.window else { return }
        let frame = scrollView.convert(scrollView.bounds, to: nil) // window coordinates, y up
        let insets = scrollView.contentView.contentInsets // toolbar above, path bar below
        let mouse = window.mouseLocationOutsideOfEventStream
        let zone: CGFloat = 50
        let fromTop = (frame.maxY - insets.top) - mouse.y
        let fromBottom = mouse.y - (frame.minY + insets.bottom)
        // Speeds up the closer the pointer gets, and keeps accelerating past the edge.
        var speed: CGFloat = 0
        if fromTop < zone {
            speed = -min(3, (zone - fromTop) / zone)
        } else if fromBottom < zone {
            speed = min(3, (zone - fromBottom) / zone)
        }
        if speed != 0 { scroll(speed: speed) }
    }

    /// Scrolls by `speed` steps (negative = up) and reports the content movement.
    func scroll(speed: CGFloat) {
        guard let scrollView, let document = scrollView.documentView else { return }
        let clip = scrollView.contentView
        let direction: CGFloat = clip.isFlipped ? 1 : -1
        let before = clip.bounds.origin.y
        let insets = clip.contentInsets
        let minOffset = clip.isFlipped ? -insets.top : -insets.bottom
        let maxOffset = max(minOffset, document.frame.height - clip.bounds.height + (clip.isFlipped ? insets.bottom : insets.top))
        let target = min(max(before + speed * 14 * direction, minOffset), maxOffset)
        guard target != before else { return }
        clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: target))
        scrollView.reflectScrolledClipView(clip)
        onScroll?((target - before) * direction)
    }
}

/// Hands back the AppKit scroll view that hosts a SwiftUI ScrollView's content.
private struct ScrollViewFinder: NSViewRepresentable {
    let found: (NSScrollView) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = PassthroughView()
        DispatchQueue.main.async { if let scrollView = view.enclosingScrollView { found(scrollView) } }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        if let scrollView = view.enclosingScrollView { found(scrollView) }
    }

    private final class PassthroughView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}

private struct CellFrames: Equatable {
    var layout = 0
    var frames: [URL: CGRect] = [:]
}

private struct CellFramesKey: PreferenceKey {
    static let defaultValue = CellFrames()
    static func reduce(value: inout CellFrames, nextValue: () -> CellFrames) {
        let next = nextValue()
        value.layout = next.layout
        value.frames.merge(next.frames) { $1 }
    }
}

private extension Hasher {
    static func hash<each T: Hashable>(_ values: repeat each T) -> Int {
        var hasher = Hasher()
        repeat hasher.combine(each values)
        return hasher.finalize()
    }
}
