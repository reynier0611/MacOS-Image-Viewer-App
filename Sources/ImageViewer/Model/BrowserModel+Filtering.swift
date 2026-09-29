import AVFoundation
import AppKit
import Observation
import SwiftUI
import UniformTypeIdentifiers

/// Search, type/date filters, and the background indexing that feeds them.
extension BrowserModel {
    // MARK: Filtering

    /// When the photo was taken (EXIF / video metadata), falling back to the file's oldest date.
    func captureDate(for item: FileItem) -> Date {
        mediaInfo[item.url]?.captureDate ?? min(item.created, item.modified)
    }

    func clearFilters() {
        searchText = ""
        typeFilter = .all
        dateFilter = .any
    }

    var currentFilter: MediaFilter {
        MediaFilter(
            type: typeFilter,
            dates: dateFilter == .any ? nil : dateFilter.range(from: customDateFrom, to: customDateTo),
            searchText: searchText
        )
    }

    /// Recomputes `folders`/`images` from the full lists, keeping the viewer and selection consistent.
    func refilter() {
        let filter = currentFilter
        images = allImages.filter {
            filter.matches($0, captureDate: captureDate(for: $0), labels: contentLabels[$0.url] ?? [])
        }
        folders = allFolders.filter(filter.matchesFolder)

        if isViewing, let url = displayedURL {
            if let index = images.firstIndex(where: { $0.url == url }) {
                viewerIndex = index
            } else {
                closeViewer()
            }
        }
        let visible = Set(gridItems.map(\.url))
        if let current = selection, !visible.contains(current) {
            selection = images.first?.url ?? folders.first?.url
        } else {
            selectedURLs.formIntersection(visible)
        }
    }

    // MARK: Background indexing

    /// Reads date taken and location for every file (cheap header reads, off the main thread).
    func startIndexing() {
        let pending = allImages.filter { mediaInfo[$0.url] == nil }
        guard !pending.isEmpty, let folder else { return }
        indexTask?.cancel()
        indexTask = Task.detached(priority: .utility) { [weak self] in
            var batch: [URL: MediaInfo] = [:]
            for (index, item) in pending.enumerated() {
                if Task.isCancelled { return }
                batch[item.url] = await MediaIndex.read(item)
                if batch.count >= 100 || index == pending.count - 1 {
                    let ready = batch
                    batch = [:]
                    await self?.mergeMediaInfo(ready, folder: folder)
                }
            }
        }
    }

    func mergeMediaInfo(_ info: [URL: MediaInfo], folder: URL) {
        guard self.folder == folder else { return }
        mediaInfo.merge(info) { $1 }
        if sortKey == .taken {
            applySort()
        } else if dateFilter != .any {
            refilter()
        }
    }

    func startContentAnalysisIfNeeded() {
        guard analysisTask == nil, let folder else { return }
        let pending = allImages.filter { !$0.isVideo && contentLabels[$0.url] == nil }
        guard !pending.isEmpty else { return }
        contentAnalysisTotal = pending.count
        contentAnalysisDone = 0
        analysisTask = Task.detached(priority: .utility) { [weak self] in
            var batch: [URL: [String]] = [:]
            for (index, item) in pending.enumerated() {
                if Task.isCancelled { break }
                batch[item.url] = await ContentAnalyzer.shared.labels(for: item)
                if batch.count >= 12 || index == pending.count - 1 {
                    let ready = batch
                    batch = [:]
                    await self?.mergeLabels(ready, done: index + 1, folder: folder)
                }
            }
            await ContentAnalyzer.shared.save()
        }
    }

    func mergeLabels(_ labels: [URL: [String]], done: Int, folder: URL) {
        guard self.folder == folder else { return }
        contentLabels.merge(labels) { $1 }
        contentAnalysisDone = done
        if done >= contentAnalysisTotal {
            analysisTask = nil // later searches pick up files added since
        }
        if !currentFilter.tokens.isEmpty { refilter() }
    }
}
