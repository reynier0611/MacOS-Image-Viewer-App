import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct GridCell: View {
    let item: FileItem
    let size: CGFloat
    let isSelected: Bool
    var rating = 0
    /// Which subfolder the file is in, when showing all subfolders ("" = the folder itself).
    var location: String?

    var body: some View {
        VStack(spacing: 5) {
            // Only the picture itself (and the name below) responds to clicks; the rest of the
            // square, and the gaps between cells, are empty space for starting a selection rectangle.
            if item.isDirectory {
                Image(nsImage: NSWorkspace.shared.icon(forFile: item.url.path))
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: size * 0.75, height: size * 0.75)
                    .background { SelectionHighlight(isSelected: isSelected) }
                    .frame(width: size, height: size)
            } else {
                ThumbnailView(item: item, size: size, isSelected: isSelected, rating: rating)
            }

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
                .frame(width: size + 8)
            if let location {
                // Always one line (blank for the top folder) so rows keep the same height.
                Label(location.isEmpty ? " " : location, systemImage: "folder")
                    .labelStyle(.titleAndIcon)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
                    .opacity(location.isEmpty ? 0 : 1)
                    .frame(width: size + 8)
                    .allowsHitTesting(false)
            }
        }
        .help(location.map { $0.isEmpty ? item.name : "\($0)/\(item.name)" } ?? item.name)
    }
}

/// The grid's selection highlight: a soft rounded backdrop that hugs the picture itself.
struct SelectionHighlight: View {
    let isSelected: Bool

    var body: some View {
        RoundedRectangle(cornerRadius: 7)
            .fill(isSelected ? Color.secondary.opacity(0.25) : .clear)
            .padding(-5)
            .allowsHitTesting(false)
    }
}

struct ThumbnailView: View {
    let item: FileItem
    let size: CGFloat
    var isSelected = false
    var rating = 0
    @State private var image: NSImage?

    init(item: FileItem, size: CGFloat, isSelected: Bool = false, rating: Int = 0) {
        self.item = item
        self.size = size
        self.isSelected = isSelected
        self.rating = rating
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
                    .overlay(alignment: .bottomLeading) {
                        if item.isVideo {
                            Image(systemName: "play.fill")
                                .font(.system(size: max(7, size * 0.08)))
                                .foregroundStyle(.white)
                                .padding(max(4, size * 0.04))
                                .background(.black.opacity(0.5), in: Circle())
                                .padding(max(3, size * 0.03))
                        }
                    }
                    // A hairline edge rather than a drop shadow: crisper, and a shadow per thumbnail
                    // is one of the costlier things to draw while scrolling.
                    .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(.black.opacity(0.15), lineWidth: 0.5))
                    .opacity(rating == Ratings.rejected ? 0.4 : 1) // rejects fade back, like Lightroom
                    .overlay(alignment: .bottom) {
                        RatingBadge(rating: rating)
                            .padding(.bottom, 4)
                            .allowsHitTesting(false)
                    }
                    .background { SelectionHighlight(isSelected: isSelected) }
            } else {
                RoundedRectangle(cornerRadius: 4)
                    .fill(.quaternary)
                    .frame(width: size * 0.8, height: size * 0.6)
                    .background { SelectionHighlight(isSelected: isSelected) }
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
            Button(item.isVideo ? "Open in QuickTime Player" : "Open in Preview") { model.openInPreview(item) }
            Button("Open with Default App") { model.openWithDefaultApp(item) }
        }
        Button("Reveal in Finder") { model.revealInFinder(item) }
        Divider()
        if !item.isDirectory {
            Button("Copy Image") { model.copyImage(item) }
        }
        Button("Copy Path") { model.copyPath(item) }
        if !item.isDirectory {
            let targets = model.fileActionTargets(for: item).filter { !$0.isDirectory }
            Menu(targets.count > 1 ? "Rate \(targets.count) Images" : "Rating") {
                RatingMenuItems(items: targets)
            }
            let placeable = targets.filter(ImageLocation.canStore)
            if !placeable.isEmpty {
                Button(placeable.count > 1 ? "Set Location of \(placeable.count) Photos…" : "Set Location…") {
                    model.showLocationPicker(for: placeable)
                }
            }
        }
        ShareLink(item: item.url)
        Divider()
        Button("Rename…") { model.beginRename(item) }
        let targets = model.fileActionTargets(for: item)
        if !targets.isEmpty {
            Divider()
            MoveToMenu(title: targets.count == 1 ? "Move to" : "Move \(targets.count) Images to", item: item)
            Button(targets.count == 1 ? "New Folder with This Image…" : "New Folder with \(targets.count) Images…") {
                model.beginNewFolderWithSelection(item)
            }
        }
        let trashTargets = model.trashTargets(for: item)
        if !trashTargets.isEmpty {
            Divider()
            Button(trashTargets.count == 1 ? "Move to Trash" : "Move \(trashTargets.count) Items to Trash", role: .destructive) {
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
