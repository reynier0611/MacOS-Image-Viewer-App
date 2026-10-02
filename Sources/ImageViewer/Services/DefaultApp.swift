import AppKit
import UniformTypeIdentifiers

/// Making Image Viewer the app that opens photos and videos when they're double-clicked in Finder.
/// macOS keeps one default per file type, so each common type is claimed separately. PDFs are left
/// to Preview. Giving them back restores Preview (images) and QuickTime Player (videos).
@MainActor
enum DefaultApp {
    static let askedKey = "askedToBecomeDefault"

    static let imageTypes: [UTType] = [
        .jpeg, .png, .heic, .heif, .gif, .tiff, .webP, .bmp, .ico,
        UTType("public.avif"), UTType("public.jpeg-2000"),
        // Camera RAW (each maker has its own type)
        UTType("com.adobe.raw-image"), UTType("com.canon.cr2-raw-image"), UTType("com.canon.cr3-raw-image"),
        UTType("com.canon.crw-raw-image"), UTType("com.nikon.raw-image"), UTType("com.nikon.nrw-raw-image"),
        UTType("com.sony.arw-raw-image"), UTType("com.fuji.raw-image"), UTType("com.olympus.or-raw-image"),
        UTType("com.panasonic.rw2-raw-image"), UTType("com.pentax.raw-image"),
    ].compactMap { $0 }

    static let videoTypes: [UTType] = [
        .quickTimeMovie, .mpeg4Movie, UTType("com.apple.m4v-video"),
    ].compactMap { $0 }

    static var allTypes: [UTType] { imageTypes + videoTypes }

    /// Only the installed copy offers itself (not test builds or `swift run`).
    static var isInstalledCopy: Bool {
        Bundle.main.bundleIdentifier != nil && Bundle.main.bundleURL.path.hasPrefix("/Applications/")
    }

    /// True when every type above already opens in this app.
    static var isDefault: Bool {
        let me = Bundle.main.bundleURL.standardizedFileURL
        return allTypes.allSatisfy { NSWorkspace.shared.urlForApplication(toOpen: $0)?.standardizedFileURL == me }
    }

    static func makeDefault() async {
        await setHandler(Bundle.main.bundleURL, for: allTypes)
    }

    static func restoreApple() async {
        let workspace = NSWorkspace.shared
        if let preview = workspace.urlForApplication(withBundleIdentifier: "com.apple.Preview") {
            await setHandler(preview, for: imageTypes)
        }
        if let quickTime = workspace.urlForApplication(withBundleIdentifier: "com.apple.QuickTimePlayerX") {
            await setHandler(quickTime, for: videoTypes)
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
        alert.informativeText = "Double-clicking an image (JPEG, PNG, HEIC, RAW…) or a video (MOV, MP4) in Finder will open it here instead of in Preview or QuickTime Player. You can change this anytime in Settings ▸ General."
        alert.addButton(withTitle: "Make Default")
        alert.addButton(withTitle: "Not Now")
        if alert.runModal() == .alertFirstButtonReturn {
            Task { await makeDefault() }
        }
    }
}
