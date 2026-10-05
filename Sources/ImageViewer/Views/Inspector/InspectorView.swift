import AppKit
import MapKit
import SwiftUI

struct InspectorView: View {
    @Environment(BrowserModel.self) private var model
    @State private var metadata: ImageMetadata?
    @State private var histogram: Histogram?
    @State private var labels: [String]?
    @State private var showAllProperties = false

    // The histogram and map live here, so they only appear while the (i) inspector is open.
    var body: some View {
        VStack(spacing: 0) {
            if let item = model.inspectedItem {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        if model.selectedURLs.count > 1 && !model.isViewing {
                            Label("\(model.selectedURLs.count) items selected", systemImage: "checkmark.circle")
                                .font(.headline)
                        }
                        cameraSection(for: item)
                        annotationSections(for: item)
                        if !item.isDirectory && !item.isVideo {
                            section("Histogram") {
                                if let histogram {
                                    HistogramView(histogram: histogram)
                                        .frame(height: 110)
                                } else {
                                    ProgressView().frame(maxWidth: .infinity, minHeight: 110)
                                }
                            }
                        }
                        mapSection(for: item)
                        if let metadata {
                            ForEach(metadata.sections) { section in
                                self.section(section.title) {
                                    rowsGrid(section.rows)
                                        .font(.callout)
                                }
                            }
                            if let labels, !labels.isEmpty {
                                section("Recognized") {
                                    Text(labels.prefix(8).joined(separator: ", "))
                                        .font(.callout)
                                        .textSelection(.enabled)
                                    Text("Search for these words to find similar photos.")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            if let latitude = metadata.latitude, let longitude = metadata.longitude {
                                Button {
                                    openInMaps(latitude: latitude, longitude: longitude, name: item.name)
                                } label: {
                                    Label("Open in Maps", systemImage: "map")
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
                .task(id: "\(item.url.path)|\(model.metadataRevision)") {
                    metadata = nil
                    labels = nil
                    let url = item.url
                    metadata = await Task.detached(priority: .userInitiated) { await ImageMetadata.load(for: url) }.value
                    if !item.isVideo && !item.isDirectory {
                        labels = await ContentAnalyzer.shared.labels(for: item)
                    }
                }
                .task(id: HistogramKey(url: item.url, modified: item.modified)) {
                    histogram = nil
                    guard !item.isVideo, !item.isDirectory else { return }
                    let url = item.url
                    histogram = await Task.detached(priority: .userInitiated) { Histogram.compute(for: url) }.value
                }
            } else {
                ContentUnavailableView("No Selection", systemImage: "info.circle", description: Text("Select an image to see its details."))
                    .frame(maxHeight: .infinity)
            }
        }
    }

    /// The files the tags apply to: every selected image in the grid, or just the inspected one.
    private func annotationTargets(for item: FileItem) -> [FileItem] {
        let items = (!model.isViewing && model.selectedURLs.count > 1) ? model.selectedImages : [item]
        return items.filter { !$0.isDirectory }
    }

    @ViewBuilder
    private func annotationSections(for item: FileItem) -> some View {
        let targets = annotationTargets(for: item)
        let storable = targets.filter(Annotations.canStore)
        if !targets.isEmpty {
            if storable.isEmpty {
                section("Tags & Note") {
                    Text("Tags and notes can't be saved in this file type (they're kept inside JPEG, HEIC, PNG, TIFF, MP4 and MOV files).")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                section(storable.count > 1 ? "Tags (\(storable.count) items)" : "Tags") {
                    TagEditor(items: storable)
                    if storable.count < targets.count {
                        Text("\(targets.count - storable.count) selected file\(targets.count - storable.count == 1 ? "" : "s") can't hold tags (unsupported type).")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                if storable.count == 1, let only = storable.first {
                    section("Note") {
                        NoteEditor(item: only)
                            .id(only.url)
                    }
                }
            }
        }
        Color.clear.frame(height: 0)
            .task(id: targets.map(\.url)) { await model.loadMediaInfoIfNeeded(targets) }
    }

    private struct HistogramKey: Hashable {
        let url: URL
        let modified: Date
    }

    private struct MapPoint: Identifiable {
        let name: String
        let coordinate: Coordinate
        var id: String { "\(name)|\(coordinate.latitude)|\(coordinate.longitude)" }
    }

    /// Every selected photo with a location, or just the current one.
    private func mapPoints(for item: FileItem) -> [MapPoint] {
        let items = (!model.isViewing && model.selectedURLs.count > 1) ? model.selectedImages : [item]
        return items.compactMap { item in
            let coordinate = model.mediaInfo[item.url]?.coordinate
                ?? metadata.flatMap { m in
                    item.url == model.inspectedItem?.url
                        ? m.latitude.flatMap { lat in m.longitude.map { Coordinate(latitude: lat, longitude: $0) } }
                        : nil
                }
            return coordinate.map { MapPoint(name: item.name, coordinate: $0) }
        }
    }

    /// Only shown when the photo (or some selected photos) has a location.
    @ViewBuilder
    private func mapSection(for item: FileItem) -> some View {
        let points = mapPoints(for: item)
        let placeable = annotationTargets(for: item).filter(ImageLocation.canStore)
        if points.isEmpty && !placeable.isEmpty {
            section("Location") {
                Button {
                    model.showLocationPicker(for: placeable)
                } label: {
                    Label(placeable.count > 1 ? "Add Location to \(placeable.count) Photos…" : "Add Location…", systemImage: "mappin.and.ellipse")
                }
                Text(placeable.count > 1 ? "None of the selected photos has a location." : "This photo has no location.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        if !points.isEmpty {
            section(points.count > 1 ? "Map (\(points.count) photos)" : "Map") {
                Map(initialPosition: initialMapPosition(for: points)) {
                    ForEach(points) { point in
                        Marker(point.name, systemImage: "photo", coordinate: point.coordinate.location)
                    }
                }
                // +/− buttons (a mouse wheel pans the map; pinch also zooms), compass and scale.
                .mapControls {
                    MapZoomStepper()
                    MapCompass()
                    MapScaleView()
                }
                .id(points.map(\.id).joined()) // re-frame when the selection changes
                .frame(height: 240)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                if !placeable.isEmpty {
                    Button {
                        model.showLocationPicker(for: placeable)
                    } label: {
                        Label("Change Location…", systemImage: "mappin.and.ellipse")
                    }
                }
            }
        }
    }

    /// One photo: start zoomed out to the surrounding region (~100 km across) rather than street level.
    /// Several photos: fit them all.
    private func initialMapPosition(for points: [MapPoint]) -> MapCameraPosition {
        guard points.count == 1, let point = points.first else { return .automatic }
        return .camera(MapCamera(centerCoordinate: point.coordinate.location, distance: 150_000))
    }

    // MARK: Camera info

    /// Compact "shot on" card shown at the very top of the inspector for photos that carry EXIF.
    @ViewBuilder
    private func cameraSection(for item: FileItem) -> some View {
        if !item.isDirectory, !item.isVideo, let cam = model.mediaInfo[item.url]?.camera {
            let bodyName = [cam.make, cam.model].compactMap { $0 }.joined(separator: " ")
            let rows: [MetadataRow] = [
                cam.shutterSpeed.map { MetadataRow(label: "Shutter",      value: formatShutter($0)) },
                cam.fNumber.map      { MetadataRow(label: "Aperture",     value: String(format: "f/%.4g", $0)) },
                cam.iso.map          { MetadataRow(label: "ISO",          value: "\($0)") },
                cam.focalLength.map  { MetadataRow(label: "Focal length", value: String(format: "%.4g mm", $0)) },
                cam.exposureBias.flatMap { $0 != 0
                    ? MetadataRow(label: "Exp. bias", value: String(format: "%+.1f EV", $0))
                    : nil },
            ].compactMap { $0 }

            section("Camera") {
                if !bodyName.isEmpty {
                    Label(bodyName, systemImage: "camera")
                        .font(.callout)
                }
                if let lens = cam.lens {
                    Label(lens, systemImage: "camera.aperture")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                if !rows.isEmpty {
                    rowsGrid(rows)
                        .font(.callout)
                        .padding(.top, bodyName.isEmpty && cam.lens == nil ? 0 : 4)
                }
            }
        }
    }

    private func formatShutter(_ seconds: Double) -> String {
        guard seconds > 0 else { return "—" }
        if seconds >= 1 { return String(format: "%.1f s", seconds) }
        let denom = Int((1 / seconds).rounded())
        return "1/\(denom) s"
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.headline)
            content()
        }
    }

    private func openInMaps(latitude: Double, longitude: Double, name: String) {
        let query = name.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "Photo"
        if let url = URL(string: "https://maps.apple.com/?ll=\(latitude),\(longitude)&q=\(query)") {
            NSWorkspace.shared.open(url)
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

/// RGB channels blended over the luminance curve, on a dark panel like photo editors use.
struct HistogramView: View {
    let histogram: Histogram

    var body: some View {
        Canvas { context, size in
            func path(_ values: [Double]) -> Path {
                var path = Path()
                path.move(to: CGPoint(x: 0, y: size.height))
                for (index, value) in values.enumerated() {
                    let x = size.width * CGFloat(index) / 255
                    path.addLine(to: CGPoint(x: x, y: size.height * (1 - CGFloat(value))))
                }
                path.addLine(to: CGPoint(x: size.width, y: size.height))
                path.closeSubpath()
                return path
            }
            context.fill(path(histogram.luminance), with: .color(.white.opacity(0.35)))
            context.blendMode = .screen
            context.fill(path(histogram.red), with: .color(.red.opacity(0.7)))
            context.fill(path(histogram.green), with: .color(.green.opacity(0.7)))
            context.fill(path(histogram.blue), with: .color(.blue.opacity(0.8)))
        }
        .padding(6)
        .background(Color(white: 0.12), in: RoundedRectangle(cornerRadius: 8))
        .accessibilityLabel("Color histogram")
    }
}
