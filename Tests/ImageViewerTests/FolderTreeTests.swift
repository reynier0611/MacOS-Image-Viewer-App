import AppKit
import Foundation
import Testing
@testable import ImageViewer

@Suite("Sidebar folder tree")
@MainActor
struct FolderTreeTests {
    let folder = TempFolder()
    var root: URL { URL(fileURLWithPath: realpath(folder.url.path, nil).map { String(cString: $0) } ?? folder.url.path, isDirectory: true) }

    func dir(_ path: String) -> URL {
        let url = root.appendingPathComponent(path, isDirectory: true)
        try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func listsOnlyFoldersInNaturalOrder() {
        _ = dir("Day 10"); _ = dir("Day 2"); _ = dir(".hidden"); _ = dir("Library.photoslibrary")
        Fixtures.write(Fixtures.solid(CGColor(gray: 0.5, alpha: 1)), to: root.appendingPathComponent("photo.jpg"))

        #expect(FolderTree.subfolders(of: root, showHidden: false).map(\.lastPathComponent) == ["Day 2", "Day 10"])
        #expect(FolderTree.subfolders(of: root, showHidden: true).map(\.lastPathComponent) == [".hidden", "Day 2", "Day 10"])
    }

    @Test func emptyFoldersBecomeLeavesOnceLoaded() async {
        let empty = dir("Empty")
        let tree = FolderTree()
        #expect(!tree.isLeaf(empty)) // unknown until loaded: shows an arrow
        await tree.loadNow(empty)
        #expect(tree.isLeaf(empty))
    }

    @Test func revealOpensTheChainUnderTheMostSpecificRoot() async {
        let deep = dir("Cloud/Trips/2024/Summer")
        let tree = FolderTree()
        let cloud = root.appendingPathComponent("Cloud", isDirectory: true)

        #expect(await tree.reveal(deep, roots: [root, cloud]))

        // Expanded from the iCloud-like root down to the parent, not the folder itself.
        #expect(tree.expanded == [cloud.path, cloud.appendingPathComponent("Trips").path, cloud.appendingPathComponent("Trips/2024").path])
        #expect(tree.children[cloud.appendingPathComponent("Trips/2024").path]?.map(\.lastPathComponent) == ["Summer"])
        #expect(await tree.reveal(URL(fileURLWithPath: "/definitely/elsewhere"), roots: [root]) == false)
    }

    @Test func revealShowsAHiddenFolderOnTheWay() async {
        let inside = dir(".secret/Inner")
        let tree = FolderTree()
        await tree.reveal(inside, roots: [root])
        #expect(tree.children[root.path]?.contains { $0.lastPathComponent == ".secret" } == true)
    }

    @Test func updatesFromTheGridOnlyForLoadedFolders() async {
        let tree = FolderTree()
        tree.update(root, subfolders: [root.appendingPathComponent("New")])
        #expect(tree.children[root.path] == nil) // never expanded: nothing to keep in sync
        await tree.loadNow(root)
        tree.update(root, subfolders: [root.appendingPathComponent("B"), root.appendingPathComponent("A")])
        #expect(tree.children[root.path]?.map(\.lastPathComponent) == ["A", "B"])
    }
}

extension AppModelSuite {
    @Suite("Renaming from the sidebar")
    @MainActor
    struct SidebarRenameTests {
        let folder = TempFolder()
        let model = BrowserModel.shared

        @Test func renamingAFolderThatContainsTheOpenOneFollowsIt() async throws {
            let inner = folder.url.appendingPathComponent("Trips/2024", isDirectory: true)
            try FileManager.default.createDirectory(at: inner, withIntermediateDirectories: true)
            Fixtures.write(Fixtures.solid(CGColor(gray: 0.5, alpha: 1)), to: inner.appendingPathComponent("a.jpg"))
            let undo = UndoManager()
            undo.groupsByEvent = false
            model.undoManager = undo
            model.navigate(to: inner)
            for _ in 0..<60 where model.allImages.isEmpty { try await Task.sleep(for: .milliseconds(30)) }
            let version = model.folderStructureVersion
            let open = try #require(model.folder)
            let trips = try #require(FileItem(url: open.deletingLastPathComponent()))

            model.beginRename(trips)
            model.renameText = "Journeys"
            undo.beginUndoGrouping(); model.commitRename(); undo.endUndoGrouping()

            #expect(model.folder?.path.hasSuffix("/Journeys/2024") == true)
            #expect(model.folderStructureVersion > version)
            for _ in 0..<60 where model.allImages.first?.name != "a.jpg" { try await Task.sleep(for: .milliseconds(30)) }
            #expect(model.allImages.map(\.name) == ["a.jpg"])
            #expect(model.errorMessage == nil)
        }
    }
}
