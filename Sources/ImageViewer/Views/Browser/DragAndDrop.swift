import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Thumbnail with a count badge shown under the cursor while dragging.
struct DragPreview: View {
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

struct AutoScrollDropDelegate: DropDelegate {
    let scroller: AutoScroller

    func validateDrop(info: DropInfo) -> Bool { true }
    func dropEntered(info: DropInfo) { scroller.start() }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        scroller.start()
        return DropProposal(operation: .forbidden) // empty grid space isn't a destination
    }

    func dropExited(info: DropInfo) { scroller.stop() }

    func performDrop(info: DropInfo) -> Bool {
        scroller.stop()
        return false
    }
}
