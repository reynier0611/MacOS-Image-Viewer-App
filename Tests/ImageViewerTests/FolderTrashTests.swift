import AppKit
import Foundation
import Testing
@testable import ImageViewer

extension AppModelSuite {
    /// Uses a private stand-in Trash so tests never touch your real Trash.
    @Suite("Deleting folders")
    @MainActor
    struct FolderTrashTests {
        let folder = TempFolder()
        let model = BrowserModel.shared
        let undo = UndoManager()
        let trash: URL

        init() throws {
            _ = NSApplication.shared
            undo.groupsByEvent = false
            model.undoManager = undo
            model.clearFilters()
            model.showsAllSubfolders = false
            trash = folder.url.appendingPathComponent(".TestTrash", isDirectory: true)
            try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
            let bin = trash
            model.moveItemToTrash = { url in
                let destination = bin.appendingPathComponent("\(UUID().uuidString)-\(url.lastPathComponent)")
                try FileManager.default.moveItem(at: url, to: destination)
                return destination
            }
        }

        func waitUntil(_ condition: () -> Bool) async throws {
            for _ in 0..<100 where !condition() { try await Task.sleep(for: .milliseconds(30)) }
            #expect(condition())
        }

        func makeTrips() throws -> URL {
            let trips = folder.url.appendingPathComponent("Trips/2024", isDirectory: true)
            try FileManager.default.createDirectory(at: trips, withIntermediateDirectories: true)
            Fixtures.write(Fixtures.solid(CGColor(gray: 0.5, alpha: 1)), to: trips.appendingPathComponent("beach.jpg"))
            Fixtures.write(Fixtures.solid(CGColor(gray: 0.3, alpha: 1)), to: folder.file("loose.jpg"))
            return trips.deletingLastPathComponent()
        }

        @Test func asksFirstThenTrashesTheFolderAndUndoBringsItBack() async throws {
            _ = try makeTrips()
            model.navigate(to: folder.url)
            try await waitUntil { model.folders.contains { $0.name == "Trips" } }
            let trips = try #require(model.folders.first { $0.name == "Trips" })

            model.moveToTrash(trips)
            #expect(model.isTrashConfirmationPresented)
            #expect(model.trashConfirmationTitle == "Move “Trips” and everything in it to the Trash?")
            #expect(FileManager.default.fileExists(atPath: trips.url.path)) // nothing happens until confirmed

            undo.beginUndoGrouping(); model.confirmPendingTrash(); undo.endUndoGrouping()
            #expect(!FileManager.default.fileExists(atPath: trips.url.path))
            #expect(!model.folders.contains { $0.name == "Trips" })

            undo.undo()
            #expect(FileManager.default.fileExists(atPath: trips.url.appendingPathComponent("2024/beach.jpg").path))
            try await waitUntil { model.folders.contains { $0.name == "Trips" } }
        }

        @Test func trashingTheOpenFolderFromTheSidebarStepsOutOfIt() async throws {
            let trips = try makeTrips()
            model.navigate(to: folder.url)
            model.navigate(to: trips.appendingPathComponent("2024"))
            try await waitUntil { model.allImages.map(\.name) == ["beach.jpg"] }
            let root = try #require(model.folder).deletingLastPathComponent().deletingLastPathComponent()

            undo.beginUndoGrouping()
            model.moveToTrash(try #require(FileItem(url: root.appendingPathComponent("Trips"))))
            model.confirmPendingTrash()
            undo.endUndoGrouping()

            #expect(model.folder?.path == root.path)
            #expect(!model.backStack.contains { $0.path.contains("/Trips") })
            try await waitUntil { model.allImages.map(\.name) == ["loose.jpg"] }
        }

        @Test func aMixedSelectionIsOneConfirmation() async throws {
            _ = try makeTrips()
            model.navigate(to: folder.url)
            try await waitUntil { model.gridItems.count == 2 }
            model.selectAll()
            model.moveToTrash()
            #expect(model.trashConfirmationTitle == "Move 2 items, including 1 folder and everything in it, to the Trash?")
            undo.beginUndoGrouping(); model.confirmPendingTrash(); undo.endUndoGrouping()
            #expect(model.gridItems.isEmpty)
            undo.undo()
            try await waitUntil { model.gridItems.count == 2 }
        }

        @Test func imagesAloneDontAsk() async throws {
            _ = try makeTrips()
            model.navigate(to: folder.url)
            try await waitUntil { model.allImages.count == 1 }
            undo.beginUndoGrouping(); model.moveToTrash(model.allImages[0]); undo.endUndoGrouping()
            #expect(!model.isTrashConfirmationPresented)
            #expect(model.allImages.isEmpty)
            undo.undo()
        }

        @Test func homeDrivesAndStandardFoldersAreNeverOffered() {
            let fm = FileManager.default
            for url in [fm.homeDirectoryForCurrentUser, URL(fileURLWithPath: "/"),
                        fm.urls(for: .desktopDirectory, in: .userDomainMask)[0],
                        fm.urls(for: .picturesDirectory, in: .userDomainMask)[0]] {
                #expect(model.isProtectedFolder(url), "\(url.path)")
                if let item = FileItem(url: url) { #expect(model.trashTargets(for: item).isEmpty) }
            }
            #expect(!model.isProtectedFolder(folder.url))
        }
    }
}
