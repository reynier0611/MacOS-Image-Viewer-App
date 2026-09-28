import AppKit
import SwiftUI

/// An AppKit scroll view that fits the image to the window, supports pinch/⌘+/⌘- zoom,
/// click-drag panning, and double-click to toggle between fit and 100%.
struct ZoomableImageView: NSViewRepresentable {
    let image: NSImage?
    let imageURL: URL?
    let zoomRequest: ZoomRequest?
    let enlargeSmallImages: Bool
    var textLines: [RecognizedLine] = []
    var selectedLines: Set<Int> = []
    var showsExtractedText = true
    var onTextSelectionChange: (Set<Int>) -> Void = { _ in }
    var onCopyText: () -> Void = {}
    let onZoomChange: (Int) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        let clipView = CenteringClipView()
        clipView.drawsBackground = false
        scrollView.contentView = clipView
        scrollView.drawsBackground = false
        scrollView.hasHorizontalScroller = true
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.allowsMagnification = true
        scrollView.minMagnification = 0.01
        scrollView.maxMagnification = 50

        let imageView = ImageCanvasView()
        imageView.imageScaling = .scaleAxesIndependently
        imageView.animates = true
        imageView.isEditable = false
        imageView.coordinator = context.coordinator
        scrollView.documentView = imageView

        let textOverlay = TextOverlayView(frame: imageView.bounds)
        textOverlay.autoresizingMask = [.width, .height]
        imageView.addSubview(textOverlay)
        context.coordinator.textOverlay = textOverlay

        let coordinator = context.coordinator
        coordinator.scrollView = scrollView
        coordinator.imageView = imageView
        coordinator.onZoomChange = onZoomChange
        coordinator.enlargeSmallImages = enlargeSmallImages
        coordinator.lastZoomID = zoomRequest?.id
        coordinator.observe()
        coordinator.setImage(image, url: imageURL)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        coordinator.onZoomChange = onZoomChange
        if coordinator.enlargeSmallImages != enlargeSmallImages {
            coordinator.enlargeSmallImages = enlargeSmallImages
            if coordinator.fitMode { coordinator.fit() }
        }
        if coordinator.imageView?.image !== image || coordinator.url != imageURL {
            coordinator.setImage(image, url: imageURL)
        }
        if let request = zoomRequest, request.id != coordinator.lastZoomID {
            coordinator.lastZoomID = request.id
            coordinator.perform(request.action)
        }
        if let overlay = coordinator.textOverlay {
            overlay.onSelectionChange = onTextSelectionChange
            overlay.onCopy = onCopyText
            if overlay.lines != textLines { overlay.lines = textLines }
            if overlay.selected != selectedLines { overlay.selected = selectedLines }
            if overlay.showsExtractedText != showsExtractedText { overlay.showsExtractedText = showsExtractedText }
        }
    }

    @MainActor
    final class Coordinator: NSObject {
        weak var scrollView: NSScrollView?
        weak var imageView: NSImageView?
        weak var textOverlay: TextOverlayView?
        var url: URL?
        var fitMode = true
        var enlargeSmallImages = true
        var lastZoomID: UUID?
        var onZoomChange: ((Int) -> Void)?

        private var backingScale: CGFloat { scrollView?.window?.backingScaleFactor ?? 2 }

        func observe() {
            guard let scrollView else { return }
            NotificationCenter.default.addObserver(
                self, selector: #selector(didEndLiveMagnify),
                name: NSScrollView.didEndLiveMagnifyNotification, object: scrollView
            )
            scrollView.postsFrameChangedNotifications = true
            NotificationCenter.default.addObserver(
                self, selector: #selector(frameDidChange),
                name: NSView.frameDidChangeNotification, object: scrollView
            )
        }

        @objc private func didEndLiveMagnify(_ notification: Notification) {
            fitMode = false
            reportZoom()
            textOverlay?.needsDisplay = true
        }

        @objc private func frameDidChange(_ notification: Notification) {
            if fitMode { fit() }
        }

        func setImage(_ image: NSImage?, url: URL?) {
            guard let imageView else { return }
            // Placeholder → full-resolution swap of the same file keeps the current zoom.
            let sameDocument = url == self.url && image?.size == imageView.image?.size
            imageView.image = image
            self.url = url
            guard let image else {
                imageView.frame = .zero
                return
            }
            if !sameDocument {
                imageView.frame = NSRect(origin: .zero, size: image.size)
                fitMode = true
                fit()
            }
        }

        func perform(_ action: ZoomAction) {
            guard let scrollView else { return }
            switch action {
            case .fit:
                fitMode = true
                fit()
            case .actualSize:
                setMagnification(1 / backingScale, centeredAt: visibleCenter)
            case .zoomIn:
                setMagnification(scrollView.magnification * 1.25, centeredAt: visibleCenter)
            case .zoomOut:
                setMagnification(scrollView.magnification / 1.25, centeredAt: visibleCenter)
            }
        }

        func toggleZoom(at point: NSPoint) {
            if fitMode {
                setMagnification(1 / backingScale, centeredAt: point)
            } else {
                perform(.fit)
            }
        }

        func fit() {
            guard let scrollView, let size = imageView?.image?.size, size.width > 0, size.height > 0 else { return }
            let available = scrollView.contentSize
            guard available.width > 0, available.height > 0 else { return }
            var magnification = min(available.width / size.width, available.height / size.height)
            if !enlargeSmallImages {
                magnification = min(magnification, 1)
            }
            scrollView.magnification = clamp(magnification)
            scrollView.contentView.scroll(to: NSPoint(
                x: (size.width - scrollView.contentView.bounds.width) / 2,
                y: (size.height - scrollView.contentView.bounds.height) / 2
            ))
            scrollView.reflectScrolledClipView(scrollView.contentView)
            reportZoom()
        }

        private var visibleCenter: NSPoint {
            let rect = scrollView?.documentVisibleRect ?? .zero
            return NSPoint(x: rect.midX, y: rect.midY)
        }

        private func setMagnification(_ value: CGFloat, centeredAt point: NSPoint) {
            guard let scrollView else { return }
            fitMode = false
            scrollView.setMagnification(clamp(value), centeredAt: point)
            reportZoom()
        }

        private func clamp(_ value: CGFloat) -> CGFloat {
            guard let scrollView else { return value }
            return min(max(value, scrollView.minMagnification), scrollView.maxMagnification)
        }

        private func reportZoom() {
            guard let scrollView else { return }
            textOverlay?.needsDisplay = true // keep outline widths constant on screen
            let percent = Int((scrollView.magnification * backingScale * 100).rounded())
            // Deferred so we never mutate SwiftUI state mid-update.
            DispatchQueue.main.async { [onZoomChange] in onZoomChange?(percent) }
        }
    }
}

/// Highlights recognized text lines on top of the image, in image coordinates, so the
/// highlights follow zoom and pan. Click / ⌘-click / ⇧-click / drag to select lines,
/// ⌘C to copy, ⌘A to select all, double-click to copy one line.
final class TextOverlayView: NSView, NSMenuItemValidation {
    var lines: [RecognizedLine] = [] {
        didSet {
            anchor = nil
            needsDisplay = true
            window?.invalidateCursorRects(for: self)
        }
    }
    var selected: Set<Int> = [] {
        didSet { needsDisplay = true }
    }
    /// When true, each line's box is filled and the recognized text is printed over it in red.
    /// When false, only outlines are drawn so the original photo shows through.
    var showsExtractedText = true {
        didSet { needsDisplay = true }
    }
    var onSelectionChange: (Set<Int>) -> Void = { _ in }
    var onCopy: () -> Void = {}

    private var anchor: Int?
    private var dragStart: NSPoint?
    private var dragBase: Set<Int> = []
    private var band: NSRect?

    override var acceptsFirstResponder: Bool { !lines.isEmpty }

    private var magnification: CGFloat { enclosingScrollView?.magnification ?? 1 }

    private func outline(_ line: RecognizedLine) -> NSBezierPath {
        let path = NSBezierPath()
        let points = line.corners.map { NSPoint(x: $0.x * bounds.width, y: $0.y * bounds.height) }
        path.move(to: points[0])
        points.dropFirst().forEach { path.line(to: $0) }
        path.close()
        return path
    }

    private func rect(_ line: RecognizedLine) -> NSRect {
        let b = line.bounds
        return NSRect(x: b.minX * bounds.width, y: b.minY * bounds.height, width: b.width * bounds.width, height: b.height * bounds.height)
    }

    private func line(at point: NSPoint) -> RecognizedLine? {
        // A little slack around each line makes small text easy to hit.
        let slack = 4 / magnification
        return lines.first { rect($0).insetBy(dx: -slack, dy: -slack).contains(point) }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard !lines.isEmpty else { return }
        // Soften the photo so the highlighted text stands out.
        NSColor.black.withAlphaComponent(0.18).setFill()
        bounds.fill()
        let width = 1.5 / magnification
        for line in lines {
            let isSelected = selected.contains(line.id)
            let path = outline(line)
            path.lineWidth = isSelected ? width * 2 : width
            path.lineJoinStyle = .round
            if showsExtractedText {
                // Opaque, so the red text isn't muddled by the photo's own lettering underneath.
                (isSelected
                    ? NSColor.controlAccentColor.blended(withFraction: 0.7, of: .white) ?? .white
                    : NSColor(calibratedRed: 1, green: 0.98, blue: 0.86, alpha: 1)
                ).setFill()
            } else {
                (isSelected ? NSColor.controlAccentColor.withAlphaComponent(0.35) : NSColor.systemYellow.withAlphaComponent(0.18)).setFill()
            }
            (isSelected ? NSColor.controlAccentColor : NSColor.systemYellow.withAlphaComponent(0.95)).setStroke()
            path.fill()
            path.stroke()
            if showsExtractedText {
                drawText(of: line)
            }
        }
        if let band {
            let path = NSBezierPath(rect: band)
            path.lineWidth = width
            path.setLineDash([4 / magnification, 3 / magnification], count: 2, phase: 0)
            NSColor.controlAccentColor.withAlphaComponent(0.12).setFill()
            NSColor.controlAccentColor.setStroke()
            path.fill()
            path.stroke()
        }
    }

    /// Prints the recognized text inside its box: sized to the box height, shrunk to fit the
    /// width, and rotated to follow the line's baseline so slanted text lines up.
    private func drawText(of line: RecognizedLine) {
        let size = bounds.size
        let corners = line.corners.map { NSPoint(x: $0.x * size.width, y: $0.y * size.height) }
        let (topLeft, topRight, bottomLeft) = (corners[0], corners[1], corners[3])
        let boxWidth = hypot(topRight.x - topLeft.x, topRight.y - topLeft.y)
        let boxHeight = hypot(topLeft.x - bottomLeft.x, topLeft.y - bottomLeft.y)
        guard boxWidth > 1, boxHeight > 1 else { return }

        var fontSize = boxHeight * 0.9
        func attributed(_ size: CGFloat) -> NSAttributedString {
            NSAttributedString(string: line.text, attributes: [
                .font: NSFont.systemFont(ofSize: size, weight: .semibold),
                .foregroundColor: NSColor.systemRed,
            ])
        }
        var text = attributed(fontSize)
        let measured = text.size()
        if measured.width > boxWidth * 0.96 {
            fontSize *= boxWidth * 0.96 / measured.width
            text = attributed(fontSize)
        }

        NSGraphicsContext.saveGraphicsState()
        let transform = NSAffineTransform()
        transform.translateX(by: bottomLeft.x, yBy: bottomLeft.y)
        transform.rotate(byRadians: atan2(topRight.y - topLeft.y, topRight.x - topLeft.x))
        transform.concat()
        let textSize = text.size()
        text.draw(at: NSPoint(x: (boxWidth - textSize.width) / 2, y: (boxHeight - textSize.height) / 2))
        NSGraphicsContext.restoreGraphicsState()
    }

    /// Only text is clickable; everywhere else, clicks fall through to the image (panning, double-click zoom).
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !lines.isEmpty, let superview else { return nil }
        return line(at: convert(point, from: superview)) != nil ? self : nil
    }

    override func resetCursorRects() {
        for line in lines {
            addCursorRect(rect(line), cursor: .pointingHand)
        }
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let point = convert(event.locationInWindow, from: nil)
        guard let hit = line(at: point) else { return }
        if event.clickCount == 2 {
            update([hit.id])
            onCopy()
            return
        }
        let modifiers = event.modifierFlags
        if modifiers.contains(.shift), let anchor,
           let from = lines.firstIndex(where: { $0.id == anchor }),
           let to = lines.firstIndex(where: { $0.id == hit.id }) {
            update(selected.union(lines[min(from, to)...max(from, to)].map(\.id)))
        } else if modifiers.contains(.command) {
            update(selected.symmetricDifference([hit.id]))
            anchor = hit.id
        } else {
            update([hit.id])
            anchor = hit.id
        }
        dragStart = point
        dragBase = selected
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = dragStart else { return }
        let point = convert(event.locationInWindow, from: nil)
        let rect = NSRect(x: min(start.x, point.x), y: min(start.y, point.y), width: abs(point.x - start.x), height: abs(point.y - start.y))
        band = rect
        update(dragBase.union(lines.filter { self.rect($0).intersects(rect) }.map(\.id)))
    }

    override func mouseUp(with event: NSEvent) {
        dragStart = nil
        band = nil
        needsDisplay = true
    }

    private func update(_ selection: Set<Int>) {
        selected = selection
        onSelectionChange(selection)
    }

    // Edit ▸ Copy (⌘C) and Edit ▸ Select All (⌘A) reach this view while it has focus.
    @objc func copy(_ sender: Any?) {
        onCopy()
    }

    override func selectAll(_ sender: Any?) {
        update(Set(lines.map(\.id)))
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(copy(_:)), #selector(selectAll(_:)): !lines.isEmpty
        default: true
        }
    }
}

/// Keeps the image centered when it is smaller than the viewport.
final class CenteringClipView: NSClipView {
    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var rect = super.constrainBoundsRect(proposedBounds)
        guard let documentView else { return rect }
        let frame = documentView.frame
        if rect.width > frame.width {
            rect.origin.x = (frame.width - rect.width) / 2
        }
        if rect.height > frame.height {
            rect.origin.y = (frame.height - rect.height) / 2
        }
        return rect
    }
}

/// Image view that pans on drag and toggles zoom on double-click.
final class ImageCanvasView: NSImageView {
    weak var coordinator: ZoomableImageView.Coordinator?
    private var lastDragPoint: NSPoint?

    override var acceptsFirstResponder: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            coordinator?.toggleZoom(at: convert(event.locationInWindow, from: nil))
            return
        }
        lastDragPoint = event.locationInWindow
    }

    override func mouseDragged(with event: NSEvent) {
        guard let last = lastDragPoint, let scrollView = enclosingScrollView else { return }
        let point = event.locationInWindow
        lastDragPoint = point
        let magnification = scrollView.magnification
        var origin = scrollView.contentView.bounds.origin
        origin.x -= (point.x - last.x) / magnification
        origin.y -= (point.y - last.y) / magnification
        scrollView.contentView.scroll(to: origin)
        scrollView.reflectScrolledClipView(scrollView.contentView)
        NSCursor.closedHand.set()
    }

    override func mouseUp(with event: NSEvent) {
        lastDragPoint = nil
        NSCursor.arrow.set()
    }
}
