import AppKit
import SwiftUI

struct AppCommands: Commands {
    @Bindable var model: BrowserModel
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .help) {
            Button("Keyboard Shortcuts") { openWindow(id: "shortcuts") }
                .keyboardShortcut("/")
        }

        CommandGroup(replacing: .appInfo) {
            Button("About Image Viewer") { Self.showAboutPanel() }
        }

        CommandGroup(replacing: .newItem) {
            Button("Open…") { model.showOpenPanel() }
                .keyboardShortcut("o")
            Button("Go to Folder…") { model.presentGoToFolder() }
                .keyboardShortcut("g", modifiers: [.command, .shift])
        }

        CommandGroup(after: .newItem) {
            Divider()
            Button("Open in Preview") { model.openInPreview() }
                .keyboardShortcut("o", modifiers: [.command, .shift])
            Button("Open with Default App") { model.openWithDefaultApp() }
            Button("Reveal in Finder") { model.revealInFinder() }
                .keyboardShortcut("r", modifiers: [.command, .option])
            Divider()
            Button("Move to Folder…") { model.showMovePanel() }
                .keyboardShortcut("m", modifiers: [.command, .shift])
            Button("New Folder with Selection…") { model.beginNewFolderWithSelection() }
                .keyboardShortcut("n", modifiers: [.command, .control])
            Button("Rename…") { model.beginRename() }
            Button("Move to Trash") { model.moveToTrash() }
                .keyboardShortcut(.delete)
        }

        CommandGroup(after: .pasteboard) {
            Divider()
            Button("Copy Image") { model.copyImage() }
                .keyboardShortcut("c", modifiers: [.command, .shift])
            Button("Copy Path") { model.copyPath() }
                .keyboardShortcut("c", modifiers: [.command, .option])
        }

        CommandGroup(after: .toolbar) {
            Toggle("Show Inspector", isOn: $model.showInspector)
                .keyboardShortcut("i")
            Toggle("Show Filmstrip", isOn: $model.showFilmstrip)
                .keyboardShortcut("f", modifiers: [.command, .option])
            Divider()
            Button("Zoom In") { model.zoom(.zoomIn) }
                .keyboardShortcut("=")
            Button("Zoom Out") { model.zoom(.zoomOut) }
                .keyboardShortcut("-")
            Button("Zoom to Fit") { model.zoom(.fit) }
                .keyboardShortcut("9")
            Button("Actual Size") { model.zoom(.actualSize) }
                .keyboardShortcut("0")
            Toggle("Enlarge Small Images to Fit", isOn: $model.enlargeSmallImages)
            Divider()
            Picker("Sort By", selection: $model.sortKey) {
                ForEach(SortKey.allCases) { Text($0.rawValue).tag($0) }
            }
            Toggle("Sort Ascending", isOn: $model.sortAscending)
            Picker("View", selection: $model.browseLayout) {
                Text("as Grid").tag(BrowseLayout.grid).keyboardShortcut("1")
                Text("as Map").tag(BrowseLayout.map).keyboardShortcut("2")
            }
            .pickerStyle(.inline)
            Toggle("Show All Subfolders", isOn: $model.showsAllSubfolders)
                .keyboardShortcut("s", modifiers: [.command, .option])
            Toggle("Show Hidden Files", isOn: $model.showHidden)
                .keyboardShortcut(".", modifiers: [.command, .shift])
            Divider()
        }

        CommandMenu("Image") {
            Menu("Rating") {
                RatingMenuItems()
                    .environment(model)
            }
            Divider()
            Toggle("Recognize Text", isOn: Binding(
                get: { model.isTextRecognitionOn },
                set: { _ in model.toggleTextRecognition() }
            ))
            .keyboardShortcut("t")
            Toggle("Adjust Color…", isOn: Binding(
                get: { model.isAdjusting },
                set: { _ in model.toggleAdjusting() }
            ))
            .keyboardShortcut("a", modifiers: [.command, .shift])
            Button("Set Location…") { model.showLocationPicker() }
                .keyboardShortcut("l", modifiers: [.command, .shift])
            Divider()
            Button("Rotate Left") { model.changeOrientation(.rotateLeft) }
                .keyboardShortcut("l")
            Button("Rotate Right") { model.changeOrientation(.rotateRight) }
                .keyboardShortcut("r")
            Button("Flip Horizontal") { model.changeOrientation(.flipHorizontal) }
            Button("Flip Vertical") { model.changeOrientation(.flipVertical) }
            Divider()
            Button("Batch Rename…") { model.isBatchRenamePresented = true }
                .keyboardShortcut("r", modifiers: [.command, .shift])
            Button("Export…") { model.isExportPresented = true }
                .keyboardShortcut("e")
            Divider()
            Button("Find Duplicates…") { model.isDuplicatesPresented = true }
                .keyboardShortcut("d", modifiers: [.command, .option])
            Divider()
            Button("Clear Search and Filters") { model.clearFilters() }
        }

        CommandMenu("Go") {
            Button("Back") { model.goBack() }
                .keyboardShortcut("[")
            Button("Forward") { model.goForward() }
                .keyboardShortcut("]")
            Button("Enclosing Folder") { model.goToEnclosingFolder() }
                .keyboardShortcut(.upArrow)
            Button("Open Selection") { model.openSelection() }
                .keyboardShortcut(.downArrow)
            Divider()
            // Plain arrow keys are handled directly (see BrowserModel.handleKey) so they
            // don't hijack text fields; these items are here for discoverability.
            Button("Next Image  (→)") { model.step(1) }
            Button("Previous Image  (←)") { model.step(-1) }
            Button("Close Image  (Esc)") { model.closeViewer() }
            Divider()
            Button("Home") { model.goHome() }
                .keyboardShortcut("h", modifiers: [.command, .shift])
            Button("Desktop") { model.goToStandardFolder(.desktopDirectory) }
                .keyboardShortcut("d", modifiers: [.command, .shift])
            Button("Downloads") { model.goToStandardFolder(.downloadsDirectory) }
                .keyboardShortcut("l", modifiers: [.command, .option])
            Button("Pictures") { model.goToStandardFolder(.picturesDirectory) }
                .keyboardShortcut("p", modifiers: [.command, .shift])
        }
    }

    private static func showAboutPanel() {
        let centered = NSMutableParagraphStyle()
        centered.alignment = .center
        let credits = NSMutableAttributedString(
            string: "Created by\n",
            attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: centered]
        )
        credits.append(NSAttributedString(
            string: "Rey Cruz Torres, PhD",
            attributes: [.font: NSFont.boldSystemFont(ofSize: 12), .foregroundColor: NSColor.labelColor, .paragraphStyle: centered]
        ))
        NSApp.orderFrontStandardAboutPanel(options: [.credits: credits])
        NSApp.activate()
    }
}
