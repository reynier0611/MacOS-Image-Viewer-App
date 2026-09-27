import AppKit
import SwiftUI

@main
struct ImageViewerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = BrowserModel.shared

    var body: some Scene {
        Window("Image Viewer", id: "main") {
            ContentView()
                .environment(model)
                .frame(minWidth: 720, minHeight: 460)
        }
        .defaultSize(width: 1280, height: 820)
        .commands { AppCommands(model: model) }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Called when files/folders are opened from Finder ("Open With"), dropped on the Dock icon, or `open -a`.
    func application(_ application: NSApplication, open urls: [URL]) {
        guard let url = urls.first else { return }
        BrowserModel.shared.open(url)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Open-file events are delivered before this, so they take precedence over the default folder.
        DispatchQueue.main.async {
            BrowserModel.shared.openDefaultFolderIfNeeded()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}
