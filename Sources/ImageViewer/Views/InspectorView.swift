import AppKit
import SwiftUI

struct InspectorView: View {
    @Environment(BrowserModel.self) private var model
    @State private var metadata: ImageMetadata?
    @State private var showAllProperties = false

    var body: some View {
        if let item = model.inspectedItem {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if !model.isViewing && !item.isDirectory {
                        ThumbnailView(item: item, size: 200)
                            .frame(maxWidth: .infinity)
                    }
                    if let metadata {
                        ForEach(metadata.sections) { section in
                            VStack(alignment: .leading, spacing: 6) {
                                Text(section.title)
                                    .font(.headline)
                                rowsGrid(section.rows)
                                    .font(.callout)
                            }
                        }
                        if let latitude = metadata.latitude, let longitude = metadata.longitude {
                            Button {
                                if let url = URL(string: "https://maps.apple.com/?ll=\(latitude),\(longitude)&q=\(item.name.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "Photo")") {
                                    NSWorkspace.shared.open(url)
                                }
                            } label: {
                                Label("Show in Maps", systemImage: "map")
                            }
                        }
                        if !metadata.rawProperties.isEmpty {
                            DisclosureGroup("All Properties (\(metadata.rawProperties.count))", isExpanded: $showAllProperties) {
                                rowsGrid(metadata.rawProperties)
                                    .font(.caption)
                                    .padding(.top, 6)
                            }
                        }
                    } else {
                        ProgressView()
                            .frame(maxWidth: .infinity)
                    }
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .task(id: item.url) {
                metadata = nil
                let url = item.url
                metadata = await Task.detached(priority: .userInitiated) { ImageMetadata.load(for: url) }.value
            }
        } else {
            ContentUnavailableView("No Selection", systemImage: "info.circle", description: Text("Select an image to see its details."))
        }
    }

    private func rowsGrid(_ rows: [MetadataRow]) -> some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 4) {
            ForEach(rows) { row in
                GridRow {
                    Text(row.label)
                        .foregroundStyle(.secondary)
                        .gridColumnAlignment(.trailing)
                    Text(row.value)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}
