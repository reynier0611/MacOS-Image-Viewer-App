import AVFoundation
import AppKit
import Observation
import SwiftUI
import UniformTypeIdentifiers

enum ZoomAction: Equatable {
    case fit, actualSize, zoomIn, zoomOut
}

struct ZoomRequest: Equatable {
    let action: ZoomAction
    let id = UUID()
}

struct MoveDestination: Identifiable {
    let title: String
    let url: URL
    var id: String { url.path }
}

extension UTType {
    /// Drag payload for images dragged within the app (the actual URLs live in `BrowserModel.draggedItems`).
    static let imageViewerSelection = UTType(exportedAs: "local.imageviewer.selection")
}

enum MediaTypeFilter: String, CaseIterable, Identifiable {
    case all = "All"
    case photos = "Photos"
    case videos = "Videos"
    case raw = "RAW"
    var id: String { rawValue }
}

enum DateFilter: String, CaseIterable, Identifiable {
    case any = "Any Date"
    case today = "Today"
    case last7Days = "Last 7 Days"
    case last30Days = "Last 30 Days"
    case thisYear = "This Year"
    case lastYear = "Last Year"
    case custom = "Custom Range…"
    var id: String { rawValue }

    func range(from: Date, to: Date) -> ClosedRange<Date> {
        let calendar = Calendar.current
        let now = Date()
        let today = calendar.startOfDay(for: now)
        let year = calendar.component(.year, from: now)
        func startOfYear(_ y: Int) -> Date { calendar.date(from: DateComponents(year: y, month: 1, day: 1))! }
        switch self {
        case .any: return Date.distantPast...Date.distantFuture
        case .today: return today...now
        case .last7Days: return calendar.date(byAdding: .day, value: -7, to: today)!...now
        case .last30Days: return calendar.date(byAdding: .day, value: -30, to: today)!...now
        case .thisYear: return startOfYear(year)...now
        case .lastYear: return startOfYear(year - 1)...startOfYear(year).addingTimeInterval(-1)
        case .custom:
            let start = calendar.startOfDay(for: min(from, to))
            let end = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: max(from, to)))!.addingTimeInterval(-1)
            return start...end
        }
    }
}

struct RenamePlan: Identifiable {
    let item: FileItem
    let newName: String
    var id: URL { item.url }
}

struct Toast: Identifiable, Equatable {
    let id = UUID()
    let message: String
    let canUndo: Bool
}

@MainActor
@Observable
final class BrowserModel {
    static let shared = BrowserModel()

    // MARK: Folder contents

    private(set) var folder: URL?
    /// Every subfolder / image / video in the folder, sorted. `folders` and `images` are
    /// these lists after the search and filters, and are what the grid and viewer show.
    private(set) var allFolders: [FileItem] = []
    private(set) var allImages: [FileItem] = []
    private(set) var folders: [FileItem] = []
    /// Images and videos (everything the viewer can show), in sort order, after filters.
    private(set) var images: [FileItem] = []
    /// Date taken and location per file, filled in the background after a folder loads.
    private(set) var mediaInfo: [URL: MediaInfo] = [:]
    /// On-device recognition labels per photo, computed when a search needs them.
    private(set) var contentLabels: [URL: [String]] = [:]
    private(set) var contentAnalysisDone = 0
    private(set) var contentAnalysisTotal = 0
    private(set) var folderError: String?
    private(set) var isLoadingFolder = false
    /// The focused item: arrow keys move it, the inspector shows it. Setting it collapses
    /// the multi-selection to just this item (except inside `adjustingSelection`).
    var selection: URL? {
        didSet {
            if !isAdjustingSelection { selectedURLs = selection.map { [$0] } ?? [] }
        }
    }
    /// Everything highlighted in the grid (⌘-click / ⇧-click / ⌘A).
    private(set) var selectedURLs: Set<URL> = []

    private(set) var backStack: [URL] = []
    private(set) var forwardStack: [URL] = []
    private(set) var recentFolders: [URL] = []
    private(set) var recentMoveDestinations: [URL] = []

    // MARK: Viewer

    private(set) var viewerIndex: Int?
    private(set) var currentImage: NSImage?
    /// Set instead of `currentImage` when the open item is a video.
    private(set) var videoPlayer: AVPlayer?
    private(set) var displayedURL: URL?
    private(set) var isLoadingImage = false
    private(set) var imageError: String?
    private(set) var zoomRequest: ZoomRequest?
    var zoomPercent: Int?

    // MARK: Text recognition (OCR)

    /// While on, every image opened in the viewer is scanned for text and the lines are highlighted.
    var isTextRecognitionOn = false {
        didSet {
            guard isTextRecognitionOn != oldValue else { return }
            selectedLineIDs = []
            recognizeTextIfNeeded()
        }
    }
    private(set) var recognizedLines: [RecognizedLine] = []
    private(set) var isRecognizingText = false
    var selectedLineIDs: Set<Int> = []

    // MARK: Search & filters

    var searchText = "" {
        didSet {
            guard searchText != oldValue else { return }
            refilter()
            if !searchText.trimmingCharacters(in: .whitespaces).isEmpty { startContentAnalysisIfNeeded() }
        }
    }
    var typeFilter: MediaTypeFilter = .all { didSet { refilter() } }
    var dateFilter: DateFilter = .any { didSet { refilter() } }
    var customDateFrom = Calendar.current.date(byAdding: .month, value: -1, to: Date())! {
        didSet { if dateFilter == .custom { refilter() } }
    }
    var customDateTo = Date() {
        didSet { if dateFilter == .custom { refilter() } }
    }

    var hasActiveFilters: Bool { typeFilter != .all || dateFilter != .any }
    var isFiltering: Bool { hasActiveFilters || !searchText.trimmingCharacters(in: .whitespaces).isEmpty }
    var isAnalyzingContent: Bool { contentAnalysisDone < contentAnalysisTotal }

    // MARK: UI state

    var isDuplicatesPresented = false
    var isBatchRenamePresented = false
    var isExportPresented = false

    var gridColumns = 1
    var columnVisibility: NavigationSplitViewVisibility = .all
    var toast: Toast?
    var errorMessage: String?
    var isRenamePresented = false
    var renameText = ""
    var isGoToFolderPresented = false
    var isNewFolderPresented = false
    var newFolderName = ""
    private(set) var newFolderItemCount = 0
    var goToFolderText = ""

    // MARK: Preferences

    var sortKey: SortKey {
        didSet { defaults.set(sortKey.rawValue, forKey: Keys.sortKey); applySort() }
    }
    var sortAscending: Bool {
        didSet { defaults.set(sortAscending, forKey: Keys.sortAscending); applySort() }
    }
    var thumbnailSize: Double {
        didSet { defaults.set(thumbnailSize, forKey: Keys.thumbnailSize) }
    }
    var showInspector: Bool {
        didSet { defaults.set(showInspector, forKey: Keys.showInspector) }
    }
    var showFilmstrip: Bool {
        didSet { defaults.set(showFilmstrip, forKey: Keys.showFilmstrip) }
    }
    var showHidden: Bool {
        didSet { defaults.set(showHidden, forKey: Keys.showHidden); reload() }
    }
    var enlargeSmallImages: Bool {
        didSet { defaults.set(enlargeSmallImages, forKey: Keys.enlargeSmallImages) }
    }


    // MARK: Internals

    @ObservationIgnored weak var undoManager: UndoManager?
    @ObservationIgnored private let defaults = UserDefaults.standard
    @ObservationIgnored private var renameItem: FileItem?
    @ObservationIgnored private var watcher: FolderWatcher?
    @ObservationIgnored private var keyMonitor: Any?
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var imageTask: Task<Void, Never>?
    @ObservationIgnored private var indexTask: Task<Void, Never>?
    @ObservationIgnored private var textTask: Task<Void, Never>?
    @ObservationIgnored private var recognizedURL: URL?
    @ObservationIgnored private var textCache: [URL: [RecognizedLine]] = [:]
    @ObservationIgnored private var analysisTask: Task<Void, Never>?
    @ObservationIgnored private var didStart = false
    @ObservationIgnored private var hasExplicitOpen = false
    @ObservationIgnored private var isAdjustingSelection = false
    @ObservationIgnored private var pendingNewFolderItems: [FileItem] = []
    /// Images being dragged inside the app, set when a drag starts.
    @ObservationIgnored private(set) var draggedItems: [FileItem] = []

    private enum Keys {
        static let sortKey = "sortKey"
        static let sortAscending = "sortAscending"
        static let thumbnailSize = "thumbnailSize"
        static let showInspector = "showInspector"
        static let showFilmstrip = "showFilmstrip"
        static let showHidden = "showHidden"
        static let enlargeSmallImages = "enlargeSmallImages"
        static let lastFolder = "lastFolder"
        static let recentFolders = "recentFolders"
        static let recentMoveDestinations = "recentMoveDestinations"
    }

    private init() {
        let d = UserDefaults.standard
        sortKey = SortKey(rawValue: d.string(forKey: Keys.sortKey) ?? "") ?? .name
        sortAscending = d.object(forKey: Keys.sortAscending) as? Bool ?? true
        thumbnailSize = d.object(forKey: Keys.thumbnailSize) as? Double ?? 160
        showInspector = d.bool(forKey: Keys.showInspector)
        showFilmstrip = d.object(forKey: Keys.showFilmstrip) as? Bool ?? true
        showHidden = d.bool(forKey: Keys.showHidden)
        enlargeSmallImages = d.object(forKey: Keys.enlargeSmallImages) as? Bool ?? true
        recentFolders = (d.stringArray(forKey: Keys.recentFolders) ?? [])
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
        recentMoveDestinations = (d.stringArray(forKey: Keys.recentMoveDestinations) ?? [])
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    // MARK: Derived state

    var isViewing: Bool { viewerIndex != nil }
    var gridItems: [FileItem] { folders + images }
    var canGoBack: Bool { !backStack.isEmpty }
    var canGoForward: Bool { !forwardStack.isEmpty }
    var canGoUp: Bool { folder.map { $0.path != "/" } ?? false }

    var currentItem: FileItem? {
        guard let index = viewerIndex, images.indices.contains(index) else { return nil }
        return images[index]
    }

    var selectedItem: FileItem? {
        guard let selection else { return nil }
        return folders.first { $0.url == selection } ?? images.first { $0.url == selection }
    }

    /// Selected images in grid order (folders are never trashed).
    var selectedImages: [FileItem] {
        images.filter { selectedURLs.contains($0.url) }
    }

    /// What the inspector describes: the open image, or the grid selection.
    var inspectedItem: FileItem? { currentItem ?? selectedItem }

    /// The image that menu/toolbar file actions apply to.
    var actionImage: FileItem? {
        guard let item = isViewing ? currentItem : selectedItem, !item.isDirectory else { return nil }
        return item
    }

    var folderDisplayName: String {
        guard let folder else { return "Image Viewer" }
        return FileManager.default.displayName(atPath: folder.path)
    }

    // MARK: Startup & opening

    func start() {
        installKeyMonitor()
    }

    /// Called once launching finishes, after any files Finder asked us to open have arrived,
    /// so a launch via "Open With" doesn't first flash the last-used folder.
    func openDefaultFolderIfNeeded() {
        guard !didStart else { return }
        didStart = true
        if folder != nil || hasExplicitOpen { return }

        // `ImageViewer /some/path` from a terminal.
        if let arg = CommandLine.arguments.dropFirst().first(where: { !$0.hasPrefix("-") && FileManager.default.fileExists(atPath: $0) }) {
            open(URL(fileURLWithPath: arg))
            return
        }
        if let last = defaults.string(forKey: Keys.lastFolder), FileManager.default.fileExists(atPath: last) {
            navigate(to: URL(fileURLWithPath: last, isDirectory: true), recordHistory: false)
        } else if let pictures = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask).first {
            navigate(to: pictures, recordHistory: false)
        }
    }

    /// Opens a folder (browse it) or an image (browse its folder and show the image).
    func open(_ url: URL) {
        hasExplicitOpen = true
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            errorMessage = "“\(url.path)” doesn't exist."
            return
        }
        let isPackage = (try? url.resourceValues(forKeys: [.isPackageKey]))?.isPackage ?? false
        if isDirectory.boolValue && !isPackage {
            navigate(to: url)
        } else {
            navigate(to: url.deletingLastPathComponent(), select: url, openViewer: true)
        }
    }

    func showOpenPanel() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.image, .folder]
        panel.directoryURL = folder
        panel.message = "Choose a folder to browse, or an image to open"
        if panel.runModal() == .OK, let url = panel.url {
            open(url)
        }
    }

    func presentGoToFolder() {
        goToFolderText = (folder?.path as NSString?)?.abbreviatingWithTildeInPath ?? "~"
        isGoToFolderPresented = true
    }

    func goToFolder(path: String) {
        let expanded = (path.trimmingCharacters(in: .whitespaces) as NSString).expandingTildeInPath
        guard !expanded.isEmpty else { return }
        open(URL(fileURLWithPath: expanded))
    }

    // MARK: Folder navigation

    func navigate(to url: URL, select: URL? = nil, openViewer: Bool = false, recordHistory: Bool = true) {
        // Resolve symlinks (e.g. /tmp → /private/tmp) so paths compare equal to the scanned items.
        let url = URL(fileURLWithPath: Self.canonicalPath(url), isDirectory: true)
        let select = select.map { URL(fileURLWithPath: Self.canonicalPath($0)) }
        let changed = folder?.path != url.path
        if recordHistory, changed, let folder {
            backStack.append(folder)
            forwardStack.removeAll()
        }
        closeViewer()
        if changed {
            folder = url
            allFolders = []
            allImages = []
            folders = []
            images = []
            mediaInfo = [:]
            contentLabels = [:]
            indexTask?.cancel()
            analysisTask?.cancel()
            analysisTask = nil
            contentAnalysisDone = 0
            contentAnalysisTotal = 0
            searchText = ""
            selection = nil
            folderError = nil
            watcher = FolderWatcher(url: url) { [weak self] in self?.reload() }
            remember(url)
        }
        load(select: select, viewing: openViewer ? select : nil)
    }

    private nonisolated static func canonicalPath(_ url: URL) -> String {
        guard let resolved = realpath(url.path, nil) else { return url.standardizedFileURL.path }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    func goBack() {
        guard let previous = backStack.popLast(), let current = folder else { return }
        forwardStack.append(current)
        navigate(to: previous, select: current, recordHistory: false)
    }

    func goForward() {
        guard let next = forwardStack.popLast(), let current = folder else { return }
        backStack.append(current)
        navigate(to: next, recordHistory: false)
    }

    func goToEnclosingFolder() {
        guard let folder, canGoUp else { return }
        navigate(to: folder.deletingLastPathComponent(), select: folder)
    }

    func goToStandardFolder(_ directory: FileManager.SearchPathDirectory) {
        if let url = FileManager.default.urls(for: directory, in: .userDomainMask).first {
            navigate(to: url)
        }
    }

    func goHome() {
        navigate(to: FileManager.default.homeDirectoryForCurrentUser)
    }

    func reload() {
        load(select: selection, viewing: isViewing ? displayedURL : nil, fallbackIndex: viewerIndex)
    }

    private func remember(_ url: URL) {
        defaults.set(url.path, forKey: Keys.lastFolder)
        recentFolders.removeAll { $0.path == url.path }
        recentFolders.insert(url, at: 0)
        recentFolders = Array(recentFolders.prefix(10))
        defaults.set(recentFolders.map(\.path), forKey: Keys.recentFolders)
    }

    private func load(select: URL?, viewing: URL?, fallbackIndex: Int? = nil, alsoSelect: [URL] = []) {
        guard let folder else { return }
        loadTask?.cancel()
        isLoadingFolder = true
        let showHidden = showHidden
        loadTask = Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                BrowserModel.scan(folder, showHidden: showHidden)
            }.value
            guard let self, !Task.isCancelled, self.folder == folder else { return }
            self.apply(result, select: select, viewing: viewing, fallbackIndex: fallbackIndex, alsoSelect: alsoSelect)
        }
    }

    private nonisolated static func scan(_ folder: URL, showHidden: Bool) -> Result<[FileItem], Error> {
        do {
            let urls = try FileManager.default.contentsOfDirectory(
                at: folder,
                includingPropertiesForKeys: FileItem.resourceKeys,
                options: showHidden ? [] : [.skipsHiddenFiles]
            )
            return .success(urls.compactMap(FileItem.init(url:)))
        } catch {
            return .failure(error)
        }
    }

    private func apply(
        _ result: Result<[FileItem], Error>, select: URL?, viewing: URL?, fallbackIndex: Int?, alsoSelect: [URL]
    ) {
        isLoadingFolder = false
        switch result {
        case .success(let items):
            folderError = nil
            allFolders = items.filter(\.isDirectory)
            allImages = items.filter { !$0.isDirectory }
            sortItems()
            startIndexing()
            if !searchText.trimmingCharacters(in: .whitespaces).isEmpty { startContentAnalysisIfNeeded() }
        case .failure(let error):
            allFolders = []
            allImages = []
            refilter()
            folderError = error.localizedDescription
        }

        let items = gridItems
        if let select, let match = items.first(where: { $0.url.path == select.path }), match.url != selection {
            selection = match.url
        } else if let current = selection, items.contains(where: { $0.url == current }) {
            // Keep the current selection (e.g. a folder refresh), dropping anything that vanished.
            let present = Set(items.map(\.url))
            selectedURLs.formIntersection(present)
            if selectedURLs.isEmpty { selectedURLs = [current] }
        } else {
            selection = images.first?.url ?? folders.first?.url
        }
        if !alsoSelect.isEmpty {
            let paths = Set(alsoSelect.map(\.path))
            selectedURLs.formUnion(items.filter { paths.contains($0.url.path) }.map(\.url))
        }

        if let viewing {
            if let index = images.firstIndex(where: { $0.url.path == viewing.path }) {
                openImage(at: index)
            } else if let fallbackIndex, !images.isEmpty {
                // The open image disappeared (deleted or renamed outside the app).
                displayedURL = nil
                openImage(at: min(fallbackIndex, images.count - 1))
            } else {
                closeViewer()
            }
        }
    }

    private func sortItems() {
        allFolders.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        let key = sortKey
        let ascending = sortAscending
        allImages.sort { a, b in
            let (x, y) = ascending ? (a, b) : (b, a)
            switch key {
            case .name:
                return x.name.localizedStandardCompare(y.name) == .orderedAscending
            case .taken:
                let dx = captureDate(for: x), dy = captureDate(for: y)
                if dx != dy { return dx < dy }
            case .modified:
                if x.modified != y.modified { return x.modified < y.modified }
            case .created:
                if x.created != y.created { return x.created < y.created }
            case .size:
                if x.size != y.size { return x.size < y.size }
            }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
        refilter()
    }

    private func applySort() {
        sortItems()
    }

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

    private var searchTokens: [String] {
        searchText.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
    }

    private func passesFilters(_ item: FileItem, tokens: [String], dates: ClosedRange<Date>?) -> Bool {
        switch typeFilter {
        case .all: break
        case .photos: if item.isVideo { return false }
        case .videos: if !item.isVideo { return false }
        case .raw: if !item.isRaw { return false }
        }
        if let dates, !dates.contains(captureDate(for: item)) { return false }
        let name = item.name.lowercased()
        let labels = contentLabels[item.url] ?? []
        // Every word must match the file name or something recognized in the photo.
        return tokens.allSatisfy { token in
            name.contains(token) || labels.contains { $0.contains(token) }
        }
    }

    /// Recomputes `folders`/`images` from the full lists, keeping the viewer and selection consistent.
    private func refilter() {
        let tokens = searchTokens
        let dates = dateFilter == .any ? nil : dateFilter.range(from: customDateFrom, to: customDateTo)
        images = allImages.filter { passesFilters($0, tokens: tokens, dates: dates) }
        folders = tokens.isEmpty ? allFolders : allFolders.filter { folder in
            tokens.allSatisfy { folder.name.lowercased().contains($0) }
        }

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
    private func startIndexing() {
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

    private func mergeMediaInfo(_ info: [URL: MediaInfo], folder: URL) {
        guard self.folder == folder else { return }
        mediaInfo.merge(info) { $1 }
        if sortKey == .taken {
            applySort()
        } else if dateFilter != .any {
            refilter()
        }
    }

    private func startContentAnalysisIfNeeded() {
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

    private func mergeLabels(_ labels: [URL: [String]], done: Int, folder: URL) {
        guard self.folder == folder else { return }
        contentLabels.merge(labels) { $1 }
        contentAnalysisDone = done
        if done >= contentAnalysisTotal {
            analysisTask = nil // later searches pick up files added since
        }
        if !searchTokens.isEmpty { refilter() }
    }

    // MARK: Grid selection

    func moveSelection(by delta: Int) {
        let items = gridItems
        guard !items.isEmpty else { return }
        guard let current = selection, let index = items.firstIndex(where: { $0.url == current }) else {
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

    /// Plain click selects one, ⌘ toggles, ⇧ adds the range from the focused item.
    func click(_ item: FileItem, modifiers: NSEvent.ModifierFlags) {
        let items = gridItems
        if modifiers.contains(.shift),
           let anchor = selection,
           let from = items.firstIndex(where: { $0.url == anchor }),
           let to = items.firstIndex(where: { $0.url == item.url }) {
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
        isAdjustingSelection = true
        defer { isAdjustingSelection = false }
        selection = focus ?? urls.first
        selectedURLs = urls
    }

    func clearSelection() {
        selection = nil
    }

    func selectAll() {
        guard !isViewing else { return }
        selectedURLs = Set(gridItems.map(\.url))
    }

    func activate(_ item: FileItem) {
        if item.isDirectory {
            navigate(to: item.url)
        } else if let index = images.firstIndex(where: { $0.url == item.url }) {
            openImage(at: index)
        }
    }

    func openSelection() {
        if let item = selectedItem { activate(item) }
    }

    // MARK: Viewer

    func openImage(at index: Int) {
        guard images.indices.contains(index) else { return }
        let item = images[index]
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

    private func preloadNeighbors(of url: URL) {
        guard let index = images.firstIndex(where: { $0.url == url }) else { return }
        for neighbor in [index + 1, index - 1] where images.indices.contains(neighbor) && !images[neighbor].isVideo {
            let neighborURL = images[neighbor].url
            Task.detached(priority: .utility) { _ = await ImageLoader.shared.load(neighborURL) }
        }
    }

    func closeViewer() {
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

    private func recognizeTextIfNeeded() {
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

    // MARK: File actions

    /// What Move to Trash / Move to Folder act on: the open image in the viewer; in the grid, every
    /// selected image — or, from a context menu, the clicked item (plus the rest of the
    /// selection if it was part of it, like Finder).
    func fileActionTargets(for item: FileItem? = nil) -> [FileItem] {
        if isViewing {
            return (item ?? currentItem).map { [$0] } ?? []
        }
        if let item, !selectedURLs.contains(item.url) {
            return item.isDirectory ? [] : [item]
        }
        return selectedImages
    }

    func moveToTrash(_ item: FileItem? = nil) {
        trash(fileActionTargets(for: item))
    }

    func trash(_ items: [FileItem]) {
        guard !items.isEmpty else { return }
        var moved: [(original: URL, trashed: URL)] = []
        var removed: Set<URL> = []
        var failures: [String] = []
        for item in items {
            do {
                var resulting: NSURL?
                try FileManager.default.trashItem(at: item.url, resultingItemURL: &resulting)
                ImageLoader.shared.invalidate(item.url)
                removed.insert(item.url)
                if let trashed = resulting as URL? {
                    moved.append((item.url, trashed))
                }
            } catch {
                failures.append("“\(item.name)”: \(error.localizedDescription)")
            }
        }
        removeFromList(removed)

        if !moved.isEmpty {
            undoManager?.registerUndo(withTarget: self) { model in
                MainActor.assumeIsolated { model.restore(moved) }
            }
            undoManager?.setActionName(moved.count == 1 ? "Move to Trash" : "Move \(moved.count) Items to Trash")
        }
        if removed.count == 1, let name = items.first(where: { removed.contains($0.url) })?.name {
            showToast("Moved “\(name)” to the Trash", canUndo: !moved.isEmpty)
        } else if removed.count > 1 {
            showToast("Moved \(removed.count) images to the Trash", canUndo: !moved.isEmpty)
        }
        if !failures.isEmpty {
            errorMessage = "Couldn't move \(failures.count) item\(failures.count == 1 ? "" : "s") to the Trash.\n"
                + failures.joined(separator: "\n")
        }
    }

    private func removeFromList(_ urls: Set<URL>) {
        guard !urls.isEmpty else { return }
        let firstGridIndex = gridItems.firstIndex { urls.contains($0.url) }
        let viewedIndex = displayedURL.flatMap { url in images.firstIndex { $0.url == url } }
        let removingViewed = displayedURL.map(urls.contains) ?? false
        images.removeAll { urls.contains($0.url) }
        allImages.removeAll { urls.contains($0.url) }

        if removingViewed, let viewedIndex {
            displayedURL = nil
            if images.isEmpty {
                closeViewer()
            } else {
                openImage(at: min(viewedIndex, images.count - 1))
            }
        } else if isViewing, let url = displayedURL {
            viewerIndex = images.firstIndex { $0.url == url }
        } else {
            // Select whatever now sits where the first deleted item was.
            selectedURLs.subtract(urls)
            if selectedURLs.isEmpty || selection.map(urls.contains) == true {
                let items = gridItems
                if let firstGridIndex, !items.isEmpty {
                    selection = items[min(firstGridIndex, items.count - 1)].url
                } else {
                    selection = nil
                }
            }
        }
    }

    private func restore(_ entries: [(original: URL, trashed: URL)]) {
        var restored: [URL] = []
        var failures: [String] = []
        for entry in entries {
            do {
                try FileManager.default.moveItem(at: entry.trashed, to: entry.original)
                restored.append(entry.original)
            } catch {
                failures.append("“\(entry.original.lastPathComponent)”: \(error.localizedDescription)")
            }
        }
        if !restored.isEmpty {
            // Redo trashes them again.
            undoManager?.registerUndo(withTarget: self) { model in
                MainActor.assumeIsolated { model.trash(restored.compactMap(FileItem.init(url:))) }
            }
            undoManager?.setActionName(restored.count == 1 ? "Move to Trash" : "Move \(restored.count) Items to Trash")
            let here = restored.filter { $0.deletingLastPathComponent().path == folder?.path }
            if let first = here.first {
                load(select: first, viewing: isViewing ? first : nil, alsoSelect: isViewing ? [] : here)
            }
            showToast(
                restored.count == 1 ? "Restored “\(restored[0].lastPathComponent)”" : "Restored \(restored.count) images",
                canUndo: false
            )
        }
        if !failures.isEmpty {
            errorMessage = "Couldn't restore \(failures.count) item\(failures.count == 1 ? "" : "s").\n"
                + failures.joined(separator: "\n")
        }
    }

    // MARK: Moving

    /// Subfolders here, the parent folder, and recently used destinations, for the "Move to" menus.
    var moveDestinationGroups: [(title: String, destinations: [MoveDestination])] {
        var seen: Set<String> = [folder?.path ?? ""]
        func unique(_ urls: [URL]) -> [MoveDestination] {
            urls.compactMap { url in
                guard seen.insert(url.path).inserted else { return nil }
                return MoveDestination(title: FileManager.default.displayName(atPath: url.path), url: url)
            }
        }
        var groups: [(String, [MoveDestination])] = []
        let here = unique(folders.prefix(30).map(\.url))
        if !here.isEmpty { groups.append(("Folders Here", here)) }
        if canGoUp, let folder {
            groups.append(("Enclosing Folder", unique([folder.deletingLastPathComponent()])))
        }
        let recent = unique(recentMoveDestinations.filter { FileManager.default.fileExists(atPath: $0.path) })
        if !recent.isEmpty { groups.append(("Recent", recent)) }
        return groups
    }

    func showMovePanel(for item: FileItem? = nil) {
        let items = fileActionTargets(for: item)
        guard !items.isEmpty else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = recentMoveDestinations.first ?? folder
        panel.prompt = "Move"
        panel.message = items.count == 1 ? "Move “\(items[0].name)” to:" : "Move \(items.count) images to:"
        if panel.runModal() == .OK, let url = panel.url {
            move(items, to: url)
        }
    }

    /// Moves images into `destination`. Never overwrites: a name clash becomes “name 2.jpg”.
    func move(_ items: [FileItem], to destination: URL) {
        let destination = URL(fileURLWithPath: Self.canonicalPath(destination), isDirectory: true)
        let items = items.filter { !$0.isDirectory && $0.url.deletingLastPathComponent().path != destination.path }
        guard !items.isEmpty else { return }
        var planned: [(from: URL, to: URL)] = []
        for item in items {
            planned.append((item.url, uniqueDestination(for: item.name, in: destination, excluding: planned.map(\.to))))
        }
        let done = applyMoves(planned)
        guard !done.isEmpty else { return }

        rememberMoveDestination(destination)
        let name = FileManager.default.displayName(atPath: destination.path)
        let renamed = done.filter { $0.from.lastPathComponent != $0.to.lastPathComponent }.count
        var message = done.count == 1 ? "Moved “\(done[0].to.lastPathComponent)” to “\(name)”" : "Moved \(done.count) images to “\(name)”"
        if renamed > 0 { message += " (\(renamed) renamed to avoid overwriting)" }
        showToast(message, canUndo: true)
    }

    /// Performs file moves, updates the listing, and registers the inverse for Undo/Redo.
    @discardableResult
    private func applyMoves(_ moves: [(from: URL, to: URL)]) -> [(from: URL, to: URL)] {
        var done: [(from: URL, to: URL)] = []
        var failures: [String] = []
        for move in moves {
            do {
                guard !FileManager.default.fileExists(atPath: move.to.path) else {
                    throw CocoaError(.fileWriteFileExists)
                }
                try FileManager.default.moveItem(at: move.from, to: move.to)
                ImageLoader.shared.invalidate(move.from)
                done.append(move)
            } catch {
                failures.append("“\(move.from.lastPathComponent)”: \(error.localizedDescription)")
            }
        }

        let here = folder?.path
        let leaving = Set(done.filter { $0.from.deletingLastPathComponent().path == here }.map(\.from))
        let arriving = done.filter { $0.to.deletingLastPathComponent().path == here }.map(\.to)
        removeFromList(leaving)
        if let first = arriving.first {
            if isViewing {
                load(select: displayedURL, viewing: displayedURL, fallbackIndex: viewerIndex)
            } else {
                load(select: first, viewing: nil, alsoSelect: arriving)
            }
        }

        if !done.isEmpty {
            let inverse = done.reversed().map { (from: $0.to, to: $0.from) }
            undoManager?.registerUndo(withTarget: self) { model in
                MainActor.assumeIsolated { _ = model.applyMoves(inverse) }
            }
            undoManager?.setActionName(done.count == 1 ? "Move" : "Move \(done.count) Images")
        }
        if !failures.isEmpty {
            errorMessage = "Couldn't move \(failures.count) item\(failures.count == 1 ? "" : "s").\n"
                + failures.joined(separator: "\n")
        }
        return done
    }

    private func uniqueDestination(for name: String, in directory: URL, excluding taken: [URL]) -> URL {
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var candidate = directory.appendingPathComponent(name)
        var counter = 2
        while FileManager.default.fileExists(atPath: candidate.path) || taken.contains(where: { $0.path == candidate.path }) {
            candidate = directory.appendingPathComponent(ext.isEmpty ? "\(base) \(counter)" : "\(base) \(counter).\(ext)")
            counter += 1
        }
        return candidate
    }

    private func rememberMoveDestination(_ url: URL) {
        recentMoveDestinations.removeAll { $0.path == url.path }
        recentMoveDestinations.insert(url, at: 0)
        recentMoveDestinations = Array(recentMoveDestinations.prefix(8))
        defaults.set(recentMoveDestinations.map(\.path), forKey: Keys.recentMoveDestinations)
    }

    // MARK: Drag and drop

    /// Called when a drag starts on an image: drags the whole selection if the image is part of it.
    func beginDrag(_ item: FileItem) {
        if !selectedURLs.contains(item.url) {
            selection = item.url
        }
        draggedItems = selectedImages.isEmpty ? [item] : selectedImages
    }

    func canDrop(onto destination: URL) -> Bool {
        !draggedItems.isEmpty
            && destination.path != folder?.path
            && draggedItems.contains { $0.url.deletingLastPathComponent().path != destination.path }
    }

    @discardableResult
    func dropDragged(onto destination: URL) -> Bool {
        guard canDrop(onto: destination) else { return false }
        let items = draggedItems
        draggedItems = []
        move(items, to: destination)
        return true
    }

    // MARK: New folder with selection

    func beginNewFolderWithSelection(_ item: FileItem? = nil) {
        let items = fileActionTargets(for: item)
        guard !items.isEmpty, folder != nil else { return }
        pendingNewFolderItems = items
        newFolderItemCount = items.count
        newFolderName = "New Folder"
        isNewFolderPresented = true
    }

    func commitNewFolder() {
        let items = pendingNewFolderItems
        pendingNewFolderItems = []
        guard let folder, !items.isEmpty else { return }
        let name = newFolderName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !name.contains("/"), !name.hasPrefix(".") else {
            errorMessage = "“\(name)” isn't a valid folder name."
            return
        }
        let url = folder.appendingPathComponent(name, isDirectory: true)
        guard !FileManager.default.fileExists(atPath: url.path) else {
            errorMessage = "An item named “\(name)” already exists here."
            return
        }
        do {
            try createFolder(url)
        } catch {
            errorMessage = "Couldn't create “\(name)”.\n\(error.localizedDescription)"
            return
        }
        // One undo step (same event): moves the images back, then removes the empty folder.
        move(items, to: url)
        load(select: url, viewing: nil)
    }

    private func createFolder(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        undoManager?.registerUndo(withTarget: self) { model in
            MainActor.assumeIsolated { model.removeFolderIfEmpty(url) }
        }
    }

    private func removeFolderIfEmpty(_ url: URL) {
        let contents = (try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []
        guard contents.allSatisfy({ $0 == ".DS_Store" }) else { return }
        do {
            try FileManager.default.removeItem(at: url)
        } catch {
            return
        }
        undoManager?.registerUndo(withTarget: self) { model in
            MainActor.assumeIsolated { try? model.createFolder(url) }
        }
        // Not reload(): that would cancel a pending refresh that reselects the images just moved back.
        allFolders.removeAll { $0.url.path == url.path }
        folders.removeAll { $0.url.path == url.path }
    }

    // MARK: Rotate & flip

    /// Rotates or flips the open image, or every selected image, without re-compressing.
    func changeOrientation(_ change: OrientationChange, item: FileItem? = nil) {
        let targets = fileActionTargets(for: item).filter { !$0.isVideo }
        applyOrientation(change, to: targets.map(\.url))
    }

    private func applyOrientation(_ change: OrientationChange, to urls: [URL]) {
        guard !urls.isEmpty else { return }
        var changed: [URL] = []
        var failures: [String] = []
        for url in urls {
            do {
                try ImageEditing.changeOrientation(of: url, by: change)
                changed.append(url)
            } catch {
                failures.append(error.localizedDescription)
            }
        }
        if !changed.isEmpty {
            for url in changed {
                ImageLoader.shared.invalidate(url)
                ThumbnailLoader.shared.invalidate(url)
                textCache[url] = nil
                if recognizedURL == url { recognizedURL = nil }
            }
            let viewing = displayedURL.flatMap { changed.contains($0) ? $0 : nil }
            if viewing != nil {
                displayedURL = nil // force the viewer to decode the new orientation
            }
            load(select: selection, viewing: viewing ?? (isViewing ? displayedURL : nil), fallbackIndex: viewerIndex)
            undoManager?.registerUndo(withTarget: self) { model in
                MainActor.assumeIsolated { model.applyOrientation(change.inverse, to: changed) }
            }
            undoManager?.setActionName(change.rawValue)
        }
        if !failures.isEmpty {
            errorMessage = failures.count == 1 ? failures[0] : "\(failures.count) images couldn't be changed.\n" + failures.joined(separator: "\n")
        }
    }

    // MARK: Batch rename

    /// Images the batch tools (rename, export) work on: the open image, or the selection in the grid.
    var batchTargets: [FileItem] {
        fileActionTargets().filter { !$0.isDirectory }
    }

    /// Date taken for each item, reading metadata directly for anything not indexed yet.
    nonisolated static func captureDates(for items: [FileItem], known: [URL: MediaInfo]) async -> [URL: Date] {
        var dates: [URL: Date] = [:]
        for item in items {
            let date = known[item.url]?.captureDate
                ?? (item.isVideo ? nil : MediaIndex.readImage(item.url).captureDate)
            dates[item.url] = date ?? min(item.created, item.modified)
        }
        return dates
    }

    /// Tokens: {name} original name, {n} counter, {date} 2026-09-28, {time} 143012,
    /// {year} {month} {day}. The extension is always kept.
    static func renamePlans(
        for items: [FileItem], template: String, start: Int, digits: Int, dates: [URL: Date]
    ) -> [RenamePlan] {
        let dateFormat = DateFormatter()
        dateFormat.locale = Locale(identifier: "en_US_POSIX")
        func format(_ date: Date, _ pattern: String) -> String {
            dateFormat.dateFormat = pattern
            return dateFormat.string(from: date)
        }
        return items.enumerated().map { index, item in
            let date = dates[item.url] ?? min(item.created, item.modified)
            let counter = String(format: "%0\(max(1, digits))d", start + index)
            var base = template
                .replacingOccurrences(of: "{name}", with: item.url.deletingPathExtension().lastPathComponent)
                .replacingOccurrences(of: "{n}", with: counter)
                .replacingOccurrences(of: "{date}", with: format(date, "yyyy-MM-dd"))
                .replacingOccurrences(of: "{time}", with: format(date, "HHmmss"))
                .replacingOccurrences(of: "{year}", with: format(date, "yyyy"))
                .replacingOccurrences(of: "{month}", with: format(date, "MM"))
                .replacingOccurrences(of: "{day}", with: format(date, "dd"))
            base = base.trimmingCharacters(in: .whitespaces)
            let ext = item.url.pathExtension
            return RenamePlan(item: item, newName: ext.isEmpty ? base : "\(base).\(ext)")
        }
    }

    /// Why the plan can't be applied, or nil if it's fine.
    static func problem(with plans: [RenamePlan]) -> String? {
        var seen: Set<String> = []
        let sources = Set(plans.map { $0.item.url.path.lowercased() })
        for plan in plans {
            let base = (plan.newName as NSString).deletingPathExtension
            if base.isEmpty { return "A name would be empty." }
            if plan.newName.contains("/") || plan.newName.contains(":") { return "Names can't contain “/” or “:”." }
            if plan.newName.hasPrefix(".") { return "Names can't start with a period." }
            let key = plan.newName.lowercased()
            if !seen.insert(key).inserted { return "Two files would both be named “\(plan.newName)”. Add {n} to the pattern." }
            let destination = plan.item.url.deletingLastPathComponent().appendingPathComponent(plan.newName)
            if FileManager.default.fileExists(atPath: destination.path), !sources.contains(destination.path.lowercased()) {
                return "“\(plan.newName)” already exists in this folder."
            }
        }
        return nil
    }

    func applyBatchRename(_ plans: [RenamePlan]) {
        let moves = plans
            .filter { $0.newName != $0.item.name }
            .map { (from: $0.item.url, to: $0.item.url.deletingLastPathComponent().appendingPathComponent($0.newName)) }
        guard !moves.isEmpty, Self.problem(with: plans) == nil else { return }
        let sources = Set(moves.map { $0.from.path.lowercased() })
        // Renames that swap names, or only change letter case, go through temporary names first.
        // Both phases happen in one event, so ⌘Z undoes the whole batch in one step.
        if moves.contains(where: { sources.contains($0.to.path.lowercased()) }) {
            let temporary = moves.map { move in
                (from: move.from, to: move.from.deletingLastPathComponent()
                    .appendingPathComponent(".rename-\(UUID().uuidString).\(move.from.pathExtension)"))
            }
            applyMoves(temporary)
            applyMoves(zip(temporary, moves).map { (from: $0.0.to, to: $0.1.to) })
        } else {
            applyMoves(moves)
        }
        undoManager?.setActionName("Rename \(moves.count) Items")
        showToast("Renamed \(moves.count) item\(moves.count == 1 ? "" : "s")", canUndo: true)
    }

    // MARK: Export

    func runExport(
        _ items: [FileItem], options: ExportOptions, to directory: URL,
        progress: @escaping @MainActor (Int) -> Void
    ) async -> [String] {
        var failures: [String] = []
        for (index, item) in items.enumerated() where !item.isVideo {
            if Task.isCancelled { break }
            let url = item.url
            do {
                _ = try await Task.detached(priority: .userInitiated) {
                    try Exporter.export(url, to: directory, options: options)
                }.value
            } catch {
                failures.append("“\(item.name)”: \(error.localizedDescription)")
            }
            progress(index + 1)
        }
        let exported = items.filter { !$0.isVideo }.count - failures.count
        if exported > 0 {
            showToast("Exported \(exported) image\(exported == 1 ? "" : "s") to “\(FileManager.default.displayName(atPath: directory.path))”", canUndo: false)
        }
        return failures
    }

    func beginRename(_ item: FileItem? = nil) {
        guard let item = item ?? actionImage else { return }
        renameItem = item
        renameText = item.url.deletingPathExtension().lastPathComponent
        isRenamePresented = true
    }

    func commitRename() {
        guard let item = renameItem else { return }
        renameItem = nil
        let base = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !base.isEmpty, !base.contains("/"), !base.hasPrefix(".") else {
            errorMessage = "“\(base)” isn't a valid name."
            return
        }
        let ext = item.url.pathExtension
        let destination = item.url.deletingLastPathComponent()
            .appendingPathComponent(ext.isEmpty ? base : "\(base).\(ext)")
        rename(from: item.url, to: destination)
    }

    private func rename(from source: URL, to destination: URL) {
        guard source.path != destination.path else { return }
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            errorMessage = "An item named “\(destination.lastPathComponent)” already exists."
            return
        }
        do {
            try FileManager.default.moveItem(at: source, to: destination)
        } catch {
            errorMessage = "Couldn't rename “\(source.lastPathComponent)”.\n\(error.localizedDescription)"
            return
        }
        ImageLoader.shared.invalidate(source)
        let wasViewing = displayedURL == source
        if wasViewing {
            // Same pixels, new name: keep showing the current image without a reload.
            displayedURL = destination
        }
        load(select: destination, viewing: wasViewing ? destination : nil)
        undoManager?.registerUndo(withTarget: self) { model in
            MainActor.assumeIsolated { model.rename(from: destination, to: source) }
        }
        undoManager?.setActionName("Rename")
    }

    func revealInFinder(_ item: FileItem? = nil) {
        if let url = (item ?? (isViewing ? currentItem : selectedItem))?.url ?? folder {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }

    func openWithDefaultApp(_ item: FileItem? = nil) {
        guard let item = item ?? actionImage else { return }
        NSWorkspace.shared.open(item.url)
    }

    /// Preview for images, QuickTime Player for videos.
    func openInPreview(_ item: FileItem? = nil) {
        guard let item = item ?? actionImage,
              let preview = NSWorkspace.shared.urlForApplication(
                  withBundleIdentifier: item.isVideo ? "com.apple.QuickTimePlayerX" : "com.apple.Preview"
              )
        else { return }
        NSWorkspace.shared.open([item.url], withApplicationAt: preview, configuration: NSWorkspace.OpenConfiguration())
    }

    /// Puts both the file and its pixels on the clipboard: pastes as a file in Finder, as an image elsewhere.
    func copyImage(_ item: FileItem? = nil) {
        guard let item = item ?? actionImage else { return }
        let pasteboardItem = NSPasteboardItem()
        pasteboardItem.setString(item.url.absoluteString, forType: .fileURL)
        let image = (displayedURL == item.url ? currentImage : nil) ?? NSImage(contentsOf: item.url)
        if let tiff = image?.tiffRepresentation {
            pasteboardItem.setData(tiff, forType: .tiff)
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([pasteboardItem])
        showToast("Copied “\(item.name)”", canUndo: false)
    }

    func copyPath(_ item: FileItem? = nil) {
        guard let url = (item ?? (isViewing ? currentItem : selectedItem))?.url ?? folder else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.path, forType: .string)
        showToast("Copied path", canUndo: false)
    }

    func showToast(_ message: String, canUndo: Bool) {
        let toast = Toast(message: message, canUndo: canUndo)
        withAnimation(.easeOut(duration: 0.2)) { self.toast = toast }
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(canUndo ? 5 : 2))
            guard let self, self.toast?.id == toast.id else { return }
            withAnimation(.easeIn(duration: 0.2)) { self.toast = nil }
        }
    }

    // MARK: Keyboard

    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            return MainActor.assumeIsolated { self.handleKey(event) } ? nil : event
        }
    }

    /// Plain (unmodified) keys. Command shortcuts live in the menus (see AppCommands).
    private func handleKey(_ event: NSEvent) -> Bool {
        guard let window = event.window,
              !(window is NSPanel),
              window.attachedSheet == nil,
              window.sheetParent == nil,
              !(window.firstResponder is NSText) // typing in a text field
        else { return false }

        let modifiers = event.modifierFlags
            .intersection(.deviceIndependentFlagsMask)
            .subtracting([.numericPad, .function, .capsLock])
        if modifiers == .command, event.charactersIgnoringModifiers == "a", !isViewing {
            selectAll()
            return true
        }
        guard modifiers.isEmpty else { return false }

        switch event.keyCode {
        case 123: step(-1) // ←
        case 124: step(1) // →
        case 125: isViewing ? step(1) : moveSelection(by: gridColumns) // ↓
        case 126: isViewing ? step(-1) : moveSelection(by: -gridColumns) // ↑
        case 36, 76: // return / enter
            guard !isViewing else { return false }
            openSelection()
        case 49: // space: play/pause a video, otherwise open/close the viewer
            if videoPlayer != nil { togglePlayback() } else { toggleViewer() }
        case 53: // escape
            if isTextRecognitionOn {
                isTextRecognitionOn = false
            } else if isViewing {
                closeViewer()
            } else if selectedURLs.count > 1 {
                selectedURLs = selection.map { [$0] } ?? [] // collapse to the focused item
            } else {
                return false
            }
        case 115: showFirst() // home
        case 119: showLast() // end
        default:
            if event.charactersIgnoringModifiers == "f" {
                toggleFullScreen()
            } else {
                return false
            }
        }
        return true
    }
}

/// Watches a folder so files added/removed/renamed outside the app show up.
final class FolderWatcher {
    private let source: DispatchSourceFileSystemObject
    private var pending: DispatchWorkItem?

    init?(url: URL, onChange: @escaping @MainActor () -> Void) {
        let descriptor = open(url.path, O_EVTONLY)
        guard descriptor >= 0 else { return nil }
        source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor, eventMask: [.write, .rename, .delete], queue: .main
        )
        source.setEventHandler { [weak self] in
            // Debounce bursts (e.g. copying many files in).
            self?.pending?.cancel()
            let work = DispatchWorkItem { MainActor.assumeIsolated { onChange() } }
            self?.pending = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
        }
        source.setCancelHandler { close(descriptor) }
        source.resume()
    }

    deinit {
        pending?.cancel()
        source.cancel()
    }
}
