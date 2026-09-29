import AppKit
import SwiftUI

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
