import AppKit
import SwiftUI

struct BrowserView: View {
    @Environment(BrowserModel.self) private var model

    var body: some View {
        Group {
            if model.folder == nil {
                ContentUnavailableView {
                    Label("No Folder Open", systemImage: "photo.on.rectangle.angled")
                } description: {
                    Text("Open a folder or an image, or drop one here.")
                } actions: {
                    Button("Open…") { model.showOpenPanel() }
                }
            } else if let error = model.folderError {
                ContentUnavailableView("Can't Open Folder", systemImage: "lock", description: Text(error))
            } else if model.gridItems.isEmpty && !model.isLoadingFolder {
                ContentUnavailableView("No Images", systemImage: "photo", description: Text("This folder has no images or subfolders."))
            } else {
                ThumbnailGrid()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if let folder = model.folder {
                VStack(spacing: 0) {
                    Divider()
                    PathBar(url: folder) { model.navigate(to: $0) }
                        .padding(.horizontal, 10)
                        .frame(height: 26)
                }
                .background(.bar)
            }
        }
    }
}

struct ThumbnailGrid: View {
    @Environment(BrowserModel.self) private var model

    private let spacing: CGFloat = 12
    private let padding: CGFloat = 16

    var body: some View {
        let size = CGFloat(model.thumbnailSize)
        let cellWidth = size + 12

        GeometryReader { geometry in
            let columns = max(1, Int((geometry.size.width - padding * 2 + spacing) / (cellWidth + spacing)))
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVGrid(
                        columns: Array(repeating: GridItem(.fixed(cellWidth), spacing: spacing), count: columns),
                        spacing: 16
                    ) {
                        ForEach(model.gridItems) { item in
                            GridCell(item: item, size: size, isSelected: model.selectedURLs.contains(item.url))
                                .id(item.url)
                                .onTapGesture(count: 2) { model.activate(item) }
                                .simultaneousGesture(TapGesture().onEnded {
                                    model.click(item, modifiers: NSEvent.modifierFlags)
                                })
                                .contextMenu { ItemContextMenu(item: item) }
                        }
                    }
                    .padding(padding)
                }
                .onChange(of: columns, initial: true) { model.gridColumns = columns }
                .onChange(of: model.selection) { _, selection in
                    guard let selection, !model.isViewing else { return }
                    proxy.scrollTo(selection)
                }
                .onChange(of: model.isViewing) { _, isViewing in
                    guard !isViewing, let selection = model.selection else { return }
                    proxy.scrollTo(selection, anchor: .center)
                }
            }
        }
    }
}

struct GridCell: View {
    let item: FileItem
    let size: CGFloat
    let isSelected: Bool

    var body: some View {
        VStack(spacing: 5) {
            Group {
                if item.isDirectory {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: item.url.path))
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: size * 0.75, height: size * 0.75)
                        .frame(width: size, height: size)
                } else {
                    ThumbnailView(item: item, size: size)
                }
            }
            .padding(6)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isSelected ? Color.secondary.opacity(0.22) : .clear)
            )

            Text(item.name)
                .font(.callout)
                .lineLimit(2)
                .truncationMode(.middle)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .foregroundStyle(isSelected ? .white : .primary)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(isSelected ? Color.accentColor : .clear)
                )
                .frame(width: size + 12)
        }
        .contentShape(Rectangle())
        .help(item.name)
    }
}

struct ThumbnailView: View {
    let item: FileItem
    let size: CGFloat
    @State private var image: NSImage?

    init(item: FileItem, size: CGFloat) {
        self.item = item
        self.size = size
        _image = State(initialValue: ThumbnailLoader.shared.cached(for: item, maxPixel: Self.bucket(for: size)))
    }

    /// Retina-sharp thumbnails, rounded up to a few fixed sizes so the cache is reused while resizing.
    private static func bucket(for size: CGFloat) -> Int {
        let target = Int(size * 2)
        return [128, 256, 512, 800].first { $0 >= target } ?? 800
    }

    var body: some View {
        let bucket = Self.bucket(for: size)
        ZStack {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 3))
                    .shadow(color: .black.opacity(0.25), radius: 1.5, y: 1)
            } else {
                RoundedRectangle(cornerRadius: 4)
                    .fill(.quaternary)
                    .frame(width: size * 0.8, height: size * 0.6)
            }
        }
        .frame(width: size, height: size)
        .task(id: "\(item.url.path)|\(bucket)|\(item.modified.timeIntervalSince1970)") {
            if let cached = ThumbnailLoader.shared.cached(for: item, maxPixel: bucket) {
                image = cached
                return
            }
            if let thumbnail = await ThumbnailLoader.shared.thumbnail(for: item, maxPixel: bucket) {
                image = thumbnail
            } else if !Task.isCancelled, image == nil {
                image = NSWorkspace.shared.icon(forFile: item.url.path)
            }
        }
    }
}

struct ItemContextMenu: View {
    @Environment(BrowserModel.self) private var model
    let item: FileItem

    var body: some View {
        Button("Open") { model.activate(item) }
        if !item.isDirectory {
            Button("Open in Preview") { model.openInPreview(item) }
            Button("Open with Default App") { model.openWithDefaultApp(item) }
        }
        Button("Reveal in Finder") { model.revealInFinder(item) }
        Divider()
        if !item.isDirectory {
            Button("Copy Image") { model.copyImage(item) }
        }
        Button("Copy Path") { model.copyPath(item) }
        ShareLink(item: item.url)
        if !item.isDirectory {
            Divider()
            Button("Rename…") { model.beginRename(item) }
        }
        let trashCount = model.trashTargets(for: item).count
        if trashCount > 0 {
            if item.isDirectory { Divider() }
            Button(trashCount == 1 ? "Move to Trash" : "Move \(trashCount) Images to Trash", role: .destructive) {
                model.moveToTrash(item)
            }
        }
    }
}

/// Finder-style clickable breadcrumb for the current folder.
struct PathBar: View {
    let url: URL
    let onSelect: (URL) -> Void

    private var components: [URL] {
        var result: [URL] = []
        var current = url
        while result.count < 64 {
            result.insert(current, at: 0)
            if current.path == "/" { break }
            current = current.deletingLastPathComponent()
        }
        return result
    }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 3) {
                ForEach(Array(components.enumerated()), id: \.offset) { index, component in
                    if index > 0 {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 8, weight: .semibold))
                            .foregroundStyle(.tertiary)
                    }
                    Button { onSelect(component) } label: {
                        HStack(spacing: 3) {
                            Image(nsImage: NSWorkspace.shared.icon(forFile: component.path))
                                .resizable()
                                .frame(width: 14, height: 14)
                            Text(FileManager.default.displayName(atPath: component.path))
                        }
                    }
                    .buttonStyle(.plain)
                    .font(.caption)
                    .foregroundStyle(index == components.count - 1 ? .primary : .secondary)
                }
            }
        }
    }
}
