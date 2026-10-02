import Foundation
import Observation

/// State for the sidebar's folder tree: which folders are expanded and their (lazily loaded)
/// subfolders. Nothing is read until a folder is expanded, so big drives stay fast and protected
/// folders (Desktop, Documents…) aren't touched just by expanding their parent.
@MainActor
@Observable
final class FolderTree {
    /// Paths of expanded folders.
    private(set) var expanded: Set<String> = []
    /// Subfolders per folder path; missing = not loaded yet.
    private(set) var children: [String: [URL]] = [:]
    var showHidden = false {
        didSet {
            guard showHidden != oldValue else { return }
            children = [:]
            for path in expanded { load(URL(fileURLWithPath: path, isDirectory: true)) }
        }
    }

    func isExpanded(_ url: URL) -> Bool { expanded.contains(url.path) }

    /// True once a folder is known to have no subfolders (its disclosure arrow is then hidden).
    func isLeaf(_ url: URL) -> Bool { children[url.path]?.isEmpty == true }

    func setExpanded(_ url: URL, _ isExpanded: Bool) {
        if isExpanded {
            expanded.insert(url.path)
            load(url) // refresh on every expand, so changes made elsewhere show up
        } else {
            expanded.remove(url.path)
        }
    }

    func load(_ url: URL) {
        Task { await loadNow(url) }
    }

    func loadNow(_ url: URL) async {
        let showHidden = showHidden
        let folders = await Task.detached(priority: .userInitiated) {
            Self.subfolders(of: url, showHidden: showHidden)
        }.value
        children[url.path] = folders
    }

    /// Reloads every expanded folder (after the app renamed, created or removed a folder) and
    /// forgets expanded folders that no longer exist.
    func refreshExpanded() {
        expanded = expanded.filter { FileManager.default.fileExists(atPath: $0) }
        for path in expanded { load(URL(fileURLWithPath: path, isDirectory: true)) }
    }

    /// Keeps the tree in step with the grid's listing (e.g. after renaming or creating a folder).
    func update(_ url: URL, subfolders: [URL]) {
        guard children[url.path] != nil || expanded.contains(url.path) else { return }
        let sorted = Self.sorted(subfolders)
        if children[url.path] != sorted { children[url.path] = sorted }
    }

    /// Expands the tree down to `folder` (not the folder itself), under the most specific root
    /// that contains it, e.g. iCloud Drive rather than Home. Returns false if no root contains it.
    @discardableResult
    func reveal(_ folder: URL, roots: [URL]) async -> Bool {
        func contains(_ root: URL, _ path: String) -> Bool {
            path == root.path || path.hasPrefix(root.path == "/" ? "/" : root.path + "/")
        }
        guard let root = roots.filter({ contains($0, folder.path) }).max(by: { $0.path.count < $1.path.count }) else {
            return false
        }
        var chain: [URL] = [] // root … parent of folder
        var current = folder.deletingLastPathComponent()
        while contains(root, current.path) {
            chain.insert(URL(fileURLWithPath: current.path, isDirectory: true), at: 0)
            if current.path == root.path || current.path == "/" { break }
            current = current.deletingLastPathComponent()
        }
        for (index, ancestor) in chain.enumerated() {
            expanded.insert(ancestor.path)
            if children[ancestor.path] == nil { await loadNow(ancestor) }
            // A hidden folder on the way (e.g. /private) still gets a row so the path is visible.
            let next = index + 1 < chain.count ? chain[index + 1] : folder
            if let list = children[ancestor.path], !list.contains(where: { $0.path == next.path }) {
                children[ancestor.path] = Self.sorted(list + [URL(fileURLWithPath: next.path, isDirectory: true)])
            }
        }
        return true
    }

    nonisolated static func subfolders(of url: URL, showHidden: Bool) -> [URL] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isPackageKey]
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: url, includingPropertiesForKeys: keys, options: showHidden ? [] : [.skipsHiddenFiles]
        )) ?? []
        return sorted(urls.filter { url in
            let values = try? url.resourceValues(forKeys: Set(keys))
            return values?.isDirectory == true && values?.isPackage != true
        })
    }

    nonisolated static func sorted(_ urls: [URL]) -> [URL] {
        urls.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }
}
