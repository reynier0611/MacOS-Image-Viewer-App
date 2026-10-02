import AVFoundation
import AppKit
import Observation
import SwiftUI
import UniformTypeIdentifiers

/// All app state. The class is split across `Model/BrowserModel+*.swift` by feature, so state
/// that those files update is `internal`; views should read it and change it only through the
/// model's methods (the few `var`s bound directly by controls are the exception).
@MainActor
@Observable
final class BrowserModel {
    static let shared = BrowserModel()

    // MARK: Folder contents

    private(set) var folder: URL?
    /// Every subfolder / image / video in the folder, sorted. `folders` and `images` are
    /// these lists after the search and filters, and are what the grid and viewer show.
    var allFolders: [FileItem] = []
    var allImages: [FileItem] = []
    var folders: [FileItem] = []
    /// Images and videos (everything the viewer can show), in sort order, after filters.
    var images: [FileItem] = []
    /// Date taken and location per file, filled in the background after a folder loads.
    var mediaInfo: [URL: MediaInfo] = [:]
    /// On-device recognition labels per photo, computed when a search needs them.
    var contentLabels: [URL: [String]] = [:]
    var contentAnalysisDone = 0
    var contentAnalysisTotal = 0
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
    var selectedURLs: Set<URL> = []

    var backStack: [URL] = []
    var forwardStack: [URL] = []
    var recentMoveDestinations: [URL] = []

    // MARK: Viewer

    var viewerIndex: Int?
    var currentImage: NSImage?
    /// Set instead of `currentImage` when the open item is a video.
    var videoPlayer: AVPlayer?
    var displayedURL: URL?
    var isLoadingImage = false
    var imageError: String?
    var zoomRequest: ZoomRequest?
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
    var recognizedLines: [RecognizedLine] = []
    var isRecognizingText = false
    var selectedLineIDs: Set<Int> = []
    /// Print the extracted text over the image (on), or just outline it to see the original (off).
    var showsExtractedText = true

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
    var ratingFilter: RatingFilter = .any { didSet { refilter() } }
    var customDateFrom = Calendar.current.date(byAdding: .month, value: -1, to: Date())! {
        didSet { if dateFilter == .custom { refilter() } }
    }
    var customDateTo = Date() {
        didSet { if dateFilter == .custom { refilter() } }
    }

    var hasActiveFilters: Bool { typeFilter != .all || dateFilter != .any || ratingFilter != .any }
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
    /// Whether the item being renamed is a folder (the whole name is editable; no extension is kept).
    var isRenamingFolder = false
    var isGoToFolderPresented = false
    var isNewFolderPresented = false
    var newFolderName = ""
    var newFolderItemCount = 0
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
    var launchFolder: LaunchFolder {
        didSet { defaults.set(launchFolder.rawValue, forKey: Keys.launchFolder) }
    }
    var customLaunchPath: String {
        didSet { defaults.set(customLaunchPath, forKey: Keys.customLaunchPath) }
    }
    var viewerBackground: ViewerBackground {
        didSet { defaults.set(viewerBackground.rawValue, forKey: Keys.viewerBackground) }
    }
    var remembersMoveDestinations: Bool {
        didSet {
            defaults.set(remembersMoveDestinations, forKey: Keys.remembersMoveDestinations)
            if !remembersMoveDestinations { forgetMoveDestinations() }
        }
    }


    // MARK: Internals

    @ObservationIgnored weak var undoManager: UndoManager?
    @ObservationIgnored let defaults = UserDefaults.standard
    @ObservationIgnored var renameItem: FileItem?
    @ObservationIgnored var watcher: FolderWatcher?
    @ObservationIgnored var keyMonitor: Any?
    @ObservationIgnored var loadTask: Task<Void, Never>?
    @ObservationIgnored var imageTask: Task<Void, Never>?
    @ObservationIgnored var indexTask: Task<Void, Never>?
    @ObservationIgnored var textTask: Task<Void, Never>?
    /// Rating writes run one after another, in the order they were requested.
    @ObservationIgnored var ratingWrites: Task<Void, Never>?
    @ObservationIgnored var recognizedURL: URL?
    @ObservationIgnored var textCache: [URL: [RecognizedLine]] = [:]
    @ObservationIgnored var analysisTask: Task<Void, Never>?
    @ObservationIgnored var didStart = false
    @ObservationIgnored var hasExplicitOpen = false
    @ObservationIgnored var isAdjustingSelection = false
    @ObservationIgnored var pendingNewFolderItems: [FileItem] = []
    /// Images being dragged inside the app, set when a drag starts.
    @ObservationIgnored var draggedItems: [FileItem] = []

    enum Keys {
        static let sortKey = "sortKey"
        static let sortAscending = "sortAscending"
        static let thumbnailSize = "thumbnailSize"
        static let showInspector = "showInspector"
        static let showFilmstrip = "showFilmstrip"
        static let showHidden = "showHidden"
        static let enlargeSmallImages = "enlargeSmallImages"
        static let launchFolder = "launchFolder"
        static let customLaunchPath = "customLaunchPath"
        static let viewerBackground = "viewerBackground"
        static let remembersMoveDestinations = "remembersMoveDestinations"
        static let recentMoveDestinations = "recentMoveDestinations"
    }

    init() {
        let d = UserDefaults.standard
        sortKey = SortKey(rawValue: d.string(forKey: Keys.sortKey) ?? "") ?? .name
        sortAscending = d.object(forKey: Keys.sortAscending) as? Bool ?? true
        thumbnailSize = d.object(forKey: Keys.thumbnailSize) as? Double ?? 160
        showInspector = d.bool(forKey: Keys.showInspector)
        showFilmstrip = d.object(forKey: Keys.showFilmstrip) as? Bool ?? true
        showHidden = d.bool(forKey: Keys.showHidden)
        enlargeSmallImages = d.object(forKey: Keys.enlargeSmallImages) as? Bool ?? true
        launchFolder = LaunchFolder(rawValue: d.string(forKey: Keys.launchFolder) ?? "") ?? .home
        customLaunchPath = d.string(forKey: Keys.customLaunchPath) ?? ""
        viewerBackground = ViewerBackground(rawValue: d.string(forKey: Keys.viewerBackground) ?? "") ?? .blurredPhoto
        remembersMoveDestinations = d.object(forKey: Keys.remembersMoveDestinations) as? Bool ?? true
        // Earlier versions remembered the last and recent folders; forget them.
        d.removeObject(forKey: "lastFolder")
        d.removeObject(forKey: "recentFolders")
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

    /// Called once launching finishes, after any files Finder asked us to open have arrived.
    /// Opened with a file or folder → that. Opened directly → always the home folder
    /// (the app deliberately doesn't remember where you were last time).
    func openDefaultFolderIfNeeded() {
        guard !didStart else { return }
        didStart = true
        if folder != nil || hasExplicitOpen { return }

        // `ImageViewer /some/path` from a terminal.
        if let arg = CommandLine.arguments.dropFirst().first(where: { !$0.hasPrefix("-") && FileManager.default.fileExists(atPath: $0) }) {
            open(URL(fileURLWithPath: arg))
            return
        }
        navigate(to: launchFolderURL, recordHistory: false)
    }

    /// The folder chosen in Settings ▸ General (home by default; falls back to home if missing).
    var launchFolderURL: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let url: URL? = switch launchFolder {
        case .home: home
        case .pictures: FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask).first
        case .desktop: FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
        case .custom: customLaunchPath.isEmpty ? nil : URL(fileURLWithPath: customLaunchPath, isDirectory: true)
        }
        guard let url, FileManager.default.fileExists(atPath: url.path) else { return home }
        return url
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
        }
        load(select: select, viewing: openViewer ? select : nil)
    }

    nonisolated static func canonicalPath(_ url: URL) -> String {
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

    func load(select: URL?, viewing: URL?, fallbackIndex: Int? = nil, alsoSelect: [URL] = []) {
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

    nonisolated static func scan(_ folder: URL, showHidden: Bool) -> Result<[FileItem], Error> {
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

    func apply(
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

    func sortItems() {
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
            case .rating:
                let rx = rating(for: x), ry = rating(for: y)
                if rx != ry { return rx < ry }
            }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
        refilter()
    }

    func applySort() {
        sortItems()
    }
}
