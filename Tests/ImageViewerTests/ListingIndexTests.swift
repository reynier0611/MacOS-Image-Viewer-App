import AppKit
import Foundation
import Testing
@testable import ImageViewer

extension AppModelSuite {
    /// The grid list and lookup indexes are precomputed when the listing changes (instead of
    /// rescanning every item on each click); they must stay right through filtering and deleting.
    @Suite("Listing indexes")
    @MainActor
    struct ListingIndexTests {
        let folder = TempFolder()
        let model = BrowserModel.shared

        func open(_ names: [String], folders: [String] = []) async throws {
            for name in folders { try FileManager.default.createDirectory(at: folder.url.appendingPathComponent(name), withIntermediateDirectories: true) }
            for name in names { Fixtures.write(Fixtures.solid(CGColor(gray: 0.5, alpha: 1)), to: folder.file(name)) }
            model.clearFilters()
            model.showsAllSubfolders = false
            model.sortKey = .name
            model.sortAscending = true
            model.navigate(to: folder.url)
            for _ in 0..<100 where model.allImages.count < names.count { try await Task.sleep(for: .milliseconds(20)) }
        }

        @Test func lookupsMatchTheListing() async throws {
            try await open(["c.jpg", "a.jpg", "b.jpg"], folders: ["Zeta"])
            #expect(model.gridItems.map(\.name) == ["Zeta", "a.jpg", "b.jpg", "c.jpg"])
            for (index, item) in model.gridItems.enumerated() { #expect(model.gridIndex[item.url] == index) }
            for (index, item) in model.images.enumerated() { #expect(model.imageIndex[item.url] == index) }

            model.click(model.images[2], modifiers: [])
            model.click(model.images[0], modifiers: .command)
            model.click(model.gridItems[0], modifiers: .command) // a folder
            #expect(model.selectedImages.map(\.name) == ["a.jpg", "c.jpg"]) // grid order, images only
            #expect(model.selectedGridItems.map(\.name) == ["Zeta", "a.jpg", "c.jpg"])
            #expect(model.hasSelectedImages)
            #expect(model.selectedItem?.name == "Zeta")
        }

        @Test func lookupsFollowFiltersAndArrowKeys() async throws {
            try await open(["beach 1.jpg", "city.jpg", "beach 2.jpg"])
            model.searchText = "beach"
            #expect(model.images.map(\.name) == ["beach 1.jpg", "beach 2.jpg"])
            #expect(model.imageIndex[model.images[1].url] == 1)
            #expect(model.allImages.first { $0.name == "city.jpg" }.map { model.imageIndex[$0.url] == nil } == true)
            model.selection = model.images[0].url
            model.moveSelection(by: 1)
            #expect(model.selectedItem?.name == "beach 2.jpg")
            model.clearFilters()
            #expect(model.videoCount == 0 && model.gridItems.count == 3)
        }

        @Test func everyFileIsIndexedByTheParallelReaders() async throws {
            let names = (1...60).map { String(format: "p%02d.jpg", $0) }
            try await open(names)
            for _ in 0..<200 where model.mediaInfo.count < 60 { try await Task.sleep(for: .milliseconds(20)) }
            #expect(Set(model.mediaInfo.keys) == Set(model.allImages.map(\.url)))
        }
    }
}
