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

    /// What search looks in besides the name: things recognized in the photo, its tags and its note.
    func searchableWords(for item: FileItem) -> [String] {
        var words = contentLabels[item.url] ?? []
        if let annotations = mediaInfo[item.url]?.annotations {
            words += annotations.tags.map { $0.lowercased() }
            if !annotations.note.isEmpty { words.append(annotations.note.lowercased()) }
        }
        return words
    }

    func clearFilters() {
        searchText = ""
        typeFilter = .all
        dateFilter = .any
        ratingFilter = .any
    }

    var currentFilter: MediaFilter {
        MediaFilter(
            type: typeFilter,
            rating: ratingFilter,
            dates: dateFilter == .any ? nil : dateFilter.range(from: customDateFrom, to: customDateTo),
            searchText: searchText
        )
    }

    /// Recomputes `folders`/`images` from the full lists, keeping the viewer and selection consistent.
    func refilter() {
        let filter = currentFilter
        images = allImages.filter {
            filter.matches($0, captureDate: captureDate(for: $0), labels: searchableWords(for: $0), rating: rating(for: $0))
        }
        folders = showsAllSubfolders ? [] : allFolders.filter(filter.matchesFolder)

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
        // Several workers read headers in parallel (it's mostly waiting on the disk); results
        // are merged in batches so the map, date filters and sorting fill in as they arrive.
        let workers = max(2, min(8, ProcessInfo.processInfo.activeProcessorCount / 2))
        let chunkSize = (pending.count + workers - 1) / workers
        let chunks = stride(from: 0, to: pending.count, by: chunkSize).map { Array(pending[$0..<min($0 + chunkSize, pending.count)]) }
        indexTask = Task.detached(priority: .utility) { [weak self] in
            await withTaskGroup(of: Void.self) { group in
                for chunk in chunks {
                    group.addTask {
                        var batch: [URL: MediaInfo] = [:]
                        for (index, item) in chunk.enumerated() {
                            if Task.isCancelled { return }
                            batch[item.url] = await MediaIndex.read(item)
                            if batch.count >= 150 || index == chunk.count - 1 {
                                let ready = batch
                                batch = [:]
                                await self?.mergeMediaInfo(ready, folder: folder)
                            }
                        }
                    }
                }
            }
        }
    }

    func mergeMediaInfo(_ info: [URL: MediaInfo], folder: URL) {
        guard self.folder == folder else { return }
        mediaInfo.merge(info) { $1 }
        if sortKey == .taken || sortKey == .rating {
            applySort()
        } else if dateFilter != .any || ratingFilter != .any {
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
