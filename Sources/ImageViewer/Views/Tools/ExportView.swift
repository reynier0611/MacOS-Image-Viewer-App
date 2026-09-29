import AppKit
import SwiftUI

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
