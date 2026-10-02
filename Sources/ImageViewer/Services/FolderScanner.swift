import Foundation

/// Lists what the browser shows for a folder.
enum FolderScanner {
    /// Normal: the folder's own files and subfolders.
    /// Recursive ("all subfolders"): every image and video at any depth, plus the folder's direct
    /// subfolders (kept for the Move to menu, not shown as tiles). Hidden folders and packages
    /// (apps, the Photos library…) are skipped; unreadable subfolders are skipped, not fatal.
    static func scan(
        _ folder: URL, recursive: Bool, showHidden: Bool, progress: (Int) -> Void = { _ in }
    ) -> Result<[FileItem], Error> {
        do {
            // Surfaces permission problems with the folder itself.
            let top = try FileManager.default.contentsOfDirectory(
                at: folder, includingPropertiesForKeys: FileItem.resourceKeys, options: showHidden ? [] : [.skipsHiddenFiles]
            )
            guard recursive else { return .success(top.compactMap(FileItem.init(url:))) }

            var options: FileManager.DirectoryEnumerationOptions = [.skipsPackageDescendants]
            if !showHidden { options.insert(.skipsHiddenFiles) }
            guard let enumerator = FileManager.default.enumerator(
                at: folder, includingPropertiesForKeys: FileItem.resourceKeys, options: options, errorHandler: { _, _ in true }
            ) else { return .success([]) }

            var items: [FileItem] = []
            var media = 0
            for case let url as URL in enumerator {
                if Task.isCancelled { return .success([]) }
                guard let item = FileItem(url: url) else { continue }
                if item.isDirectory {
                    if enumerator.level == 1 { items.append(item) }
                } else {
                    items.append(item)
                    media += 1
                    if media % 250 == 0 { progress(media) }
                }
            }
            return .success(items)
        } catch {
            return .failure(error)
        }
    }
}
