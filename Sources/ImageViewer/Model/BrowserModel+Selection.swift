import AVFoundation
import AppKit
import Observation
import SwiftUI
import UniformTypeIdentifiers

/// Grid selection: arrow keys, clicks with modifiers, the selection rectangle.
extension BrowserModel {
    // MARK: Grid selection

    func moveSelection(by delta: Int) {
        let items = gridItems
        guard !items.isEmpty else { return }
        guard let current = selection, let index = gridIndex[current] else {
            selection = items.first?.url
            return
        }
        let target = index + delta
        guard items.indices.contains(target) else {
            // Up/down past the edge: stop at first/last, like Finder.
            selection = items[max(0, min(items.count - 1, target))].url
            return
        }
        selection = items[target].url
    }

    /// Gives the keyboard back to browsing after typing in the search field (or any text field).
    /// Without this, a focused search field keeps receiving the arrow keys even after you click
    /// thumbnails or open an image, so ← → stop navigating. The search text is kept.
    func endTextEditing(in window: NSWindow? = nil) {
        let window = window ?? NSApp.keyWindow ?? NSApp.mainWindow
            ?? NSApp.windows.first { $0.isVisible && !($0 is NSPanel) }
        guard let window, !(window is NSPanel), window.attachedSheet == nil,
              window.firstResponder is NSText
        else { return }
        window.makeFirstResponder(nil)
    }

    /// Plain click selects one, ⌘ toggles, ⇧ adds the range from the focused item.
    func click(_ item: FileItem, modifiers: NSEvent.ModifierFlags) {
        endTextEditing()
        let items = gridItems
        if modifiers.contains(.shift),
           let anchor = selection,
           let from = gridIndex[anchor],
           let to = gridIndex[item.url] {
            // Additive, so ⌘-picked images elsewhere aren't lost when you ⇧-click a range.
            selectedURLs.formUnion(items[min(from, to)...max(from, to)].map(\.url))
        } else if modifiers.contains(.command) {
            isAdjustingSelection = true
            defer { isAdjustingSelection = false }
            if selectedURLs.contains(item.url) {
                selectedURLs.remove(item.url)
            } else {
                selectedURLs.insert(item.url)
            }
            selection = item.url
        } else {
            selection = item.url
        }
    }

    /// Used by the drag-selection rectangle.
    func setSelection(_ urls: Set<URL>, focus: URL?) {
        endTextEditing()
        isAdjustingSelection = true
        defer { isAdjustingSelection = false }
        selection = focus ?? urls.first
        selectedURLs = urls
    }

    func clearSelection() {
        endTextEditing()
        selection = nil
    }

    func selectAll() {
        guard !isViewing else { return }
        selectedURLs = Set(gridItems.map(\.url))
    }

    func activate(_ item: FileItem) {
        endTextEditing()
        if item.isDirectory {
            navigate(to: item.url)
        } else if let index = images.firstIndex(where: { $0.url == item.url }) {
            openImage(at: index)
        }
    }

    func openSelection() {
        if let item = selectedItem { activate(item) }
    }
}
