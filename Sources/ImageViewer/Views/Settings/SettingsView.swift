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
        }
        .formStyle(.grouped)
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

    var body: some View {
        @Bindable var model = model
        Form {
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
        .task { recognizedCount = await ContentAnalyzer.shared.cachedCount }
    }
}
