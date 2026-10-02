import SwiftUI

/// Every keyboard shortcut in one place: shown by Help ▸ Keyboard Shortcuts (⌘/).
enum ShortcutCatalog {
    struct Shortcut: Identifiable {
        let keys: String
        let action: String
        var id: String { keys + action }
    }

    struct Section: Identifiable {
        let title: String
        let shortcuts: [Shortcut]
        var id: String { title }
    }

    private static func s(_ keys: String, _ action: String) -> Shortcut { Shortcut(keys: keys, action: action) }

    static let sections: [Section] = [
        Section(title: "Browsing", shortcuts: [
            s("← → ↑ ↓", "Move the selection"),
            s("Return  or  Space", "Open the image or folder"),
            s("⌘↓  /  ⌘↑", "Open selection  /  enclosing folder"),
            s("⌘[  /  ⌘]", "Back  /  forward"),
            s("⌘-click  /  ⇧-click", "Add one  /  add a range to the selection"),
            s("Drag on empty space", "Select with a rectangle"),
            s("⌘A", "Select all"),
            s("Esc", "Keep only the focused item selected"),
            s("⌘=  /  ⌘-", "Bigger  /  smaller thumbnails"),
        ]),
        Section(title: "Viewing an image", shortcuts: [
            s("← →  (or ↑ ↓)", "Previous  /  next"),
            s("Home  /  End", "First  /  last"),
            s("Esc  or  Space", "Back to the grid"),
            s("Space", "Play / pause a video"),
            s("F", "Full screen"),
            s("⌘=  /  ⌘-", "Zoom in  /  out"),
            s("⌘9  /  ⌘0", "Zoom to fit  /  actual pixels"),
            s("Double-click", "Toggle fit and 100%"),
        ]),
        Section(title: "Text in images", shortcuts: [
            s("⌘T", "Recognize text"),
            s("Click, ⌘-click, ⇧-click, drag", "Select lines"),
            s("⌘C  /  double-click", "Copy selected lines  /  copy one line"),
            s("⌘A", "Select all lines"),
            s("Esc", "Hide the text"),
        ]),
        Section(title: "Rating (saved in the file)", shortcuts: [
            s("1 … 5", "Rate the image or the whole selection"),
            s("0  or  ✕", "Clear the rating"),
            s("X", "Reject  /  un-reject"),
        ]),
        Section(title: "Files", shortcuts: [
            s("⌘⌫", "Move to Trash"),
            s("⌘Z  /  ⇧⌘Z", "Undo  /  redo"),
            s("⇧⌘M", "Move to folder…"),
            s("⌃⌘N", "New folder with selection…"),
            s("⌘L  /  ⌘R", "Rotate left  /  right"),
            s("⇧⌘A", "Adjust color  (⌘S saves)"),
            s("⇧⌘L", "Set location…"),
            s("⇧⌘R", "Batch rename…"),
            s("⌘E", "Export…"),
            s("⌥⌘D", "Find duplicates…"),
            s("⇧⌘C  /  ⌥⌘C", "Copy image  /  copy path"),
            s("⌥⌘R", "Reveal in Finder"),
            s("⇧⌘O", "Open in Preview"),
        ]),
        Section(title: "App", shortcuts: [
            s("⌘O", "Open a folder or image"),
            s("⇧⌘G", "Go to folder by typing a path"),
            s("⌘I", "Inspector (details, histogram, map)"),
            s("⌥⌘F", "Filmstrip on / off"),
            s("⌘1  /  ⌘2", "Grid  /  world map"),
            s("⌥⌘S", "Show all subfolders (flatten)"),
            s("⇧⌘.", "Show hidden files"),
            s("⌘,", "Settings"),
            s("⌘/", "This list"),
        ]),
    ]
}

struct ShortcutsView: View {
    private let columns = [GridItem(.flexible(), alignment: .topLeading), GridItem(.flexible(), alignment: .topLeading)]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, alignment: .leading, spacing: 24) {
                ForEach(ShortcutCatalog.sections) { section in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(section.title)
                            .font(.headline)
                        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 14, verticalSpacing: 6) {
                            ForEach(section.shortcuts) { shortcut in
                                GridRow {
                                    Text(shortcut.keys)
                                        .font(.callout.weight(.medium))
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 5))
                                        .gridColumnAlignment(.trailing)
                                    Text(shortcut.action)
                                        .font(.callout)
                                }
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(24)
        }
        .frame(minWidth: 760, minHeight: 520)
    }
}
