import AppKit
import SwiftUI

struct DuplicatesView: View {
    @Environment(BrowserModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var includeSimilar = true
    @State private var sensitivity: SimilaritySensitivity = .normal
    @State private var groups: [DuplicateGroup] = []
    @State private var keepers: [UUID: URL] = [:]
    @State private var details: [URL: String] = [:]
    @State private var marked: Set<URL> = []
    @State private var isScanning = false
    @State private var hasScanned = false
    @State private var progress = 0.0
    @State private var status = ""
    @State private var scanTask: Task<Void, Never>?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            footer
        }
        .frame(width: 820, height: 600)
        .task { scan() }
        .onDisappear { scanTask?.cancel() }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Find Duplicates")
                    .font(.title3.bold())
                Text("\(model.allImages.count) items in “\(model.folderDisplayName)”. Everything is analyzed on this Mac.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Toggle("Include similar images", isOn: $includeSimilar)
            Picker("Sensitivity", selection: $sensitivity) {
                ForEach(SimilaritySensitivity.allCases) { Text($0.rawValue).tag($0) }
            }
            .labelsHidden()
            .frame(width: 100)
            .disabled(!includeSimilar)
            .help(sensitivity.explanation)
            Button("Scan Again") { scan() }
                .disabled(isScanning)
        }
        .padding(16)
    }

    @ViewBuilder
    private var content: some View {
        if isScanning {
            ProgressView(value: progress) {
                Text(status)
            }
            .frame(width: 360)
        } else if hasScanned && groups.isEmpty {
            ContentUnavailableView(
                "No Duplicates Found",
                systemImage: "checkmark.circle",
                description: Text(includeSimilar ? "Try the Loose sensitivity to catch more variations." : "No identical copies in this folder.")
            )
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    ForEach(groups) { group in
                        groupRow(group)
                    }
                }
                .padding(16)
            }
        }
    }

    private func groupRow(_ group: DuplicateGroup) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(
                    group.kind == .identical ? "Identical copies" : "Similar images",
                    systemImage: group.kind == .identical ? "doc.on.doc" : "square.on.square"
                )
                .font(.headline)
                Text("\(group.items.count) files")
                    .foregroundStyle(.secondary)
                Spacer()
                if group.kind == .similar {
                    Button("Mark All but Best") {
                        for item in group.items where item.url != keepers[group.id] { marked.insert(item.url) }
                    }
                    .controlSize(.small)
                }
            }
            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: 14) {
                    ForEach(group.items) { item in
                        card(item, isKeeper: keepers[group.id] == item.url)
                    }
                }
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 12))
    }

    private func card(_ item: FileItem, isKeeper: Bool) -> some View {
        let isMarked = marked.contains(item.url)
        return VStack(alignment: .leading, spacing: 4) {
            ThumbnailView(item: item, size: 130)
                .opacity(isMarked ? 0.45 : 1)
                .overlay(alignment: .topTrailing) {
                    if isMarked {
                        Image(systemName: "trash.circle.fill")
                            .font(.title)
                            .foregroundStyle(.white, .red)
                    }
                }
            Text(item.name)
                .font(.caption)
                .lineLimit(1)
                .truncationMode(.middle)
            Text(details[item.url] ?? "")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            if isKeeper {
                Label("Best copy", systemImage: "star.fill")
                    .font(.caption2.bold())
                    .foregroundStyle(.green)
            }
            Toggle("Move to Trash", isOn: Binding(
                get: { marked.contains(item.url) },
                set: { if $0 { marked.insert(item.url) } else { marked.remove(item.url) } }
            ))
            .toggleStyle(.checkbox)
            .font(.caption)
        }
        .frame(width: 140)
        .contentShape(Rectangle())
        .contextMenu {
            Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([item.url]) }
            Button("Open in Preview") { model.openInPreview(item) }
        }
    }

    /// Identical groups where every copy is marked would lose the photo entirely.
    private var wouldRemoveAllCopies: Bool {
        groups.contains { $0.kind == .identical && $0.items.allSatisfy { marked.contains($0.url) } }
    }

    private var footer: some View {
        HStack {
            if wouldRemoveAllCopies {
                Label("Keep at least one of each set of identical copies.", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
            } else {
                Text(marked.isEmpty ? "Identical extra copies are pre-marked. Similar images are only marked if you choose." : "\(marked.count) marked for the Trash (you can undo with ⌘Z).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Close") { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button("Move \(marked.count) to Trash", role: .destructive) { trashMarked() }
                .keyboardShortcut(.defaultAction)
                .disabled(marked.isEmpty || wouldRemoveAllCopies)
        }
        .padding(16)
    }

    private func scan() {
        scanTask?.cancel()
        isScanning = true
        progress = 0
        status = "Starting…"
        let items = model.allImages
        let includeSimilar = includeSimilar
        let sensitivity = sensitivity
        scanTask = Task {
            let found = await DuplicateFinder.findGroups(in: items, includeSimilar: includeSimilar, sensitivity: sensitivity) { value, message in
                Task { @MainActor in
                    progress = value
                    status = message
                }
            }
            guard !Task.isCancelled else { return }
            let (keepers, details) = await Task.detached { Self.describe(found) }.value
            groups = found
            self.keepers = keepers
            self.details = details
            // Pre-mark only exact extra copies; similar photos may be different shots.
            marked = Set(found.filter { $0.kind == .identical }.flatMap { group in
                group.items.map(\.url).filter { $0 != keepers[group.id] }
            })
            isScanning = false
            hasScanned = true
        }
    }

    private nonisolated static func describe(_ groups: [DuplicateGroup]) -> ([UUID: URL], [URL: String]) {
        var keepers: [UUID: URL] = [:]
        var details: [URL: String] = [:]
        for group in groups {
            keepers[group.id] = DuplicateFinder.suggestedKeeper(in: group.items)?.url
            for item in group.items {
                var parts: [String] = []
                if let size = ImageLoader.pixelSize(of: item.url) {
                    parts.append("\(Int(size.width))×\(Int(size.height))")
                }
                parts.append(ByteCountFormatter.string(fromByteCount: item.size, countStyle: .file))
                parts.append(item.modified.formatted(date: .abbreviated, time: .omitted))
                details[item.url] = parts.joined(separator: " · ")
            }
        }
        return (keepers, details)
    }

    private func trashMarked() {
        let items = groups.flatMap(\.items).filter { marked.contains($0.url) }
        var seen: Set<URL> = []
        model.trash(items.filter { seen.insert($0.url).inserted })
        groups = groups.compactMap { group in
            var group = group
            group.items.removeAll { marked.contains($0.url) }
            return group.items.count > 1 ? group : nil
        }
        marked = []
    }
}
