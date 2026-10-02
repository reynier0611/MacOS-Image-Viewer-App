import AppKit
import SwiftUI

/// A folder tree: Home and iCloud Drive, plus every drive. Folders expand to show subfolders,
/// and the tree opens itself down to whatever folder the grid is showing.
struct SidebarView: View {
    @Environment(BrowserModel.self) private var model
    @State private var tree = FolderTree()
    @State private var volumes: [URL] = []
    @State private var volumeNames: [URL: String] = [:]

    private static let home = FileManager.default.homeDirectoryForCurrentUser
    private static let iCloud: URL? = {
        let url = home.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs", isDirectory: true)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }()

    /// Familiar icons for well-known folders; plain folders get a folder icon.
    private static let symbols: [String: String] = {
        var map = [home.path: "house"]
        let known: [(FileManager.SearchPathDirectory, String)] = [
            (.desktopDirectory, "menubar.dock.rectangle"), (.documentDirectory, "doc"),
            (.downloadsDirectory, "arrow.down.circle"), (.picturesDirectory, "photo"),
            (.moviesDirectory, "film"), (.musicDirectory, "music.note"), (.applicationDirectory, "square.grid.3x3"),
        ]
        for (directory, symbol) in known {
            if let url = FileManager.default.urls(for: directory, in: .userDomainMask).first { map[url.path] = symbol }
        }
        if let iCloud { map[iCloud.path] = "icloud" }
        return map
    }()

    private var roots: [URL] { [Self.home] + (Self.iCloud.map { [$0] } ?? []) + volumes }

    var body: some View {
        ScrollViewReader { proxy in
            List(selection: selection) {
                Section("Folders") {
                    FolderTreeRow(url: Self.home, title: FileManager.default.displayName(atPath: Self.home.path), symbols: Self.symbols, tree: tree)
                    if let iCloud = Self.iCloud {
                        FolderTreeRow(url: iCloud, title: "iCloud Drive", symbols: Self.symbols, tree: tree)
                    }
                }
                if !volumes.isEmpty {
                    Section("Locations") {
                        ForEach(volumes, id: \.self) { volume in
                            FolderTreeRow(
                                url: volume, title: volumeNames[volume] ?? volume.lastPathComponent,
                                symbols: [volume.path: volume.path == "/" ? "internaldrive" : "externaldrive"], tree: tree
                            )
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            .onAppear {
                refreshVolumes()
                tree.showHidden = model.showHidden
                if tree.expanded.isEmpty { tree.setExpanded(Self.home, true) }
            }
            .onChange(of: model.folder, initial: true) {
                guard let folder = model.folder else { return }
                Task {
                    if await tree.reveal(folder, roots: roots) {
                        try? await Task.sleep(for: .milliseconds(100)) // let the new rows lay out
                        withAnimation { proxy.scrollTo(folder.path) }
                    }
                }
            }
            .onChange(of: model.allFolders.map(\.url)) {
                if let folder = model.folder { tree.update(folder, subfolders: model.allFolders.map(\.url)) }
            }
            .onChange(of: model.showHidden) { tree.showHidden = model.showHidden }
            .onChange(of: model.folderStructureVersion) { tree.refreshExpanded() }
            .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didMountNotification)) { _ in refreshVolumes() }
            .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didUnmountNotification)) { _ in refreshVolumes() }
        }
    }

    /// Selection is keyed by path so it highlights whichever row matches the current folder.
    private var selection: Binding<String?> {
        Binding(
            get: { model.folder?.path },
            set: { path in
                guard let path, path != model.folder?.path else { return }
                model.navigate(to: URL(fileURLWithPath: path, isDirectory: true))
            }
        )
    }

    /// Off the main thread: an unreachable network drive can make these calls hang for a long
    /// time, which would otherwise freeze the window while the app launches.
    private func refreshVolumes() {
        Task.detached(priority: .utility) {
            let found = (FileManager.default.mountedVolumeURLs(
                includingResourceValuesForKeys: [.volumeNameKey, .volumeIsBrowsableKey],
                options: [.skipHiddenVolumes]
            ) ?? []).filter {
                (try? $0.resourceValues(forKeys: [.volumeIsBrowsableKey]))?.volumeIsBrowsable ?? true
            }
            let names = Dictionary(uniqueKeysWithValues: found.map {
                ($0, (try? $0.resourceValues(forKeys: [.volumeNameKey]))?.volumeName ?? $0.lastPathComponent)
            })
            await MainActor.run {
                volumes = found
                volumeNames = names
            }
        }
    }
}

/// One folder in the tree, with its subfolders nested underneath when expanded.
struct FolderTreeRow: View {
    @Environment(BrowserModel.self) private var model
    let url: URL
    let title: String
    var symbols: [String: String] = [:]
    let tree: FolderTree

    var body: some View {
        if tree.isLeaf(url) {
            row
        } else {
            DisclosureGroup(isExpanded: Binding(get: { tree.isExpanded(url) }, set: { tree.setExpanded(url, $0) })) {
                if let subfolders = tree.children[url.path] {
                    ForEach(subfolders, id: \.path) { subfolder in
                        // AnyView breaks the type recursion of a view that contains itself.
                        AnyView(FolderTreeRow(
                            url: subfolder, title: FileManager.default.displayName(atPath: subfolder.path),
                            symbols: symbols, tree: tree
                        ))
                    }
                } else {
                    ProgressView()
                        .controlSize(.small)
                }
            } label: {
                row
            }
        }
    }

    private var row: some View {
        Label(title, systemImage: symbols[url.path] ?? "folder")
            .lineLimit(1)
            .help(url.path)
            .folderDropTarget(url)
            .tag(url.path)
            .id(url.path)
            .contextMenu {
                Button("Open") { model.navigate(to: url) }
                Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                if let item = FileItem(url: url), url.path != FileManager.default.homeDirectoryForCurrentUser.path, url.path != "/" {
                    Divider()
                    Button("Rename…") { model.beginRename(item) }
                }
            }
    }
}
