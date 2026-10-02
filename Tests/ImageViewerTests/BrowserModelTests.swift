import AppKit
import Foundation
import Testing
@testable import ImageViewer

/// Drives the real app model against a temporary folder. Serialized: the app has one shared model.
@Suite("Browser model", .serialized)
@MainActor
struct BrowserModelTests {
    let folder = TempFolder()
    let model = BrowserModel.shared
    let undo = UndoManager()

    init() {
        _ = NSApplication.shared
        undo.groupsByEvent = false
        model.undoManager = undo
        model.clearFilters()
        model.sortKey = .name
        model.sortAscending = true
    }

    /// Creates images named `names` and opens the folder, waiting until the listing is loaded.
    func open(_ names: [String]) async throws {
        for (index, name) in names.enumerated() {
            let shade = CGFloat(index + 1) / CGFloat(names.count + 1)
            Fixtures.write(Fixtures.solid(CGColor(srgbRed: shade, green: 0.4, blue: 1 - shade, alpha: 1), width: 60 + index * 10), to: folder.file(name))
        }
        model.navigate(to: folder.url)
        try await waitUntil { model.allImages.count == names.count }
    }

    func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<100 where !condition() {
            try await Task.sleep(for: .milliseconds(30))
        }
        #expect(condition())
    }

    func undoLastAction() {
        undo.undo()
    }

    func grouped(_ action: () -> Void) {
        undo.beginUndoGrouping()
        action()
        undo.endUndoGrouping()
    }

    // MARK: Keyboard (regression: a focused search field swallowed ← →)

    @Test func arrowKeysWorkAfterLeavingTheSearchField() async throws {
        try await open(["a.jpg", "b.jpg", "c.jpg"])
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        let search = NSSearchField(frame: NSRect(x: 10, y: 10, width: 200, height: 24))
        window.contentView?.addSubview(search)
        func key(_ code: UInt16, _ scalar: Int) -> NSEvent {
            let characters = String(Character(UnicodeScalar(scalar)!))
            return NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                context: nil, characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code
            )!
        }
        let right = key(124, NSRightArrowFunctionKey), down = key(125, NSDownArrowFunctionKey)
        model.selection = model.images[0].url

        #expect(window.makeFirstResponder(search))
        #expect(window.firstResponder is NSText)
        #expect(model.handleKey(right) == false) // typing: the arrow moves the text cursor
        #expect(model.selection == model.images[0].url)

        #expect(model.handleKey(down)) // ↓ leaves the search field, like Finder
        #expect(!(window.firstResponder is NSText))
        #expect(model.handleKey(right))
        #expect(model.selection == model.images[1].url)

        window.makeFirstResponder(search)
        model.endTextEditing(in: window) // what clicking a thumbnail or the image does
        #expect(!(window.firstResponder is NSText))
    }

    // MARK: Selection

    @Test func clickModifiersSelectLikeFinder() async throws {
        try await open(["1.jpg", "2.jpg", "3.jpg", "4.jpg", "5.jpg"])
        let items = model.images
        model.click(items[0], modifiers: [])
        model.click(items[2], modifiers: .command)
        #expect(model.selectedURLs == [items[0].url, items[2].url])
        model.click(items[2], modifiers: .command)
        #expect(model.selectedURLs == [items[0].url])
        // ⇧ adds the range from the last-clicked item (here item 3, just deselected) to the selection.
        model.click(items[3], modifiers: .shift)
        #expect(model.selectedURLs == [items[0].url, items[2].url, items[3].url])
        model.click(items[1], modifiers: [])
        model.click(items[3], modifiers: .shift)
        #expect(model.selectedURLs == Set(items[1...3].map(\.url)))
        model.click(items[4], modifiers: [])
        #expect(model.selectedURLs == [items[4].url])
    }

    @Test func upAndDownMoveByARow() async throws {
        try await open(["1.jpg", "2.jpg", "3.jpg", "4.jpg", "5.jpg", "6.jpg"])
        model.gridColumns = 3
        model.selection = model.images[1].url
        model.moveSelection(by: model.gridColumns)
        #expect(model.selection == model.images[4].url)
        model.moveSelection(by: 10) // stops at the last item
        #expect(model.selection == model.images[5].url)
    }

    // MARK: File operations (all undoable)

    @Test func batchRenameCanSwapNamesAndUndo() async throws {
        try await open(["a.jpg", "b.jpg"])
        let a = model.allImages.first { $0.name == "a.jpg" }!, b = model.allImages.first { $0.name == "b.jpg" }!
        grouped {
            model.applyBatchRename([RenamePlan(item: a, newName: "b.jpg"), RenamePlan(item: b, newName: "a.jpg")])
        }
        try await waitUntil { model.allImages.first { $0.name == "a.jpg" }?.size == b.size }
        #expect(model.allImages.first { $0.name == "b.jpg" }?.size == a.size)
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.url.path).filter { $0.hasPrefix(".") }.isEmpty)

        undoLastAction()
        try await waitUntil { model.allImages.first { $0.name == "a.jpg" }?.size == a.size }
    }

    @Test func moveIntoFolderAndUndo() async throws {
        let sub = folder.url.appendingPathComponent("Keep", isDirectory: true)
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        Fixtures.write(Fixtures.solid(CGColor(gray: 0.2, alpha: 1)), to: sub.appendingPathComponent("x.jpg"))
        try await open(["x.jpg", "y.jpg"])
        let x = model.allImages.first { $0.name == "x.jpg" }!

        grouped { model.move([x], to: sub) }

        #expect(model.allImages.map(\.name) == ["y.jpg"])
        // A name clash never overwrites: it becomes “x 2.jpg”.
        #expect(Set(try FileManager.default.contentsOfDirectory(atPath: sub.path)) == ["x.jpg", "x 2.jpg"])

        undoLastAction()
        try await waitUntil { model.allImages.count == 2 }
        #expect(Set(try FileManager.default.contentsOfDirectory(atPath: sub.path)) == ["x.jpg"])
    }

    @Test func rotateSelectionAndUndo() async throws {
        try await open(["a.jpg", "b.jpg", "c.jpg"])
        model.click(model.images[0], modifiers: [])
        model.click(model.images[1], modifiers: .command)

        grouped { model.changeOrientation(.rotateRight) }

        #expect(Fixtures.orientation(of: folder.file("a.jpg")) == 6)
        #expect(Fixtures.orientation(of: folder.file("b.jpg")) == 6)
        #expect(Fixtures.orientation(of: folder.file("c.jpg")) == 1)
        undoLastAction()
        #expect(Fixtures.orientation(of: folder.file("a.jpg")) == 1)
        #expect(Fixtures.orientation(of: folder.file("b.jpg")) == 1)
    }

    @Test func filteringHidesItemsAndKeepsSelectionConsistent() async throws {
        try await open(["beach.jpg", "city.jpg", "beach 2.jpg"])
        model.selection = model.images.first { $0.name == "city.jpg" }!.url
        model.searchText = "beach"
        #expect(model.images.map(\.name) == ["beach 2.jpg", "beach.jpg"])
        #expect(model.selection.map { url in model.images.contains { $0.url == url } } == true)
        model.clearFilters()
        #expect(model.images.count == 3)
    }

    // MARK: Settings

    @Test func launchFolderDefaultsToHomeAndFallsBackWhenMissing() {
        let (saved, savedPath) = (model.launchFolder, model.customLaunchPath)
        defer { model.launchFolder = saved; model.customLaunchPath = savedPath }
        let home = FileManager.default.homeDirectoryForCurrentUser.path

        model.launchFolder = .home
        #expect(model.launchFolderURL.path == home)
        model.launchFolder = .custom
        model.customLaunchPath = folder.url.path
        #expect(model.launchFolderURL.path == folder.url.path)
        model.customLaunchPath = "/definitely/not/here"
        #expect(model.launchFolderURL.path == home)
    }

    @Test func turningOffMoveMemoryForgetsAndStopsRemembering() {
        let saved = model.remembersMoveDestinations
        defer { model.remembersMoveDestinations = saved }
        model.remembersMoveDestinations = true
        model.rememberMoveDestination(folder.url)
        #expect(model.recentMoveDestinations.first?.path == folder.url.path)

        model.remembersMoveDestinations = false
        #expect(model.recentMoveDestinations.isEmpty)
        model.rememberMoveDestination(folder.url)
        #expect(model.recentMoveDestinations.isEmpty)
    }

    // MARK: Renaming

    func entries() throws -> Set<String> {
        Set(try FileManager.default.contentsOfDirectory(atPath: folder.url.path))
    }

    @Test func renamesAFolderKeepingDotsInItsNameAndUndoes() async throws {
        let trip = folder.url.appendingPathComponent("2024.06 Trip", isDirectory: true)
        try FileManager.default.createDirectory(at: trip, withIntermediateDirectories: true)
        Fixtures.write(Fixtures.solid(CGColor(gray: 0.4, alpha: 1)), to: trip.appendingPathComponent("inside.jpg"))
        try await open(["a.jpg"])
        let item = try #require(model.folders.first { $0.name == "2024.06 Trip" })

        model.beginRename(item)
        #expect(model.isRenamingFolder)
        #expect(model.renameText == "2024.06 Trip") // whole name, not "2024"
        model.renameText = "2024.07 Beach"
        grouped { model.commitRename() }

        #expect(try entries().contains("2024.07 Beach"))
        #expect(FileManager.default.fileExists(atPath: folder.url.appendingPathComponent("2024.07 Beach/inside.jpg").path))
        try await waitUntil { model.folders.map(\.name) == ["2024.07 Beach"] }

        undoLastAction()
        #expect(try entries().contains("2024.06 Trip"))
        try await waitUntil { model.folders.map(\.name) == ["2024.06 Trip"] }
    }

    @Test func changingOnlyLetterCaseWorksForFilesAndFolders() async throws {
        try FileManager.default.createDirectory(at: folder.url.appendingPathComponent("trip"), withIntermediateDirectories: true)
        try await open(["photo.jpg"])

        model.beginRename(model.folders.first { $0.name == "trip" })
        model.renameText = "Trip"
        grouped { model.commitRename() }
        model.beginRename(model.allImages.first { $0.name == "photo.jpg" })
        model.renameText = "Photo"
        grouped { model.commitRename() }

        #expect(model.errorMessage == nil)
        #expect(try entries() == ["Trip", "Photo.jpg"])
    }

    @Test("Rejects invalid names", arguments: ["", "  ", "a/b", "a:b", ".hidden"])
    func rejectsInvalidNames(name: String) async throws {
        try FileManager.default.createDirectory(at: folder.url.appendingPathComponent("Keep"), withIntermediateDirectories: true)
        try await open(["x.jpg"])
        model.errorMessage = nil
        model.beginRename(model.folders.first { $0.name == "Keep" })
        model.renameText = name
        grouped { model.commitRename() }
        #expect(model.errorMessage != nil)
        #expect(try entries() == ["Keep", "x.jpg"])
        model.errorMessage = nil
    }

    @Test func backHistoryFollowsARenamedFolder() async throws {
        let old = folder.url.appendingPathComponent("Old", isDirectory: true)
        try FileManager.default.createDirectory(at: old.appendingPathComponent("Inner"), withIntermediateDirectories: true)
        try await open(["x.jpg"])
        model.navigate(to: old.appendingPathComponent("Inner"))
        model.navigate(to: folder.url) // history: …, root, Old/Inner
        try await waitUntil { model.folders.contains { $0.name == "Old" } }

        model.beginRename(model.folders.first { $0.name == "Old" })
        model.renameText = "New"
        grouped { model.commitRename() }

        #expect(model.backStack.last?.path.hasSuffix("/New/Inner") == true)
        model.goBack()
        #expect(model.folder?.lastPathComponent == "Inner")
        #expect(model.folder?.deletingLastPathComponent().lastPathComponent == "New")
    }

    // MARK: Ratings

    @Test func ratingTheSelectionWritesTheFilesAndUndoes() async throws {
        try await open(["a.jpg", "b.jpg", "c.jpg"])
        model.click(model.images[0], modifiers: [])
        model.click(model.images[1], modifiers: .command)

        grouped { model.setRating(4) }
        #expect(model.rating(for: model.images[0]) == 4) // on screen immediately
        await model.finishRatingWrites()
        #expect(Ratings.read(folder.file("a.jpg")) == 4)
        #expect(Ratings.read(folder.file("b.jpg")) == 4)
        #expect(Ratings.read(folder.file("c.jpg")) == nil)

        undoLastAction()
        await model.finishRatingWrites()
        #expect(Ratings.read(folder.file("a.jpg")) == 0)
        #expect(model.rating(for: model.images[0]) == 0)
    }

    @Test func numberKeysAndXRateTheOpenImage() async throws {
        try await open(["a.jpg", "b.jpg"])
        model.openImage(at: 0)
        defer { model.closeViewer() }
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 100, height: 100), styleMask: [.titled], backing: .buffered, defer: false)
        func press(_ key: String, code: UInt16) -> Bool {
            model.handleKey(NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                context: nil, characters: key, charactersIgnoringModifiers: key, isARepeat: false, keyCode: code
            )!)
        }

        grouped { #expect(press("5", code: 23)) }
        #expect(model.rating(for: model.images[0]) == 5)
        grouped { #expect(press("x", code: 7)) }
        #expect(model.rating(for: model.images[0]) == Ratings.rejected)
        grouped { #expect(press("x", code: 7)) } // X again un-rejects
        #expect(model.rating(for: model.images[0]) == 0)
        await model.finishRatingWrites()
        #expect(Ratings.read(folder.file("a.jpg")) == 0)
        #expect(Ratings.read(folder.file("b.jpg")) == nil)
    }

    @Test func existingRatingsAreReadAndCanBeFilteredAndSorted() async throws {
        let names = ["one.jpg", "three.jpg", "none.jpg", "rejected.jpg"]
        for name in names { Fixtures.write(Fixtures.solid(CGColor(gray: 0.5, alpha: 1)), to: folder.file(name)) }
        try Ratings.write(1, to: folder.file("one.jpg"))
        try Ratings.write(3, to: folder.file("three.jpg"))
        try Ratings.write(Ratings.rejected, to: folder.file("rejected.jpg"))
        model.navigate(to: folder.url)
        try await waitUntil { model.allImages.count == 4 && model.allImages.allSatisfy { model.mediaInfo[$0.url] != nil } }
        defer { model.ratingFilter = .any; model.sortKey = .name; model.sortAscending = true }

        model.ratingFilter = .oneOrMore
        #expect(Set(model.images.map(\.name)) == ["one.jpg", "three.jpg"])
        model.ratingFilter = .rejected
        #expect(model.images.map(\.name) == ["rejected.jpg"])
        model.ratingFilter = .any

        model.sortKey = .rating
        model.sortAscending = false
        #expect(model.images.map(\.name) == ["three.jpg", "one.jpg", "none.jpg", "rejected.jpg"])
    }

    @Test func videosAreSkippedWithoutError() async throws {
        try await open(["a.jpg"])
        FileManager.default.createFile(atPath: folder.file("clip.mov").path, contents: Data([0, 0, 0, 0]))
        model.reload()
        try await waitUntil { model.allImages.count == 2 }
        grouped { model.setRating(3, for: model.allImages) }
        await model.finishRatingWrites()
        #expect(model.errorMessage == nil)
        #expect(Ratings.read(folder.file("a.jpg")) == 3)
        #expect(model.toast?.message.contains("1 skipped") == true)
    }
}
