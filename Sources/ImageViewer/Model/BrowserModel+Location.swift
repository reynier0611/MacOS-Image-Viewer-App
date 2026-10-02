import AppKit
import Foundation

/// Adding a location by hand to photos that don't have one (or fixing a wrong one).
extension BrowserModel {
    /// The open image or the selected photos that can hold a location.
    var locationTargets: [FileItem] {
        fileActionTargets().filter(ImageLocation.canStore)
    }

    func showLocationPicker(for items: [FileItem]? = nil) {
        let targets = items?.filter(ImageLocation.canStore) ?? locationTargets
        guard !targets.isEmpty else {
            NSSound.beep()
            showToast("A location can be added to JPEG, HEIC, PNG and TIFF photos", canUndo: false)
            return
        }
        locationPickerItems = targets
        isLocationPickerPresented = true
    }

    /// Where to center the picker: the photos' own location, or else the location of the photo in
    /// this folder taken closest in time (likely the same trip).
    func suggestedLocation(for items: [FileItem]) -> (coordinate: Coordinate, from: FileItem?)? {
        if let own = items.lazy.compactMap({ self.mediaInfo[$0.url]?.coordinate }).first {
            return (own, nil)
        }
        guard let reference = items.first.map(captureDate(for:)) else { return nil }
        let candidates = allImages.compactMap { item -> (FileItem, Coordinate)? in
            mediaInfo[item.url]?.coordinate.map { (item, $0) }
        }
        guard let nearest = candidates.min(by: {
            abs(captureDate(for: $0.0).timeIntervalSince(reference)) < abs(captureDate(for: $1.0).timeIntervalSince(reference))
        }) else { return nil }
        return (nearest.1, nearest.0)
    }

    /// Sets (or with nil, removes) the location of `items`, in their files, with Undo.
    func setLocation(_ coordinate: Coordinate?, for items: [FileItem]) {
        let storable = items.filter(ImageLocation.canStore)
        guard !storable.isEmpty else { return }
        Task {
            await loadMediaInfoIfNeeded(storable)
            applyLocations(Dictionary(uniqueKeysWithValues: storable.map { ($0.url, coordinate) }))
            let count = storable.count
            let what = count == 1 ? "“\(storable[0].name)”" : "\(count) photos"
            showToast(coordinate == nil ? "Removed the location from \(what)" : "Set the location of \(what)", canUndo: true)
        }
    }

    func applyLocations(_ locations: [URL: Coordinate?]) {
        var previous: [URL: Coordinate?] = [:]
        for (url, coordinate) in locations {
            previous[url] = mediaInfo[url]?.coordinate
            mediaInfo[url, default: MediaInfo()].coordinate = coordinate // the maps update right away
        }

        undoManager?.registerUndo(withTarget: self) { model in
            MainActor.assumeIsolated { model.applyLocations(previous) }
        }
        undoManager?.setActionName("Set Location")

        let targets = locations
        enqueueMetadataWrite(Array(targets.keys), what: "location") { url in
            try ImageLocation.write(targets[url]!, to: url)
        } onFailure: { model, failed in
            for url in failed {
                model.mediaInfo[url, default: MediaInfo()].coordinate = previous[url] ?? nil
            }
        }
        let writes = metadataWrites
        Task { [weak self] in
            await writes?.value
            self?.metadataRevision += 1 // the inspector re-reads the file's details
        }
    }
}
