import AppKit
import SwiftUI

// MARK: - Filters

struct FilterButton: View {
    @Environment(BrowserModel.self) private var model
    @State private var isPresented = false

    var body: some View {
        Button { isPresented.toggle() } label: {
            Label(
                "Filter",
                systemImage: model.hasActiveFilters ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle"
            )
        }
        .help("Filter by type and date taken")
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            FilterPanel()
                .padding(16)
                .frame(width: 320)
        }
    }
}

struct FilterPanel: View {
    @Environment(BrowserModel.self) private var model

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 14) {
            Picker("Show", selection: $model.typeFilter) {
                ForEach(MediaTypeFilter.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)

            Picker("Taken", selection: $model.dateFilter) {
                ForEach(DateFilter.allCases) { Text($0.rawValue).tag($0) }
            }
            if model.dateFilter == .custom {
                DatePicker("From", selection: $model.customDateFrom, displayedComponents: .date)
                DatePicker("To", selection: $model.customDateTo, displayedComponents: .date)
            }
            Text("“Taken” uses the date stored in the photo or video, or the file's date when there isn't one.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Clear Filters") { model.clearFilters() }
                    .disabled(!model.isFiltering)
            }
        }
    }
}

/// Shown above the grid while a search or filter hides some items.
struct FilterStatusBar: View {
    @Environment(BrowserModel.self) private var model

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "line.3.horizontal.decrease.circle.fill")
                .foregroundStyle(.tint)
            Text("Showing \(model.images.count) of \(model.allImages.count)")
                .fontWeight(.medium)
            ForEach(chips, id: \.self) { chip in
                Text(chip)
                    .font(.caption)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(.tint.opacity(0.15), in: Capsule())
            }
            if model.isAnalyzingContent {
                ProgressView(value: Double(model.contentAnalysisDone), total: Double(max(1, model.contentAnalysisTotal)))
                    .frame(width: 70)
                Text("Recognizing contents…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Button("Clear") { model.clearFilters() }
                .buttonStyle(.borderless)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .glassSurface(in: Capsule())
    }

    private var chips: [String] {
        var chips: [String] = []
        let search = model.searchText.trimmingCharacters(in: .whitespaces)
        if !search.isEmpty { chips.append("“\(search)”") }
        if model.typeFilter != .all { chips.append(model.typeFilter.rawValue) }
        if model.dateFilter == .custom {
            chips.append("\(model.customDateFrom.formatted(date: .abbreviated, time: .omitted)) – \(model.customDateTo.formatted(date: .abbreviated, time: .omitted))")
        } else if model.dateFilter != .any {
            chips.append(model.dateFilter.rawValue)
        }
        return chips
    }
}

// MARK: - Tools menu

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

struct BatchRenameView: View {
    @Environment(BrowserModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var items: [FileItem] = []
    @State private var dates: [URL: Date] = [:]
    @State private var template = "{date}_{n}"
    @State private var start = 1
    @State private var digits = 3

    private static let tokens = ["{name}", "{n}", "{date}", "{time}", "{year}", "{month}", "{day}"]

    private var plans: [RenamePlan] {
        BrowserModel.renamePlans(for: items, template: template, start: start, digits: digits, dates: dates)
    }

    var body: some View {
        let plans = plans
        let problem = items.isEmpty ? nil : BrowserModel.problem(with: plans)
        VStack(alignment: .leading, spacing: 14) {
            Text("Rename \(items.count) Item\(items.count == 1 ? "" : "s")")
                .font(.title3.bold())

            TextField("Pattern", text: $template)
                .textFieldStyle(.roundedBorder)
                .font(.body.monospaced())
            HStack(spacing: 6) {
                Text("Insert:")
                    .foregroundStyle(.secondary)
                ForEach(Self.tokens, id: \.self) { token in
                    Button(token) { template += token }
                        .controlSize(.small)
                }
            }
            HStack(spacing: 24) {
                Stepper("Start at \(start)", value: $start, in: 0...99_999)
                Stepper("Digits: \(digits)", value: $digits, in: 1...6)
            }

            List(plans.prefix(500)) { plan in
                HStack {
                    Text(plan.item.name)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Image(systemName: "arrow.right")
                        .foregroundStyle(.tertiary)
                    Text(plan.newName)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .listStyle(.bordered)

            if let problem {
                Label(problem, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
            }
            HStack {
                Text("{date} and {time} are when each photo was taken. Undo with ⌘Z.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Rename") {
                    model.applyBatchRename(plans)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(problem != nil || items.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 600, height: 540)
        .task {
            items = model.batchTargets
            dates = await BrowserModel.captureDates(for: items, known: model.mediaInfo)
        }
    }
}

// MARK: - Export

struct ExportView: View {
    @Environment(BrowserModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var items: [FileItem] = []
    @State private var options = ExportOptions()
    @State private var isExporting = false
    @State private var exported = 0
    @State private var failures: [String] = []
    @State private var exportTask: Task<Void, Never>?

    private static let sizes = [4096, 3000, 2048, 1600, 1024]

    var body: some View {
        let photos = items.filter { !$0.isVideo }
        VStack(alignment: .leading, spacing: 14) {
            Text("Export \(photos.count) Image\(photos.count == 1 ? "" : "s")")
                .font(.title3.bold())
            Form {
                Picker("Format", selection: $options.format) {
                    ForEach(ExportOptions.Format.available) { Text($0.rawValue).tag($0) }
                }
                Picker("Size", selection: $options.maxPixelSize) {
                    Text("Original size").tag(Int?.none)
                    ForEach(Self.sizes, id: \.self) { Text("\($0) px on the longest side").tag(Int?.some($0)) }
                }
                if options.format.isLossy {
                    LabeledContent("Quality") {
                        HStack {
                            Slider(value: $options.quality, in: 0.4...1)
                            Text("\(Int((options.quality * 100).rounded()))%")
                                .monospacedDigit()
                                .frame(width: 40, alignment: .trailing)
                        }
                    }
                }
                Toggle("Keep camera details and date", isOn: $options.keepMetadata)
                Toggle("Remove location", isOn: $options.removeLocation)
                    .disabled(!options.keepMetadata)
            }
            .formStyle(.grouped)
            .scrollDisabled(true)

            if items.count > photos.count {
                Text("\(items.count - photos.count) video\(items.count - photos.count == 1 ? " is" : "s are") skipped.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if isExporting {
                ProgressView(value: Double(exported), total: Double(max(1, photos.count))) {
                    Text("Exporting \(exported) of \(photos.count)…")
                }
            }
            if !failures.isEmpty {
                ScrollView {
                    Text(failures.joined(separator: "\n"))
                        .font(.caption)
                        .foregroundStyle(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 80)
            }
            HStack {
                Text("Originals are never changed.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button(isExporting ? "Stop" : "Cancel", role: .cancel) {
                    exportTask?.cancel()
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                Button("Export…") { chooseFolderAndExport(photos) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(photos.isEmpty || isExporting)
            }
        }
        .padding(20)
        .frame(width: 480)
        .task {
            items = model.batchTargets
            if !ExportOptions.Format.available.contains(options.format) {
                options.format = ExportOptions.Format.available.first ?? .jpeg
            }
        }
    }

    private func chooseFolderAndExport(_ photos: [FileItem]) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Export Here"
        panel.message = "Choose where to save the exported copies"
        panel.directoryURL = model.folder
        guard panel.runModal() == .OK, let directory = panel.url else { return }
        isExporting = true
        exported = 0
        failures = []
        exportTask = Task {
            failures = await model.runExport(photos, options: options, to: directory) { exported = $0 }
            isExporting = false
            if failures.isEmpty { dismiss() }
        }
    }
}

// MARK: - Duplicates

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
