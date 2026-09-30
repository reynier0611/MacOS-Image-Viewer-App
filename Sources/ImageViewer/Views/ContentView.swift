import SwiftUI

struct ContentView: View {
    @Environment(BrowserModel.self) private var model
    @Environment(\.undoManager) private var undoManager

    var body: some View {
        @Bindable var model = model

        NavigationSplitView(columnVisibility: $model.columnVisibility) {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 170, ideal: 210, max: 320)
        } detail: {
            DetailView()
                .inspector(isPresented: $model.showInspector) {
                    InspectorView()
                        .inspectorColumnWidth(min: 240, ideal: 290, max: 440)
                }
        }
        .navigationTitle(title)
        .navigationSubtitle(subtitle)
        .toolbar { MainToolbar(model: model) }
        .searchable(text: $model.searchText, placement: .toolbar, prompt: "Name or contents, e.g. beach")
        .sheet(isPresented: $model.isDuplicatesPresented) { DuplicatesView() }
        .sheet(isPresented: $model.isBatchRenamePresented) { BatchRenameView() }
        .sheet(isPresented: $model.isExportPresented) { ExportView() }
        .overlay(alignment: .bottom) { toastView }
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first else { return false }
            model.open(url)
            return true
        }
        .alert("Rename", isPresented: $model.isRenamePresented) {
            TextField("Name", text: $model.renameText)
            Button("Rename") { model.commitRename() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(model.isRenamingFolder ? "Rename this folder." : "The file extension is kept.")
        }
        .alert("New Folder with Selection", isPresented: $model.isNewFolderPresented) {
            TextField("Folder name", text: $model.newFolderName)
            Button("Create") { model.commitNewFolder() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Creates a folder here and moves \(model.newFolderItemCount == 1 ? "the image" : "the \(model.newFolderItemCount) images") into it.")
        }
        .alert("Go to Folder", isPresented: $model.isGoToFolderPresented) {
            TextField("Path", text: $model.goToFolderText)
            Button("Go") { model.goToFolder(path: model.goToFolderText) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Type a folder or image path, e.g. ~/Pictures")
        }
        .alert(
            "Something went wrong",
            isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })
        ) {
            Button("OK") {}
        } message: {
            Text(model.errorMessage ?? "")
        }
        .onAppear {
            model.undoManager = undoManager
            model.start()
        }
        .onChange(of: undoManager) { model.undoManager = undoManager }
    }

    private var title: String {
        model.currentItem?.name ?? model.folderDisplayName
    }

    private var subtitle: String {
        if let index = model.viewerIndex {
            return "\(index + 1) of \(model.images.count)"
        }
        guard model.folder != nil else { return "" }
        if model.isFiltering {
            return "Showing \(model.images.count) of \(model.allImages.count)"
        }
        let videoCount = model.images.filter(\.isVideo).count
        let imageCount = model.images.count - videoCount
        var parts = ["\(imageCount) image\(imageCount == 1 ? "" : "s")"]
        if videoCount > 0 {
            parts.append("\(videoCount) video\(videoCount == 1 ? "" : "s")")
        }
        if !model.folders.isEmpty {
            parts.append("\(model.folders.count) folder\(model.folders.count == 1 ? "" : "s")")
        }
        if model.selectedURLs.count > 1 {
            parts.append("\(model.selectedURLs.count) selected")
        }
        return parts.joined(separator: ", ")
    }

    @ViewBuilder
    private var toastView: some View {
        if let toast = model.toast {
            HStack(spacing: 12) {
                Text(toast.message)
                    .lineLimit(1)
                if toast.canUndo {
                    Button("Undo") {
                        model.toast = nil
                        model.undoManager?.undo()
                    }
                    .buttonStyle(.borderless)
                    .fontWeight(.semibold)
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 10)
            .glassSurface(in: Capsule())
            .padding(.bottom, model.isViewing && model.showFilmstrip ? 124 : 60)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }
}

struct DetailView: View {
    @Environment(BrowserModel.self) private var model

    var body: some View {
        ZStack {
            // The grid stays alive under the viewer so closing an image returns instantly to the same spot.
            BrowserView()
                .opacity(model.isViewing ? 0 : 1)
                .allowsHitTesting(!model.isViewing)
                .accessibilityHidden(model.isViewing)
            if model.isViewing {
                ViewerView()
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.15), value: model.isViewing)
    }
}

struct MainToolbar: ToolbarContent {
    @Bindable var model: BrowserModel

    var body: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            if model.isViewing {
                Button { model.closeViewer() } label: {
                    Label("All Images", systemImage: "square.grid.2x2")
                }
                .help("Back to thumbnails (Esc)")
            } else {
                ControlGroup {
                    Button { model.goBack() } label: { Label("Back", systemImage: "chevron.left") }
                        .disabled(!model.canGoBack)
                        .help("Back (⌘[)")
                    Button { model.goForward() } label: { Label("Forward", systemImage: "chevron.right") }
                        .disabled(!model.canGoForward)
                        .help("Forward (⌘])")
                }
                Button { model.goToEnclosingFolder() } label: {
                    Label("Enclosing Folder", systemImage: "arrow.turn.left.up")
                }
                .disabled(!model.canGoUp)
                .help("Enclosing folder (⌘↑)")
            }
        }

        ToolbarItemGroup(placement: .primaryAction) {
            if model.isViewing {
                ControlGroup {
                    Button { model.step(-1) } label: { Label("Previous", systemImage: "chevron.backward") }
                        .disabled((model.viewerIndex ?? 0) == 0)
                        .help("Previous image (←)")
                    Button { model.step(1) } label: { Label("Next", systemImage: "chevron.forward") }
                        .disabled((model.viewerIndex ?? 0) >= model.images.count - 1)
                        .help("Next image (→)")
                }
                ControlGroup {
                    Button { model.zoom(.zoomOut) } label: { Label("Zoom Out", systemImage: "minus.magnifyingglass") }
                        .help("Zoom out (⌘-)")
                    Button { model.zoom(.fit) } label: { Label("Fit", systemImage: "arrow.up.left.and.down.right.magnifyingglass") }
                        .help("Zoom to fit (⌘9)")
                    Button { model.zoom(.zoomIn) } label: { Label("Zoom In", systemImage: "plus.magnifyingglass") }
                        .help("Zoom in (⌘=)")
                }
                if model.currentItem?.isVideo == false {
                    Toggle(isOn: Binding(get: { model.isTextRecognitionOn }, set: { model.isTextRecognitionOn = $0 })) {
                        Label("Text", systemImage: "text.viewfinder")
                    }
                    .help("Find and select text in the image (⌘T)")
                    ControlGroup {
                        Button { model.changeOrientation(.rotateLeft) } label: { Label("Rotate Left", systemImage: "rotate.left") }
                            .help("Rotate left (⌘L)")
                        Button { model.changeOrientation(.rotateRight) } label: { Label("Rotate Right", systemImage: "rotate.right") }
                            .help("Rotate right (⌘R)")
                    }
                }
                Button { model.toggleFullScreen() } label: {
                    Label("Full Screen", systemImage: "arrow.up.left.and.arrow.down.right")
                }
                .help("Full screen (F)")
                if let item = model.currentItem {
                    ShareLink(item: item.url)
                        .help("Share (AirDrop, Messages, …)")
                }
                Button(role: .destructive) { model.moveToTrash() } label: {
                    Label("Move to Trash", systemImage: "trash")
                }
                .help("Move to Trash (⌘⌫)")
            } else {
                Menu {
                    Picker("Sort By", selection: $model.sortKey) {
                        ForEach(SortKey.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.inline)
                    Divider()
                    Toggle("Ascending", isOn: $model.sortAscending)
                } label: {
                    Label("Sort", systemImage: "arrow.up.arrow.down")
                }
                .help("Sort images")
                Slider(value: $model.thumbnailSize, in: 80...400) {
                    Label("Thumbnail Size", systemImage: "photo")
                }
                .frame(width: 110)
                .help("Thumbnail size (⌘- / ⌘=)")
                FilterButton()
                Menu {
                    MoveToMenuItems()
                } label: {
                    Label("Move to Folder", systemImage: "arrowshape.turn.up.right")
                }
                .disabled(model.selectedImages.isEmpty)
                .help("Move selected images to another folder (⇧⌘M). You can also drag them onto a folder.")
                Button(role: .destructive) { model.moveToTrash() } label: {
                    Label("Move to Trash", systemImage: "trash")
                }
                .disabled(model.selectedImages.isEmpty)
                .help("Move selected images to Trash (⌘⌫). ⌘-click or ⇧-click to select several.")
            }
            Menu {
                ToolsMenuItems()
            } label: {
                Label("Tools", systemImage: "wand.and.stars")
            }
            .help("Rotate, rename, export, find duplicates")
            Toggle(isOn: $model.showInspector) {
                Label("Inspector", systemImage: "info.circle")
            }
            .help("Show metadata (⌘I)")
        }
    }
}
