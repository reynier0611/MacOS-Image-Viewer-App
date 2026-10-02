import MapKit
import SwiftUI

/// Set Location (⇧⌘L): click the map to drop a pin, or search for a place or address (or type
/// coordinates). Saved into the photos' own EXIF GPS fields.
struct LocationPickerView: View {
    @Environment(BrowserModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let items: [FileItem]

    @State private var pin: Coordinate?
    @State private var position: MapCameraPosition = .automatic
    @State private var query = ""
    @State private var results: [MKMapItem] = []
    @State private var isSearching = false
    @State private var message: String?

    private var hasLocation: Bool {
        items.contains { model.mediaInfo[$0.url]?.coordinate != nil }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(items.count == 1 ? "Location of “\(items[0].name)”" : "Location of \(items.count) photos")
                .font(.headline)

            HStack {
                TextField("Search for a place or address, or type coordinates", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(search)
                if isSearching {
                    ProgressView().controlSize(.small)
                }
                Button("Search", action: search)
                    .disabled(query.trimmingCharacters(in: .whitespaces).isEmpty)
            }

            if !results.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(results.enumerated()), id: \.offset) { index, item in
                        if index > 0 { Divider() }
                        Button {
                            choose(item)
                        } label: {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(item.name ?? "Unnamed place")
                                if let address = item.placemark.title, address != item.name {
                                    Text(address)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 5)
                            .padding(.horizontal, 8)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 7))
                .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(.quaternary))
            }

            MapReader { proxy in
                Map(position: $position) {
                    if let pin {
                        Marker(items.count == 1 ? items[0].name : "\(items.count) photos", coordinate: pin.location)
                            .tint(.red)
                    }
                }
                .mapControls {
                    MapZoomStepper()
                    MapCompass()
                    MapScaleView()
                }
                .onTapGesture(coordinateSpace: .local) { point in
                    if let coordinate = proxy.convert(point, from: .local) {
                        pin = Coordinate(latitude: coordinate.latitude, longitude: coordinate.longitude)
                        results = []
                        message = nil
                    }
                }
            }
            .frame(height: 380)
            .clipShape(RoundedRectangle(cornerRadius: 10))

            Group {
                if let pin {
                    Text(String(format: "%.5f, %.5f", pin.latitude, pin.longitude))
                        .monospacedDigit()
                        .textSelection(.enabled)
                } else {
                    Text("Click the map to drop a pin.")
                }
                if let message {
                    Text(message)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            HStack {
                if hasLocation {
                    Button("Remove Location", role: .destructive) {
                        model.setLocation(nil, for: items)
                        dismiss()
                    }
                }
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                // No Return shortcut: Return in the search field searches.
                Button("Set Location") {
                    model.setLocation(pin, for: items)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(pin == nil)
            }
        }
        .padding(20)
        .frame(width: 620)
        .onAppear(perform: start)
    }

    private func start() {
        guard let suggestion = model.suggestedLocation(for: items) else {
            position = .region(MKCoordinateRegion(
                center: CLLocationCoordinate2D(latitude: 25, longitude: 0),
                span: MKCoordinateSpan(latitudeDelta: 120, longitudeDelta: 300)
            ))
            return
        }
        if let neighbor = suggestion.from {
            // Not this photo's location, just a likely area: center there, without a pin.
            position = .camera(MapCamera(centerCoordinate: suggestion.coordinate.location, distance: 60_000))
            message = "Centered on “\(neighbor.name)”, the photo here taken closest in time."
        } else {
            pin = suggestion.coordinate
            position = .camera(MapCamera(centerCoordinate: suggestion.coordinate.location, distance: 20_000))
        }
    }

    private func search() {
        let text = query.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        if let coordinate = ImageLocation.parse(text) {
            pin = coordinate
            results = []
            message = nil
            position = .camera(MapCamera(centerCoordinate: coordinate.location, distance: 20_000))
            return
        }
        isSearching = true
        message = nil
        Task {
            defer { isSearching = false }
            let request = MKLocalSearch.Request()
            request.naturalLanguageQuery = text
            do {
                let found = try await MKLocalSearch(request: request).start().mapItems
                results = Array(found.prefix(6))
                if results.count == 1 { choose(results[0]) }
            } catch {
                results = []
                message = "No places found for “\(text)”."
            }
        }
    }

    private func choose(_ item: MKMapItem) {
        let coordinate = item.placemark.coordinate
        pin = Coordinate(latitude: coordinate.latitude, longitude: coordinate.longitude)
        position = .camera(MapCamera(centerCoordinate: coordinate, distance: 8_000))
        results = []
        message = nil
    }
}
