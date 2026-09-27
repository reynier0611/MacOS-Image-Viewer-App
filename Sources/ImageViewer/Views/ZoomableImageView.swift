import AppKit
import SwiftUI

/// An AppKit scroll view that fits the image to the window, supports pinch/⌘+/⌘- zoom,
/// click-drag panning, and double-click to toggle between fit and 100%.
struct ZoomableImageView: NSViewRepresentable {
    let image: NSImage?
    let imageURL: URL?
    let zoomRequest: ZoomRequest?
    let enlargeSmallImages: Bool
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
    }

    @MainActor
    final class Coordinator: NSObject {
        weak var scrollView: NSScrollView?
        weak var imageView: NSImageView?
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
            let percent = Int((scrollView.magnification * backingScale * 100).rounded())
            // Deferred so we never mutate SwiftUI state mid-update.
            DispatchQueue.main.async { [onZoomChange] in onZoomChange?(percent) }
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
