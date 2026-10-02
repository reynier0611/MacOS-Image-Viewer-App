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
            } else if model.gridItems.isEmpty && model.isFiltering {
                ContentUnavailableView {
                    Label("No Matches", systemImage: "magnifyingglass")
                } description: {
                    Text(model.isAnalyzingContent ? "Still recognizing photo contents (\(model.contentAnalysisDone) of \(model.contentAnalysisTotal))…" : "Nothing here matches the search and filters.")
                } actions: {
                    Button("Clear Search and Filters") { model.clearFilters() }
                }
            } else if model.gridItems.isEmpty && model.isLoadingFolder, let found = model.scanFoundCount {
                VStack(spacing: 10) {
                    ProgressView()
                    Text("Finding photos and videos in all subfolders…")
                    Text("\(found) found so far")
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            } else if model.gridItems.isEmpty && !model.isLoadingFolder {
                ContentUnavailableView(
                    "No Images", systemImage: "photo",
                    description: Text(model.showsAllSubfolders ? "There are no images or videos in this folder or its subfolders." : "This folder has no images or subfolders.")
                )
            } else {
                ThumbnailGrid()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .safeAreaInset(edge: .top, spacing: 0) {
            if model.isFiltering {
                FilterStatusBar()
                    .padding(.top, 8)
                    .padding(.bottom, 4)
            }
        }
        // A floating glass capsule; thumbnails scroll underneath it.
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if let folder = model.folder {
                PathBar(url: folder) { model.navigate(to: $0) }
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .glassSurface(in: Capsule())
                    .padding(.horizontal, 16)
                    .padding(.bottom, 12)
                    .frame(maxWidth: .infinity, alignment: .leading)
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
        ViewThatFits(in: .horizontal) {
            crumbs
            ScrollView(.horizontal, showsIndicators: false) { crumbs }
        }
    }

    private var crumbs: some View {
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
