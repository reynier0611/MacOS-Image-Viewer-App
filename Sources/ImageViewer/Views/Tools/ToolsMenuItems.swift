import AppKit
import SwiftUI

struct ToolsMenuItems: View {
    @Environment(BrowserModel.self) private var model

    var body: some View {
        let photos = model.batchTargets.filter { !$0.isVideo }.count
        Section(photos > 1 ? "\(photos) Images" : "Image") {
            Button("Rotate Left") { model.changeOrientation(.rotateLeft) }
            Button("Rotate Right") { model.changeOrientation(.rotateRight) }
            Button("Flip Horizontal") { model.changeOrientation(.flipHorizontal) }
            Button("Flip Vertical") { model.changeOrientation(.flipVertical) }
        }
        .disabled(photos == 0)
        Divider()
        Button("Batch Rename…") { model.isBatchRenamePresented = true }
            .disabled(model.batchTargets.isEmpty)
        Button("Export…") { model.isExportPresented = true }
            .disabled(photos == 0)
        Divider()
        Button("Find Duplicates…") { model.isDuplicatesPresented = true }
            .disabled(model.allImages.count < 2)
    }
}

// MARK: - Batch rename
