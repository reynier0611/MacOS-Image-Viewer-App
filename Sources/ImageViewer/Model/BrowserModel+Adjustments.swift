import AppKit
import CoreImage
import Foundation

/// Adjust Color (⇧⌘A): live preview while dragging the sliders, then save as a copy or over the original.
extension BrowserModel {
    var hasUnsavedAdjustments: Bool { isAdjusting && !adjustments.isUnchanged }

    func toggleAdjusting() {
        if isAdjusting {
            if hasUnsavedAdjustments { remindToSaveAdjustments() } else { endAdjusting() }
        } else {
            beginAdjusting()
        }
    }

    func beginAdjusting() {
        if !isViewing { openSelection() }
        guard isViewing, let item = currentItem, ImageAdjuster.canAdjust(item) else { return }
        isTextRecognitionOn = false
        adjustmentBase = nil
        adjustmentAutoFilters = nil
        adjustments = Adjustments()
        adjustmentPreview = nil
        isAdjusting = true
        let url = item.url
        Task {
            let base = await Task.detached(priority: .userInitiated) { ImageAdjuster.previewImage(url) }.value
            guard isAdjusting, displayedURL == url else { return }
            adjustmentBase = base
            renderAdjustmentPreview()
        }
    }

    /// Leaves the panel, discarding anything not saved.
    func endAdjusting() {
        isAdjusting = false
        adjustments = Adjustments()
        adjustmentPreview = nil
        adjustmentBase = nil
        adjustmentAutoFilters = nil
        isShowingOriginal = false
    }

    func remindToSaveAdjustments() {
        NSSound.beep()
        showToast("Save or cancel the adjustments first", canUndo: false)
    }

    /// Re-renders the screen-sized preview. While one render runs, later slider moves just mark it
    /// stale, so dragging never queues up a backlog.
    func renderAdjustmentPreview() {
        guard isAdjusting, adjustmentBase != nil else { return }
        guard !isRenderingAdjustment else {
            adjustmentRenderPending = true
            return
        }
        isRenderingAdjustment = true
        Task {
            defer { isRenderingAdjustment = false }
            repeat {
                adjustmentRenderPending = false
                guard isAdjusting, let base = adjustmentBase, let size = currentImage?.size else { return }
                let wanted = adjustments
                if wanted.isUnchanged {
                    adjustmentPreview = nil
                    continue
                }
                if wanted.auto && adjustmentAutoFilters == nil {
                    let filters = await Task.detached(priority: .userInitiated) { ImageAdjuster.autoFilters(for: base) }.value
                    adjustmentAutoFilters = filters
                }
                let filters = adjustmentAutoFilters ?? []
                let rendered = await Task.detached(priority: .userInitiated) {
                    ImageAdjuster.render(ImageAdjuster.apply(wanted, to: base, autoFilters: filters))
                }.value
                guard isAdjusting else { return }
                if let rendered {
                    adjustmentPreview = NSImage(cgImage: rendered, size: size) // same size: keeps the zoom
                }
            } while adjustmentRenderPending
        }
    }

    // MARK: Saving

    func saveAdjustments() {
        guard hasUnsavedAdjustments, let item = currentItem, !isSavingAdjustments else { return }
        let canOverwrite = ImageAdjuster.canOverwrite(item.url)
        let copyName = ImageAdjuster.copyURL(for: item.url).lastPathComponent

        let alert = NSAlert()
        alert.messageText = "Save the adjusted photo?"
        alert.informativeText = canOverwrite
            ? "Save as Copy keeps the original and adds “\(copyName)” next to it.\n\nOverwrite Original replaces “\(item.name)” with the adjusted version. You can undo it (⌘Z) for a week."
            : "“\(item.name)” can't be rewritten in its own format, so the adjusted version will be saved as a JPEG copy, “\(copyName)”."
        alert.addButton(withTitle: "Save as Copy") // the default: Return
        if canOverwrite {
            alert.addButton(withTitle: "Overwrite Original")
        }
        alert.addButton(withTitle: "Cancel").keyEquivalent = "\u{1b}"
        let response = alert.runModal()
        switch response {
        case .alertFirstButtonReturn: saveAdjustedCopy(of: item)
        case .alertSecondButtonReturn where canOverwrite: overwriteWithAdjustments(item)
        default: break
        }
    }

    private func saveAdjustedCopy(of item: FileItem) {
        let wanted = adjustments
        let output = ImageAdjuster.copyURL(for: item.url)
        isSavingAdjustments = true
        Task {
            defer { isSavingAdjustments = false }
            do {
                try await Task.detached(priority: .userInitiated) {
                    try ImageAdjuster.save(wanted, from: item.url, to: output)
                }.value
            } catch {
                errorMessage = error.localizedDescription
                return
            }
            endAdjusting()
            load(select: selection, viewing: displayedURL, fallbackIndex: viewerIndex)
            undoManager?.registerUndo(withTarget: self) { model in
                MainActor.assumeIsolated { model.removeAdjustedCopy(output) }
            }
            undoManager?.setActionName("Save Adjusted Copy")
            showToast("Saved “\(output.lastPathComponent)”", canUndo: true)
        }
    }

    private func removeAdjustedCopy(_ url: URL) {
        try? FileManager.default.trashItem(at: url, resultingItemURL: nil)
        load(select: selection, viewing: displayedURL, fallbackIndex: viewerIndex)
    }

    private func overwriteWithAdjustments(_ item: FileItem) {
        let wanted = adjustments
        let url = item.url
        isSavingAdjustments = true
        Task {
            defer { isSavingAdjustments = false }
            let backup: URL
            do {
                backup = try await Task.detached(priority: .userInitiated) {
                    let backup = try ImageAdjuster.backUp(url)
                    try ImageAdjuster.save(wanted, from: url, to: url)
                    return backup
                }.value
            } catch {
                errorMessage = error.localizedDescription
                return
            }
            endAdjusting()
            fileContentsChanged(url)
            registerFileRestore(url, from: backup, actionName: "Adjust Color")
            showToast("Saved adjustments to “\(item.name)”", canUndo: true)
        }
    }

    /// Undo puts the earlier version back; the version it replaces is kept so Redo can return to it.
    private func registerFileRestore(_ url: URL, from backup: URL, actionName: String) {
        undoManager?.registerUndo(withTarget: self) { model in
            MainActor.assumeIsolated {
                do {
                    let current = try ImageAdjuster.backUp(url)
                    try ImageAdjuster.restore(backup, to: url)
                    model.fileContentsChanged(url)
                    model.registerFileRestore(url, from: current, actionName: actionName)
                } catch {
                    model.errorMessage = "“\(url.lastPathComponent)” couldn't be restored: \(error.localizedDescription)"
                }
            }
        }
        undoManager?.setActionName(actionName)
    }

    /// Drops everything cached about a file whose pixels changed, and shows the new version.
    func fileContentsChanged(_ url: URL) {
        ImageLoader.shared.invalidate(url)
        ThumbnailLoader.shared.invalidate(url)
        textCache[url] = nil
        if recognizedURL == url { recognizedURL = nil }
        let viewing = displayedURL == url
        if viewing { displayedURL = nil } // force the viewer to decode it again
        load(select: selection, viewing: viewing ? url : displayedURL, fallbackIndex: viewerIndex)
    }
}
