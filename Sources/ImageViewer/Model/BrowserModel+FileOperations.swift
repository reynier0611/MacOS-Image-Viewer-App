import AVFoundation
import AppKit
import Observation
import SwiftUI
import UniformTypeIdentifiers

/// Trash, move, drag and drop, new folder, rename, and Finder/clipboard actions. All undoable where it makes sense.
extension BrowserModel {
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

    /// What Move to Trash acts on: the open image; a folder from the sidebar; the clicked item;
    /// or everything selected in the grid, folders included. Home, drives and standard folders
    /// (Desktop, Documents…) are never offered.
    func trashTargets(for item: FileItem? = nil) -> [FileItem] {
        if let item, isProtectedFolder(item.url) { return [] }
        if isViewing { return [item ?? currentItem].compactMap { $0 } }
        if let item, !selectedURLs.contains(item.url) { return [item] }
        return selectedGridItems.filter { !isProtectedFolder($0.url) }
    }

    func isProtectedFolder(_ url: URL) -> Bool {
        let path = url.path
        if path == "/" || path == FileManager.default.homeDirectoryForCurrentUser.path { return true }
        if path.hasPrefix("/Volumes/"), url.pathComponents.count == 3 { return true } // a drive
        let standard: [FileManager.SearchPathDirectory] = [
            .desktopDirectory, .documentDirectory, .downloadsDirectory, .picturesDirectory,
            .moviesDirectory, .musicDirectory, .applicationDirectory, .libraryDirectory,
        ]
        return standard.contains { FileManager.default.urls(for: $0, in: .userDomainMask).first?.path == path }
    }

    /// Moves to the Trash right away, or first asks when folders are involved.
    func moveToTrash(_ item: FileItem? = nil) {
        let targets = trashTargets(for: item)
        guard !targets.isEmpty else { return }
        if targets.contains(where: \.isDirectory) {
            pendingTrash = targets
            isTrashConfirmationPresented = true
        } else {
            trash(targets)
        }
    }

    func confirmPendingTrash() {
        let items = pendingTrash
        pendingTrash = []
        isTrashConfirmationPresented = false
        trash(items)
    }

    var trashConfirmationTitle: String {
        let folders = pendingTrash.filter(\.isDirectory)
        if pendingTrash.count == 1, let folder = folders.first {
            return "Move “\(folder.name)” and everything in it to the Trash?"
        }
        return "Move \(pendingTrash.count) items, including \(folders.count) folder\(folders.count == 1 ? "" : "s") and everything in \(folders.count == 1 ? "it" : "them"), to the Trash?"
    }

    func trash(_ items: [FileItem]) {
        guard !items.isEmpty else { return }
        var moved: [(original: URL, trashed: URL)] = []
        var removed: Set<URL> = []
        var failures: [String] = []
        for item in items {
            do {
                let resulting = try moveItemToTrash(item.url)
                ImageLoader.shared.invalidate(item.url)
                removed.insert(item.url)
                if let trashed = resulting {
                    moved.append((item.url, trashed))
                }
            } catch {
                failures.append("“\(item.name)”: \(error.localizedDescription)")
            }
        }
        removeFromList(removed)
        let trashedFolders = items.filter { $0.isDirectory && removed.contains($0.url) }.map(\.url)
        if !trashedFolders.isEmpty {
            folderStructureVersion += 1
            func isInside(_ url: URL) -> Bool {
                trashedFolders.contains { url.path == $0.path || url.path.hasPrefix($0.path + "/") }
            }
            backStack.removeAll(where: isInside)
            forwardStack.removeAll(where: isInside)
            // Trashed the open folder (or one containing it) from the sidebar: step out of it.
            if let folder, let gone = trashedFolders.first(where: { folder.path == $0.path || folder.path.hasPrefix($0.path + "/") }) {
                navigate(to: gone.deletingLastPathComponent(), select: nil, recordHistory: false)
            }
        }

        if !moved.isEmpty {
            undoManager?.registerUndo(withTarget: self) { model in
                MainActor.assumeIsolated { model.restore(moved) }
            }
            undoManager?.setActionName(moved.count == 1 ? "Move to Trash" : "Move \(moved.count) Items to Trash")
        }
        if removed.count == 1, let name = items.first(where: { removed.contains($0.url) })?.name {
            showToast("Moved “\(name)” to the Trash", canUndo: !moved.isEmpty)
        } else if removed.count > 1 {
            showToast("Moved \(removed.count) items to the Trash", canUndo: !moved.isEmpty)
        }
        if !failures.isEmpty {
            errorMessage = "Couldn't move \(failures.count) item\(failures.count == 1 ? "" : "s") to the Trash.\n"
                + failures.joined(separator: "\n")
        }
    }

    func removeFromList(_ urls: Set<URL>) {
        guard !urls.isEmpty else { return }
        let firstGridIndex = urls.compactMap { gridIndex[$0] }.min()
        let viewedIndex = displayedURL.flatMap { url in images.firstIndex { $0.url == url } }
        let removingViewed = displayedURL.map(urls.contains) ?? false
        images.removeAll { urls.contains($0.url) }
        allImages.removeAll { urls.contains($0.url) }
        folders.removeAll { urls.contains($0.url) }
        allFolders.removeAll { urls.contains($0.url) }

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

    func restore(_ entries: [(original: URL, trashed: URL)]) {
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
            if restored.contains(where: { (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true }) {
                folderStructureVersion += 1
            }
            let here = restored.filter(isListed)
            if let first = here.first {
                load(select: first, viewing: isViewing ? first : nil, alsoSelect: isViewing ? [] : here)
            }
            showToast(
                restored.count == 1 ? "Restored “\(restored[0].lastPathComponent)”" : "Restored \(restored.count) items",
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
        let here = unique(allFolders.prefix(30).map(\.url)) // also when subfolders are flattened
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
    func applyMoves(_ moves: [(from: URL, to: URL)]) -> [(from: URL, to: URL)] {
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

        let leaving = Set(done.filter { isListed($0.from) }.map(\.from))
        let arriving = done.filter { isListed($0.to) }.map(\.to)
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

    func uniqueDestination(for name: String, in directory: URL, excluding taken: [URL]) -> URL {
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

    func forgetMoveDestinations() {
        recentMoveDestinations = []
        defaults.removeObject(forKey: Keys.recentMoveDestinations)
    }

    func rememberMoveDestination(_ url: URL) {
        guard remembersMoveDestinations else { return }
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

    func createFolder(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        folderStructureVersion += 1
        undoManager?.registerUndo(withTarget: self) { model in
            MainActor.assumeIsolated { model.removeFolderIfEmpty(url) }
        }
    }

    func removeFolderIfEmpty(_ url: URL) {
        let contents = (try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []
        guard contents.allSatisfy({ $0 == ".DS_Store" }) else { return }
        defer { folderStructureVersion += 1 }
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

    /// Renames the given item, or the open image / the selected file or folder.
    func beginRename(_ item: FileItem? = nil) {
        guard let item = item ?? (isViewing ? currentItem : selectedItem) else { return }
        renameItem = item
        isRenamingFolder = item.isDirectory
        // Folders like "2024.06 Trip" have no extension to protect: edit the whole name.
        renameText = item.isDirectory ? item.name : item.url.deletingPathExtension().lastPathComponent
        isRenamePresented = true
    }

    func commitRename() {
        guard let item = renameItem else { return }
        renameItem = nil
        let base = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !base.isEmpty, !base.contains("/"), !base.contains(":"), !base.hasPrefix(".") else {
            errorMessage = "“\(base)” isn't a valid name. Names can't be empty, contain “/” or “:”, or start with a period."
            return
        }
        let parent = item.url.deletingLastPathComponent()
        let ext = item.url.pathExtension
        let destination = item.isDirectory
            ? parent.appendingPathComponent(base, isDirectory: true)
            : parent.appendingPathComponent(ext.isEmpty ? base : "\(base).\(ext)")
        rename(from: item.url, to: destination)
    }

    func rename(from source: URL, to destination: URL) {
        guard source.path != destination.path else { return }
        // On a case-insensitive disk (the macOS default) "trip" and "Trip" are the same name,
        // so a case-only change must go through a temporary name.
        let caseOnly = source.path.lowercased() == destination.path.lowercased()
        guard caseOnly || !FileManager.default.fileExists(atPath: destination.path) else {
            errorMessage = "An item named “\(destination.lastPathComponent)” already exists."
            return
        }
        do {
            if caseOnly {
                let temporary = source.deletingLastPathComponent().appendingPathComponent(".rename-\(UUID().uuidString)")
                try FileManager.default.moveItem(at: source, to: temporary)
                try FileManager.default.moveItem(at: temporary, to: destination)
            } else {
                try FileManager.default.moveItem(at: source, to: destination)
            }
        } catch {
            errorMessage = "Couldn't rename “\(source.lastPathComponent)”.\n\(error.localizedDescription)"
            return
        }
        ImageLoader.shared.invalidate(source)
        updateRememberedPaths(from: source, to: destination)
        let wasViewing = displayedURL == source
        if wasViewing {
            // Same pixels, new name: keep showing the current image without a reload.
            displayedURL = destination
        }
        if let folder, folder.path == source.path || folder.path.hasPrefix(source.path + "/") {
            // Renamed the open folder or one containing it (possible from the sidebar): follow it.
            navigate(to: URL(fileURLWithPath: destination.path + folder.path.dropFirst(source.path.count), isDirectory: true), recordHistory: false)
        } else {
            load(select: destination, viewing: wasViewing ? destination : nil)
        }
        if (try? destination.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
            folderStructureVersion += 1
        }
        undoManager?.registerUndo(withTarget: self) { model in
            MainActor.assumeIsolated { model.rename(from: destination, to: source) }
        }
        undoManager?.setActionName("Rename")
    }

    /// After a folder is renamed, Back/Forward, remembered "Move to" folders and the launch folder
    /// setting that pointed into it follow the new name instead of going stale.
    func updateRememberedPaths(from source: URL, to destination: URL) {
        let old = source.path, new = destination.path
        func updated(_ url: URL) -> URL {
            if url.path == old { return URL(fileURLWithPath: new, isDirectory: true) }
            if url.path.hasPrefix(old + "/") {
                return URL(fileURLWithPath: new + url.path.dropFirst(old.count), isDirectory: true)
            }
            return url
        }
        backStack = backStack.map(updated)
        forwardStack = forwardStack.map(updated)
        if recentMoveDestinations.contains(where: { updated($0) != $0 }) {
            recentMoveDestinations = recentMoveDestinations.map(updated)
            defaults.set(recentMoveDestinations.map(\.path), forKey: Keys.recentMoveDestinations)
        }
        if !customLaunchPath.isEmpty {
            let launch = updated(URL(fileURLWithPath: customLaunchPath, isDirectory: true)).path
            if launch != customLaunchPath { customLaunchPath = launch }
        }
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
}
