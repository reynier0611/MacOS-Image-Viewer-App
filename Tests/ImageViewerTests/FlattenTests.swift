import AppKit
import Foundation
import Testing
@testable import ImageViewer

private func makeTree(in folder: TempFolder) throws {
    func dir(_ path: String) -> URL {
        let url = folder.url.appendingPathComponent(path, isDirectory: true)
        try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    let image = Fixtures.solid(CGColor(gray: 0.5, alpha: 1))
    Fixtures.write(image, to: folder.file("top.jpg"))
    Fixtures.write(image, to: dir("2024").appendingPathComponent("a.jpg"))
    Fixtures.write(image, to: dir("2024/Summer/Day 1").appendingPathComponent("deep.jpg"))
    Fixtures.write(image, to: dir(".hidden").appendingPathComponent("secret.jpg"))
    Fixtures.write(image, to: dir("Old.photoslibrary/originals").appendingPathComponent("inside.jpg"))
    _ = dir("Empty")
}

@Suite("Folder scanning")
struct FolderScannerTests {
    @Test func recursiveFindsMediaAtAnyDepthButOnlyTopLevelFolders() throws {
        let folder = TempFolder()
        try makeTree(in: folder)
        let items = try FolderScanner.scan(folder.url, recursive: true, showHidden: false).get()
        #expect(Set(items.filter { !$0.isDirectory }.map(\.name)) == ["top.jpg", "a.jpg", "deep.jpg"])
        #expect(Set(items.filter(\.isDirectory).map(\.name)) == ["2024", "Empty"]) // not "Summer", not hidden/packages
    }

    @Test func normalScanIsUnchanged() throws {
        let folder = TempFolder()
        try makeTree(in: folder)
        let items = try FolderScanner.scan(folder.url, recursive: false, showHidden: false).get()
        #expect(Set(items.map(\.name)) == ["top.jpg", "2024", "Empty"])
    }

    @Test func anUnreadableSubfolderIsSkippedNotFatal() throws {
        let folder = TempFolder()
        try makeTree(in: folder)
        let locked = folder.url.appendingPathComponent("Locked")
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
        Fixtures.write(Fixtures.solid(CGColor(gray: 0.2, alpha: 1)), to: locked.appendingPathComponent("x.jpg"))
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path) }

        let items = try FolderScanner.scan(folder.url, recursive: true, showHidden: false).get()
        #expect(Set(items.filter { !$0.isDirectory }.map(\.name)) == ["top.jpg", "a.jpg", "deep.jpg"])
    }
}

extension AppModelSuite {
    @Suite("Show all subfolders")
    @MainActor
    struct FlattenModelTests {
        let folder = TempFolder()
        let model = BrowserModel.shared
        let undo = UndoManager()

        init() throws {
            _ = NSApplication.shared
            undo.groupsByEvent = false
            model.undoManager = undo
            model.clearFilters()
            model.sortKey = .name
            model.sortAscending = true
            model.showsAllSubfolders = false
            try makeTree(in: folder)
        }

        func waitUntil(_ condition: () -> Bool, seconds: Double = 3, sourceLocation: SourceLocation = #_sourceLocation) async throws {
            for _ in 0..<Int(seconds * 30) where !condition() { try await Task.sleep(for: .milliseconds(33)) }
            #expect(condition(), "shown: \(model.images.map { $0.url.path.replacingOccurrences(of: model.folder?.path ?? "", with: "") }) folders: \(model.folders.map(\.name)) flat: \(model.showsAllSubfolders) loading: \(model.isLoadingFolder)", sourceLocation: sourceLocation)
        }

        func names() -> Set<String> { Set(model.images.map(\.name)) }

        @Test func togglingFlattensAndRestores() async throws {
            defer { model.showsAllSubfolders = false }
            model.navigate(to: folder.url)
            try await waitUntil { names() == ["top.jpg"] }
            #expect(Set(model.folders.map(\.name)) == ["2024", "Empty"])

            model.showsAllSubfolders = true
            try await waitUntil { names() == ["top.jpg", "a.jpg", "deep.jpg"] }
            #expect(model.folders.isEmpty) // no folder tiles
            #expect(Set(model.allFolders.map(\.name)) == ["2024", "Empty"]) // still offered in Move to
            let root = try #require(model.folder) // the resolved path (/private/var/…), as the app stores it
            #expect(model.isListed(root.appendingPathComponent("2024/Summer/Day 1/deep.jpg")))

            model.showsAllSubfolders = false
            try await waitUntil { names() == ["top.jpg"] }
            #expect(!model.isListed(root.appendingPathComponent("2024/a.jpg")))
        }

        @Test func movingBetweenSubfoldersKeepsTheFileListedAndUndoes() async throws {
            defer { model.showsAllSubfolders = false }
            model.showsAllSubfolders = true
            model.navigate(to: folder.url)
            try await waitUntil { names().count == 3 }
            let top = try #require(model.allImages.first { $0.name == "top.jpg" })

            undo.beginUndoGrouping()
            model.move([top], to: folder.url.appendingPathComponent("2024"))
            undo.endUndoGrouping()

            try await waitUntil { model.allImages.contains { $0.url.path.hasSuffix("/2024/top.jpg") } }
            #expect(names() == ["top.jpg", "a.jpg", "deep.jpg"])
            undo.undo()
            let root = try #require(model.folder) // resolved path, as the app stores it
            try await waitUntil { model.allImages.contains { $0.name == "top.jpg" && $0.url.deletingLastPathComponent().path == root.path } }
        }

        @Test func filesAddedByOtherAppsDeepInTheTreeAppear() async throws {
            defer { model.showsAllSubfolders = false }
            model.showsAllSubfolders = true
            model.navigate(to: folder.url)
            try await waitUntil { names().count == 3 }

            // Another process (cp) adds a photo three levels down; the app's own changes are ignored by design.
            let copy = Process()
            copy.executableURL = URL(fileURLWithPath: "/bin/cp")
            copy.arguments = [folder.file("top.jpg").path, folder.url.appendingPathComponent("2024/Summer/Day 1/new.jpg").path]
            try copy.run()
            copy.waitUntilExit()

            try await waitUntil({ names().contains("new.jpg") }, seconds: 5)
        }
    }
}
