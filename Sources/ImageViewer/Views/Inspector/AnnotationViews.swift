import SwiftUI

/// Tags for the inspected file, or for every selected file: tags on only some of them show how
/// many. Typing a comma or Return adds a tag; tags used elsewhere in the folder are suggested.
struct TagEditor: View {
    @Environment(BrowserModel.self) private var model
    let items: [FileItem]
    @State private var draft = ""
    @FocusState private var isTyping: Bool

    /// Each tag once, in the order it first appears, with how many of the items have it.
    private var tagCounts: [(tag: String, count: Int)] {
        var result: [(tag: String, count: Int)] = []
        for item in items {
            for tag in model.annotations(for: item).tags {
                if let index = result.firstIndex(where: { $0.tag.caseInsensitiveCompare(tag) == .orderedSame }) {
                    result[index].count += 1
                } else {
                    result.append((tag, 1))
                }
            }
        }
        return result
    }

    private var suggestions: [String] {
        let onAll = Set(tagCounts.filter { $0.count == items.count }.map { $0.tag.lowercased() })
        let typed = Annotations.cleanTag(draft)
        return model.knownTags
            .filter { !onAll.contains($0.lowercased()) && (typed.isEmpty || $0.localizedCaseInsensitiveContains(typed)) }
            .prefix(8)
            .map { $0 }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            FlowLayout(spacing: 5) {
                ForEach(tagCounts, id: \.tag) { entry in
                    chip(entry.tag, count: entry.count)
                }
                TextField(tagCounts.isEmpty ? "Add tags…" : "Add…", text: $draft)
                    .textFieldStyle(.plain)
                    .font(.callout)
                    .frame(minWidth: 70)
                    .focused($isTyping)
                    .onSubmit(add)
                    .onChange(of: draft) {
                        if draft.contains(",") { add() }
                    }
            }
            .padding(6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(.quaternary))
            .contentShape(Rectangle())
            .onTapGesture { isTyping = true }

            if isTyping && !suggestions.isEmpty {
                FlowLayout(spacing: 5) {
                    ForEach(suggestions, id: \.self) { tag in
                        Button {
                            model.addTags(tag, to: items)
                            draft = ""
                        } label: {
                            Label(tag, systemImage: "plus")
                                .font(.caption)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 3)
                                .background(.quaternary, in: Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private func chip(_ tag: String, count: Int) -> some View {
        let onAll = count == items.count
        return HStack(spacing: 3) {
            Text(tag)
            if !onAll {
                Text("\(count)/\(items.count)")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Button {
                model.removeTag(tag, from: items)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 14, height: 14)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(items.count > 1 ? "Remove “\(tag)” from the selected items" : "Remove “\(tag)”")
        }
        .font(.callout)
        .padding(.leading, 8)
        .padding(.trailing, 3)
        .padding(.vertical, 2)
        .background(Color.accentColor.opacity(onAll ? 0.18 : 0.07), in: Capsule())
        .help(onAll ? tag : "On \(count) of the \(items.count) selected items. Type it again to add it to all.")
    }

    private func add() {
        model.addTags(draft, to: items)
        draft = ""
    }
}

/// A paragraph about the photo. Saved into the file a moment after you stop typing, and when you
/// click elsewhere or move to another photo.
struct NoteEditor: View {
    @Environment(BrowserModel.self) private var model
    let item: FileItem
    @State private var text = ""
    @State private var saved = ""
    @State private var saveTask: Task<Void, Never>?
    @FocusState private var isEditing: Bool

    private var storedNote: String { model.annotations(for: item).note }

    var body: some View {
        TextEditor(text: $text)
            .font(.callout)
            .scrollContentBackground(.hidden)
            .focused($isEditing)
            .padding(.horizontal, 3)
            .padding(.vertical, 5)
            .frame(minHeight: 64, maxHeight: 180)
            .fixedSize(horizontal: false, vertical: true)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(.quaternary))
            .overlay(alignment: .topLeading) {
                if text.isEmpty {
                    Text("Add a note…")
                        .font(.callout)
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .allowsHitTesting(false)
                }
            }
            .onAppear {
                text = storedNote
                saved = storedNote
            }
            // Loaded late, or changed by Undo: show it unless you're in the middle of typing.
            .onChange(of: storedNote) {
                if !isEditing || text == saved {
                    text = storedNote
                    saved = storedNote
                }
            }
            .onChange(of: text) {
                saveTask?.cancel()
                saveTask = Task {
                    try? await Task.sleep(for: .seconds(1.5))
                    if !Task.isCancelled { commit() }
                }
            }
            .onChange(of: isEditing) { if !isEditing { commit() } }
            .onDisappear { commit() }
    }

    private func commit() {
        saveTask?.cancel()
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed != saved.trimmingCharacters(in: .whitespacesAndNewlines) else { return }
        saved = text
        model.setNote(trimmed, for: item)
    }
}

/// Lays its children out left to right, wrapping onto new lines like text.
struct FlowLayout: Layout {
    var spacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(subviews, width: proposal.width ?? .infinity)
        return CGSize(
            width: proposal.width ?? rows.map(\.width).max() ?? 0,
            height: rows.last.map { $0.y + $0.height } ?? 0
        )
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for row in arrange(subviews, width: bounds.width) {
            for (index, x, size) in row.items {
                subviews[index].place(
                    at: CGPoint(x: bounds.minX + x, y: bounds.minY + row.y + (row.height - size.height) / 2),
                    proposal: ProposedViewSize(size)
                )
            }
        }
    }

    private struct Row {
        var y: CGFloat
        var width: CGFloat = 0
        var height: CGFloat = 0
        var items: [(Int, CGFloat, CGSize)] = []
    }

    private func arrange(_ subviews: Subviews, width: CGFloat) -> [Row] {
        var rows = [Row(y: 0)]
        for index in subviews.indices {
            var size = subviews[index].sizeThatFits(.unspecified)
            size.width = min(size.width, width)
            if rows[rows.count - 1].width + size.width > width, !rows[rows.count - 1].items.isEmpty {
                let last = rows[rows.count - 1]
                rows.append(Row(y: last.y + last.height + spacing))
            }
            var row = rows[rows.count - 1]
            let x = row.items.isEmpty ? 0 : row.width + spacing
            row.items.append((index, x, size))
            row.width = x + size.width
            row.height = max(row.height, size.height)
            rows[rows.count - 1] = row
        }
        return rows
    }
}
