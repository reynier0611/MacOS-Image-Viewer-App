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
    private(set) var folders: [FileItem] = []
    /// Images and videos (everything the viewer can show), in sort order.
    private(set) var images: [FileItem] = []
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

    // MARK: UI state

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
            folders = []
            images = []
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
            folders = items.filter(\.isDirectory)
            images = items.filter { !$0.isDirectory }
            sortItems()
        case .failure(let error):
            folders = []
            images = []
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
        folders.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        let key = sortKey
        let ascending = sortAscending
        images.sort { a, b in
            let (x, y) = ascending ? (a, b) : (b, a)
            switch key {
            case .name:
                return x.name.localizedStandardCompare(y.name) == .orderedAscending
            case .modified:
                if x.modified != y.modified { return x.modified < y.modified }
            case .created:
                if x.created != y.created { return x.created < y.created }
            case .size:
                if x.size != y.size { return x.size < y.size }
            }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
    }

    private func applySort() {
        sortItems()
        if isViewing, let url = displayedURL {
            viewerIndex = images.firstIndex { $0.url == url }
        }
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
            return
        }
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

    private func trash(_ items: [FileItem]) {
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
        folders.removeAll { $0.url.path == url.path }
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
            if isViewing {
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
