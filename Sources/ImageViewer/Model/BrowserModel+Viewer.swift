import AVFoundation
import AppKit
import Observation
import SwiftUI
import UniformTypeIdentifiers

/// The single-image viewer: loading, video, zoom, and text recognition.
extension BrowserModel {
    // MARK: Viewer

    func openImage(at index: Int) {
        guard images.indices.contains(index) else { return }
        let item = images[index]
        if isAdjusting, item.url != displayedURL {
            guard !hasUnsavedAdjustments else { return remindToSaveAdjustments() }
            endAdjusting()
        }
        viewerIndex = index
        selection = item.url
        guard item.url != displayedURL else { return }

        displayedURL = item.url
        imageError = nil
        imageTask?.cancel()
        videoPlayer?.pause()
        videoPlayer = nil
        if item.isVideo {
            currentImage = nil
            isLoadingImage = false
            zoomPercent = nil
            let player = AVPlayer(url: item.url)
            videoPlayer = player
            player.play()
            recognizeTextIfNeeded()
            return
        }
        recognizeTextIfNeeded()
        if let full = ImageLoader.shared.cachedImage(for: item.url) {
            currentImage = full
            isLoadingImage = false
        } else {
            currentImage = ImageLoader.shared.placeholder(for: item.url)
            isLoadingImage = true
        }

        imageTask = Task { [weak self] in
            let image = await ImageLoader.shared.load(item.url)
            guard let self, !Task.isCancelled, self.displayedURL == item.url else { return }
            self.isLoadingImage = false
            if let image {
                self.currentImage = image
            } else {
                self.currentImage = nil
                self.imageError = "“\(item.name)” couldn't be opened."
            }
            self.preloadNeighbors(of: item.url)
        }
    }

    func preloadNeighbors(of url: URL) {
        guard let index = images.firstIndex(where: { $0.url == url }) else { return }
        // Two ahead and one back, so quick runs of → stay smooth.
        for neighbor in [index + 1, index + 2, index - 1] where images.indices.contains(neighbor) && !images[neighbor].isVideo {
            let neighborURL = images[neighbor].url
            Task.detached(priority: .utility) { _ = await ImageLoader.shared.load(neighborURL) }
        }
    }

    func closeViewer() {
        endAdjusting()
        isTextRecognitionOn = false
        imageTask?.cancel()
        videoPlayer?.pause()
        videoPlayer = nil
        viewerIndex = nil
        displayedURL = nil
        currentImage = nil
        isLoadingImage = false
        imageError = nil
        zoomPercent = nil
    }

    /// ⌘T: toggles text recognition, opening the selected image first when in the grid.
    func toggleTextRecognition() {
        if !isViewing {
            openSelection()
            guard isViewing else { return }
            isTextRecognitionOn = true
            return
        }
        isTextRecognitionOn.toggle()
    }

    func recognizeTextIfNeeded() {
        guard isTextRecognitionOn, let url = displayedURL, currentItem?.isVideo == false else {
            textTask?.cancel()
            recognizedLines = []
            recognizedURL = nil
            isRecognizingText = false
            return
        }
        guard recognizedURL != url else { return }
        selectedLineIDs = []
        textTask?.cancel()
        if let cached = textCache[url] {
            recognizedLines = cached
            recognizedURL = url
            isRecognizingText = false
            return
        }
        recognizedLines = []
        recognizedURL = nil
        isRecognizingText = true
        textTask = Task { [weak self] in
            // Always the full-resolution, upright image (never the blurry placeholder).
            let image = await ImageLoader.shared.load(url)
            guard let cgImage = image?.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
                self?.isRecognizingText = false
                return
            }
            let lines = await Task.detached(priority: .userInitiated) { TextRecognizer.recognize(cgImage) }.value
            guard let self, !Task.isCancelled, self.displayedURL == url, self.isTextRecognitionOn else { return }
            self.textCache[url] = lines
            self.recognizedLines = lines
            self.recognizedURL = url
            self.isRecognizingText = false
        }
    }

    /// Copies the selected lines (or all of them) in reading order.
    func copyRecognizedText(all: Bool = false) {
        let lines = all || selectedLineIDs.isEmpty
            ? recognizedLines
            : recognizedLines.filter { selectedLineIDs.contains($0.id) }
        guard !lines.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lines.map(\.text).joined(separator: "\n"), forType: .string)
        showToast("Copied \(lines.count) line\(lines.count == 1 ? "" : "s") of text", canUndo: false)
    }

    func selectAllRecognizedText() {
        selectedLineIDs = Set(recognizedLines.map(\.id))
    }

    func togglePlayback() {
        guard let player = videoPlayer else { return }
        if player.timeControlStatus == .paused {
            // Restart from the beginning if the video already ended.
            if let item = player.currentItem, item.currentTime() >= item.duration { player.seek(to: .zero) }
            player.play()
        } else {
            player.pause()
        }
    }

    func toggleViewer() {
        if isViewing {
            closeViewer()
        } else {
            openSelection()
        }
    }

    /// Next/previous image in the viewer, or next/previous item in the grid.
    func step(_ delta: Int) {
        endTextEditing()
        guard let index = viewerIndex else {
            moveSelection(by: delta)
            return
        }
        let target = index + delta
        if images.indices.contains(target) {
            openImage(at: target)
        } else {
            NSSound.beep()
        }
    }

    func showFirst() {
        if isViewing { openImage(at: 0) } else { selection = gridItems.first?.url }
    }

    func showLast() {
        if isViewing { openImage(at: images.count - 1) } else { selection = gridItems.last?.url }
    }

    func zoom(_ action: ZoomAction) {
        if isViewing {
            zoomRequest = ZoomRequest(action: action)
            return
        }
        switch action {
        case .zoomIn: thumbnailSize = min(400, thumbnailSize + 40)
        case .zoomOut: thumbnailSize = max(80, thumbnailSize - 40)
        case .fit, .actualSize: thumbnailSize = 160
        }
    }

    /// Full screen with the sidebar tucked away — the "as big as possible" mode.
    func toggleFullScreen() {
        guard let window = NSApp.mainWindow ?? NSApp.keyWindow else { return }
        let entering = !window.styleMask.contains(.fullScreen)
        columnVisibility = entering ? .detailOnly : .all
        window.toggleFullScreen(nil)
    }
}
