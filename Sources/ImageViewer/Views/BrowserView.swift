import AppKit
import SwiftUI
import UniformTypeIdentifiers

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
    @State private var cellFrames: [URL: CGRect] = [:]
    @State private var marquee: CGRect?
    @State private var marqueeBase: Set<URL> = []

    private let spacing: CGFloat = 12
    private let padding: CGFloat = 16
    private static let space = "gridContent"

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
                            cell(for: item, size: size)
                        }
                    }
                    .padding(padding)
                    .frame(maxWidth: .infinity, minHeight: geometry.size.height, alignment: .top)
                    // Empty space: click to deselect, drag to draw a selection rectangle.
                    .background {
                        Color.clear
                            .contentShape(Rectangle())
                            .onTapGesture {
                                let flags = NSEvent.modifierFlags
                                if !flags.contains(.command) && !flags.contains(.shift) { model.clearSelection() }
                            }
                            .gesture(marqueeGesture)
                    }
                    .overlay(alignment: .topLeading) { marqueeView }
                    .coordinateSpace(name: Self.space)
                    .onPreferenceChange(CellFramesKey.self) { cellFrames = $0 }
                }
                .onChange(of: columns, initial: true) { model.gridColumns = columns }
                .onChange(of: model.selection) { _, selection in
                    guard let selection, !model.isViewing, marquee == nil else { return }
                    proxy.scrollTo(selection)
                }
                .onChange(of: model.isViewing) { _, isViewing in
                    guard !isViewing, let selection = model.selection else { return }
                    proxy.scrollTo(selection, anchor: .center)
                }
            }
        }
    }

    @ViewBuilder
    private func cell(for item: FileItem, size: CGFloat) -> some View {
        let base = GridCell(item: item, size: size, isSelected: model.selectedURLs.contains(item.url))
            .background(GeometryReader { geometry in
                Color.clear.preference(key: CellFramesKey.self, value: [item.url: geometry.frame(in: .named(Self.space))])
            })
            .id(item.url)
            .onTapGesture(count: 2) { model.activate(item) }
            .simultaneousGesture(TapGesture().onEnded {
                model.click(item, modifiers: NSEvent.modifierFlags)
            })
            .contextMenu { ItemContextMenu(item: item) }

        if item.isDirectory {
            base.folderDropTarget(item.url, cornerRadius: 8)
        } else {
            base.onDrag {
                model.beginDrag(item)
                return NSItemProvider(item: item.url.path as NSString, typeIdentifier: UTType.imageViewerSelection.identifier)
            } preview: {
                DragPreview(item: item, count: model.selectedURLs.contains(item.url) ? max(1, model.selectedImages.count) : 1)
            }
        }
    }

    private var marqueeGesture: some Gesture {
        DragGesture(minimumDistance: 4, coordinateSpace: .named(Self.space))
            .onChanged { value in
                if marquee == nil {
                    let flags = NSEvent.modifierFlags
                    marqueeBase = flags.contains(.command) || flags.contains(.shift) ? model.selectedURLs : []
                }
                let rect = CGRect(
                    x: min(value.startLocation.x, value.location.x),
                    y: min(value.startLocation.y, value.location.y),
                    width: abs(value.location.x - value.startLocation.x),
                    height: abs(value.location.y - value.startLocation.y)
                )
                marquee = rect
                let hits = Set(cellFrames.filter { $0.value.intersects(rect) }.map(\.key))
                let focus = model.gridItems.first { hits.contains($0.url) }?.url
                model.setSelection(marqueeBase.union(hits), focus: focus ?? model.selection)
            }
            .onEnded { _ in marquee = nil }
    }

    @ViewBuilder
    private var marqueeView: some View {
        if let marquee {
            Rectangle()
                .fill(Color.accentColor.opacity(0.15))
                .overlay(Rectangle().strokeBorder(Color.accentColor.opacity(0.8), lineWidth: 1))
                .frame(width: marquee.width, height: marquee.height)
                .offset(x: marquee.minX, y: marquee.minY)
                .allowsHitTesting(false)
        }
    }
}

private struct CellFramesKey: PreferenceKey {
    static let defaultValue: [URL: CGRect] = [:]
    static func reduce(value: inout [URL: CGRect], nextValue: () -> [URL: CGRect]) {
        value.merge(nextValue()) { $1 }
    }
}

/// Thumbnail with a count badge shown under the cursor while dragging.
private struct DragPreview: View {
    let item: FileItem
    let count: Int

    var body: some View {
        ThumbnailView(item: item, size: 90)
            .overlay(alignment: .topTrailing) {
                if count > 1 {
                    Text("\(count)")
                        .font(.caption.bold())
                        .foregroundStyle(.white)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(Color.red, in: Capsule())
                        .offset(x: 6, y: -6)
                }
            }
            .padding(8)
    }
}

/// Makes a view accept images dragged within the app and move them into `destination`.
struct FolderDropTarget: ViewModifier {
    @Environment(BrowserModel.self) private var model
    let destination: URL
    let cornerRadius: CGFloat
    @State private var isTargeted = false

    func body(content: Content) -> some View {
        content
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius)
                    .fill(Color.accentColor.opacity(0.15))
                    .overlay(RoundedRectangle(cornerRadius: cornerRadius).strokeBorder(Color.accentColor, lineWidth: 2))
                    .opacity(isTargeted ? 1 : 0)
                    .allowsHitTesting(false)
            }
            .onDrop(of: [.imageViewerSelection], delegate: Delegate(model: model, destination: destination, isTargeted: $isTargeted))
    }

    private struct Delegate: DropDelegate {
        let model: BrowserModel
        let destination: URL
        @Binding var isTargeted: Bool

        func validateDrop(info: DropInfo) -> Bool {
            model.canDrop(onto: destination)
        }

        func dropEntered(info: DropInfo) {
            isTargeted = model.canDrop(onto: destination)
        }

        func dropExited(info: DropInfo) {
            isTargeted = false
        }

        func dropUpdated(info: DropInfo) -> DropProposal? {
            DropProposal(operation: model.canDrop(onto: destination) ? .move : .forbidden)
        }

        func performDrop(info: DropInfo) -> Bool {
            isTargeted = false
            return model.dropDragged(onto: destination)
        }
    }
}

extension View {
    func folderDropTarget(_ destination: URL, cornerRadius: CGFloat = 6) -> some View {
        modifier(FolderDropTarget(destination: destination, cornerRadius: cornerRadius))
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
        let targets = model.fileActionTargets(for: item)
        if !targets.isEmpty {
            Divider()
            MoveToMenu(title: targets.count == 1 ? "Move to" : "Move \(targets.count) Images to", item: item)
            Button(targets.count == 1 ? "New Folder with This Image…" : "New Folder with \(targets.count) Images…") {
                model.beginNewFolderWithSelection(item)
            }
            Divider()
            Button(targets.count == 1 ? "Move to Trash" : "Move \(targets.count) Images to Trash", role: .destructive) {
                model.moveToTrash(item)
            }
        }
    }
}

/// Submenu listing likely destinations (subfolders, parent, recent) plus "Choose Folder…".
struct MoveToMenu: View {
    @Environment(BrowserModel.self) private var model
    let title: String
    var item: FileItem?

    var body: some View {
        Menu(title) { MoveToMenuItems(item: item) }
    }
}

struct MoveToMenuItems: View {
    @Environment(BrowserModel.self) private var model
    var item: FileItem?

    var body: some View {
        ForEach(model.moveDestinationGroups, id: \.title) { group in
            Section(group.title) {
                ForEach(group.destinations) { destination in
                    Button(destination.title) {
                        model.move(model.fileActionTargets(for: item), to: destination.url)
                    }
                }
            }
        }
        Divider()
        Button("Choose Folder…") { model.showMovePanel(for: item) }
        Button("New Folder with Selection…") { model.beginNewFolderWithSelection(item) }
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
                    .folderDropTarget(component, cornerRadius: 4)
                    .font(.caption)
                    .foregroundStyle(index == components.count - 1 ? .primary : .secondary)
                }
            }
        }
    }
}
