import AppKit
import SwiftUI

struct SidebarView: View {
    @Environment(BrowserModel.self) private var model
    @State private var volumes: [URL] = []

    private struct Favorite: Identifiable {
        let title: String
        let symbol: String
        let url: URL
        var id: URL { url }
    }

    private static let favorites: [Favorite] = {
        let fm = FileManager.default
        func dir(_ d: FileManager.SearchPathDirectory) -> URL? { fm.urls(for: d, in: .userDomainMask).first }
        var list: [Favorite] = [
            Favorite(title: "Home", symbol: "house", url: fm.homeDirectoryForCurrentUser),
        ]
        let standard: [(String, String, FileManager.SearchPathDirectory)] = [
            ("Desktop", "menubar.dock.rectangle", .desktopDirectory),
            ("Documents", "doc", .documentDirectory),
            ("Downloads", "arrow.down.circle", .downloadsDirectory),
            ("Pictures", "photo", .picturesDirectory),
        ]
        for (title, symbol, directory) in standard {
            if let url = dir(directory) { list.append(Favorite(title: title, symbol: symbol, url: url)) }
        }
        let iCloud = fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs", isDirectory: true)
        if fm.fileExists(atPath: iCloud.path) {
            list.append(Favorite(title: "iCloud Drive", symbol: "icloud", url: iCloud))
        }
        return list
    }()

    var body: some View {
        List(selection: selection) {
            Section("Favorites") {
                ForEach(Self.favorites) { favorite in
                    Label(favorite.title, systemImage: favorite.symbol)
                        .folderDropTarget(favorite.url)
                        .tag(favorite.url.path)
                }
            }
            if !volumes.isEmpty {
                Section("Locations") {
                    ForEach(volumes, id: \.self) { volume in
                        Label(volumeName(volume), systemImage: volume.path == "/" ? "internaldrive" : "externaldrive")
                            .folderDropTarget(volume)
                            .tag(volume.path)
                    }
                }
            }
            let favoritePaths = Set(Self.favorites.map(\.url.path))
            let recents = model.recentFolders.filter { !favoritePaths.contains($0.path) }.prefix(8)
            if !recents.isEmpty {
                Section("Recent") {
                    ForEach(Array(recents), id: \.self) { url in
                        Label(FileManager.default.displayName(atPath: url.path), systemImage: "folder")
                            .folderDropTarget(url)
                            .help(url.path)
                            .tag(url.path)
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .onAppear { refreshVolumes() }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didMountNotification)) { _ in refreshVolumes() }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didUnmountNotification)) { _ in refreshVolumes() }
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

    private func refreshVolumes() {
        volumes = (FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: [.volumeNameKey, .volumeIsBrowsableKey],
            options: [.skipHiddenVolumes]
        ) ?? []).filter {
            (try? $0.resourceValues(forKeys: [.volumeIsBrowsableKey]))?.volumeIsBrowsable ?? true
        }
    }

    private func volumeName(_ url: URL) -> String {
        (try? url.resourceValues(forKeys: [.volumeNameKey]))?.volumeName ?? url.lastPathComponent
    }
}
