import Foundation

/// Editing the capture date/time stored in a photo's EXIF metadata.
extension BrowserModel {
    /// Sets a new capture date on `item`, writes it to disk, and registers Undo.
    func setCaptureDate(_ date: Date, for item: FileItem) {
        guard ImageDateEditor.canEdit(item.url) else { return }
        let url = item.url
        let previous = mediaInfo[url]?.captureDate

        // Immediate UI update so the inspector reflects the change without waiting for disk.
        mediaInfo[url, default: MediaInfo()].captureDate = date
        metadataRevision += 1

        let undoManager = undoManager
        undoManager?.registerUndo(withTarget: self) { model in
            if let previous {
                model.setCaptureDate(previous, for: item)
            } else {
                // No original date: clear back to nil (file is left with the new date but UI shows nil).
                model.mediaInfo[url]?.captureDate = nil
                model.metadataRevision += 1
            }
        }
        undoManager?.setActionName("Change Date Taken")

        enqueueMetadataWrite([url], what: "date") { url in
            try ImageDateEditor.write(date, to: url)
        } onFailure: { model, _ in
            // Roll back the optimistic UI update on failure.
            model.mediaInfo[url]?.captureDate = previous
            model.metadataRevision += 1
        }
    }
}
