import AppKit
import UniformTypeIdentifiers

/// Making Image Viewer the app that opens photos and videos when they're double-clicked in Finder.
/// Only the main formats are claimed; camera RAW, PDFs and everything else stay with whatever opens
/// them now (Photoshop, Preview…). macOS keeps one default per type and asks the user to confirm
/// each change itself (an app can't change them silently), so types already set are skipped.
/// Giving them back restores Preview (images) and QuickTime Player (videos).
@MainActor
enum DefaultApp {
    static let askedKey = "askedToBecomeDefault"

    static let imageTypes: [UTType] = [.jpeg, .png, .heic, .gif, .tiff, .webP]
    static let videoTypes: [UTType] = [.quickTimeMovie, .mpeg4Movie]

    static var allTypes: [UTType] { imageTypes + videoTypes }

    /// Only the installed copy offers itself (not test builds or `swift run`).
    static var isInstalledCopy: Bool {
        Bundle.main.bundleIdentifier != nil && Bundle.main.bundleURL.path.hasPrefix("/Applications/")
    }

    private static func isMine(_ type: UTType) -> Bool {
        NSWorkspace.shared.urlForApplication(toOpen: type)?.standardizedFileURL == Bundle.main.bundleURL.standardizedFileURL
    }

    /// True when every type above already opens in this app.
    static var isDefault: Bool { allTypes.allSatisfy(isMine) }

    static func makeDefault() async {
        await setHandler(Bundle.main.bundleURL, for: allTypes.filter { !isMine($0) })
    }

    static func restoreApple() async {
        let workspace = NSWorkspace.shared
        if let preview = workspace.urlForApplication(withBundleIdentifier: "com.apple.Preview") {
            await setHandler(preview, for: imageTypes.filter(isMine))
        }
        if let quickTime = workspace.urlForApplication(withBundleIdentifier: "com.apple.QuickTimePlayerX") {
            await setHandler(quickTime, for: videoTypes.filter(isMine))
        }
    }

    private static func setHandler(_ app: URL, for types: [UTType]) async {
        for type in types {
            try? await NSWorkspace.shared.setDefaultApplication(at: app, toOpen: type)
        }
    }

    /// Asked once, on the first launch of the installed app.
    static func askIfNeeded() {
        let defaults = UserDefaults.standard
        guard isInstalledCopy, !defaults.bool(forKey: askedKey) else { return }
        defaults.set(true, forKey: askedKey)
        guard !isDefault else { return }
        let alert = NSAlert()
        alert.messageText = "Open photos and videos with Image Viewer?"
        alert.informativeText = "Double-clicking a JPEG, PNG, HEIC, GIF, TIFF or WebP image, or a MOV or MP4 video, in Finder will open it here. Camera RAW files and everything else keep opening where they do now.\n\nmacOS then asks you to confirm each format once. You can change this anytime in Settings ▸ General."
        alert.addButton(withTitle: "Make Default")
        alert.addButton(withTitle: "Not Now")
        if alert.runModal() == .alertFirstButtonReturn {
            Task { await makeDefault() }
        }
    }
}
