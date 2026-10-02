import AppKit
import SwiftUI

/// Image Viewer ▸ Settings… (⌘,)
struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettings()
                .tabItem { Label("General", systemImage: "gearshape") }
            ViewerSettings()
                .tabItem { Label("Viewer", systemImage: "photo") }
            PrivacySettings()
                .tabItem { Label("Privacy", systemImage: "hand.raised") }
        }
        .frame(width: 480)
        .fixedSize(horizontal: false, vertical: true)
    }
}

private struct GeneralSettings: View {
    @Environment(BrowserModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Form {
            Section {
                Picker("When opened on its own, start in", selection: $model.launchFolder) {
                    ForEach(LaunchFolder.allCases) { Text($0.rawValue).tag($0) }
                }
                if model.launchFolder == .custom {
                    LabeledContent("Folder") {
                        HStack {
                            Text(model.customLaunchPath.isEmpty ? "None chosen" : (model.customLaunchPath as NSString).abbreviatingWithTildeInPath)
                                .foregroundStyle(model.customLaunchPath.isEmpty ? .secondary : .primary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Button("Choose…") { chooseFolder() }
                        }
                    }
                }
            } footer: {
                Text("Opening an image or folder from Finder always shows that item. The app doesn't remember where you were last time.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Browsing") {
                Picker("Sort by", selection: $model.sortKey) {
                    ForEach(SortKey.allCases) { Text($0.rawValue).tag($0) }
                }
                Toggle("Ascending", isOn: $model.sortAscending)
                LabeledContent("Thumbnail size") {
                    Slider(value: $model.thumbnailSize, in: 80...400)
                }
                Toggle("Show hidden files", isOn: $model.showHidden)
            }
            Section {
                LabeledContent("Opens photos and videos") {
                    HStack {
                        Text(isDefault ? "Yes" : "No")
                            .foregroundStyle(isDefault ? .green : .secondary)
                        if isDefault {
                            Button("Give Back to Preview") { change { await DefaultApp.restoreApple() } }
                        } else {
                            Button("Make Default") { change { await DefaultApp.makeDefault() } }
                        }
                    }
                }
            } footer: {
                Text("What opens JPEG, PNG, HEIC, GIF, TIFF and WebP images and MOV and MP4 videos when you double-click them in Finder. Camera RAW and other formats are left alone. macOS asks you to confirm each format. Giving back restores Preview for images and QuickTime Player for videos.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            isDefault = DefaultApp.isDefault
        }
    }

    @State private var isDefault = DefaultApp.isDefault

    private func change(_ action: @escaping @MainActor () async -> Void) {
        Task {
            await action()
            isDefault = DefaultApp.isDefault
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.prompt = "Choose"
        if panel.runModal() == .OK, let url = panel.url {
            model.customLaunchPath = url.path
        }
    }
}

private struct ViewerSettings: View {
    @Environment(BrowserModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Form {
            Picker("Background around the image", selection: $model.viewerBackground) {
                ForEach(ViewerBackground.allCases) { Text($0.rawValue).tag($0) }
            }
            Toggle("Enlarge small images to fit the window", isOn: $model.enlargeSmallImages)
            Toggle("Show the filmstrip when the pointer is at the bottom", isOn: $model.showFilmstrip)
        }
        .formStyle(.grouped)
    }
}

private struct PrivacySettings: View {
    @Environment(BrowserModel.self) private var model
    @State private var recognizedCount: Int?
    @State private var hasFullDiskAccess = FullDiskAccess.isGranted
    @AppStorage(ThumbnailDiskCache.enabledKey) private var keepsThumbnails = true
    @State private var thumbnailBytes: Int64?

    private func clearThumbnails() {
        Task.detached { ThumbnailDiskCache.shared.clear() }
        thumbnailBytes = 0
    }

    var body: some View {
        @Bindable var model = model
        Form {
            Section {
                LabeledContent("Full Disk Access") {
                    HStack {
                        Text(hasFullDiskAccess ? "On" : "Off")
                            .foregroundStyle(hasFullDiskAccess ? .green : .secondary)
                        Button(hasFullDiskAccess ? "Open Settings…" : "Turn On…") { FullDiskAccess.openSettings() }
                    }
                }
            } footer: {
                Text("macOS asks before an app opens Desktop, Documents, Downloads, or external and network drives. With Full Disk Access, Image Viewer can open any folder without asking. In System Settings, switch on Image Viewer (or add it with +).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section {
                Toggle("Remember folders I move photos into", isOn: $model.remembersMoveDestinations)
                LabeledContent("Remembered") {
                    HStack {
                        Text("\(model.recentMoveDestinations.count) folder\(model.recentMoveDestinations.count == 1 ? "" : "s")")
                            .foregroundStyle(.secondary)
                        Button("Forget") { model.forgetMoveDestinations() }
                            .disabled(model.recentMoveDestinations.isEmpty)
                    }
                }
            } footer: {
                Text("Shown under Move to ▸ Recent.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section {
                Toggle("Keep thumbnails on disk (much faster)", isOn: $keepsThumbnails)
                    .onChange(of: keepsThumbnails) { if !keepsThumbnails { clearThumbnails() } }
                LabeledContent("Thumbnail cache") {
                    HStack {
                        Text(thumbnailBytes.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "…")
                            .foregroundStyle(.secondary)
                        Button("Clear") { clearThumbnails() }
                            .disabled(thumbnailBytes == 0)
                    }
                }
            } footer: {
                Text("Small copies of thumbnails you've browsed, kept only on this Mac so folders open instantly next time. Capped at 500 MB.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section {
                LabeledContent("Recognized photos") {
                    HStack {
                        Text(recognizedCount.map { "\($0)" } ?? "…")
                            .foregroundStyle(.secondary)
                        Button("Clear") {
                            Task {
                                await ContentAnalyzer.shared.clearCache()
                                recognizedCount = 0
                            }
                        }
                        .disabled(recognizedCount == 0)
                    }
                }
            } footer: {
                Text("What search recognized in your photos (e.g. “beach”), stored only on this Mac so each photo is analyzed once.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .task {
            recognizedCount = await ContentAnalyzer.shared.cachedCount
            thumbnailBytes = await Task.detached { ThumbnailDiskCache.shared.totalBytes }.value
        }
        // Re-check when coming back from System Settings.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            hasFullDiskAccess = FullDiskAccess.isGranted
        }
    }
}

enum FullDiskAccess {
    /// The privacy database is only readable by apps with Full Disk Access, so trying to open it
    /// is a reliable check (it's opened read-only and closed immediately; nothing is read).
    static var isGranted: Bool {
        let path = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/com.apple.TCC/TCC.db").path
        guard let handle = FileHandle(forReadingAtPath: path) else { return false }
        try? handle.close()
        return true
    }

    static func openSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
            NSWorkspace.shared.open(url)
        }
    }
}
