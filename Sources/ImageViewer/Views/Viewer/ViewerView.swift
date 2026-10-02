import AVKit
import SwiftUI

struct ViewerView: View {
    @Environment(BrowserModel.self) private var model
    @State private var controlsVisible = true
    @State private var isPointerOverControls = false
    @State private var hideTask: Task<Void, Never>?
    /// The filmstrip only appears while the pointer is near the bottom edge, so it never hides
    /// the bottom of the image otherwise.
    @State private var isPointerNearBottom = false
    private static let filmstripRevealZone: CGFloat = 120

    private var hasFilmstrip: Bool { model.showFilmstrip && model.images.count > 1 }

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color(white: 0.94)
                    .ignoresSafeArea()
                if model.viewerBackground == .blurredPhoto {
                    AmbientBackdrop(item: model.currentItem)
                        .ignoresSafeArea() // flows up under the toolbar's glass
                }
                content
                if let error = model.imageError {
                    ContentUnavailableView(error, systemImage: "exclamationmark.triangle")
                }
            }
            .overlay(alignment: .topTrailing) {
                if model.isLoadingImage {
                    ProgressView()
                        .controlSize(.small)
                        .padding(10)
                        .glassSurface(in: Circle())
                        .padding(14)
                }
            }
            .overlay(alignment: .leading) {
                edgeButton("chevron.left", enabled: (model.viewerIndex ?? 0) > 0) { model.step(-1) }
            }
            .overlay(alignment: .trailing) {
                edgeButton("chevron.right", enabled: (model.viewerIndex ?? 0) < model.images.count - 1) { model.step(1) }
            }
            .overlay(alignment: .topLeading) { infoPill }
            .overlay(alignment: .trailing) {
                if model.isAdjusting {
                    AdjustPanel()
                        .padding(.trailing, 16)
                        .onHover { isPointerOverControls = $0 }
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
            .animation(.easeOut(duration: 0.2), value: model.isAdjusting)
            .overlay(alignment: .top) {
                if model.isTextRecognitionOn {
                    TextRecognitionBar()
                        .padding(.top, 14)
                        .onHover { isPointerOverControls = $0 }
                }
            }
            .overlay(alignment: .bottom) {
                // Videos keep it visible: the player's own controls sit above it.
                let visible = hasFilmstrip && (isPointerNearBottom || model.videoPlayer != nil)
                ZStack(alignment: .bottom) {
                    // Removed (not just faded) when hidden, so no glass is left on screen;
                    // it slides in from below the bottom edge and back out.
                    if visible {
                        FilmstripView()
                            .frame(width: min(CGFloat(model.images.count) * 76 + 20, geometry.size.width - 40))
                            .glassSurface(in: RoundedRectangle(cornerRadius: 22))
                            .padding(.bottom, 16)
                            .onHover { isPointerOverControls = $0 }
                            .transition(.move(edge: .bottom))
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                .clipped() // fully out of sight below the edge while sliding away
                .animation(.easeOut(duration: 0.25), value: visible)
            }
            .glassGroup()
            .onContinuousHover { phase in
                switch phase {
                case .active(let location):
                    isPointerNearBottom = location.y > geometry.size.height - Self.filmstripRevealZone
                    showControls()
                case .ended:
                    isPointerNearBottom = false
                    hideControls(hideCursor: false)
                }
            }
        }
        .onChange(of: model.viewerIndex, initial: true) { showControls() }
        .onDisappear { hideTask?.cancel() }
    }

    @ViewBuilder
    private var content: some View {
        if let player = model.videoPlayer {
            VideoPlayerView(player: player)
                // Keep the player's own controls clear of the floating filmstrip.
                .padding(.bottom, hasFilmstrip ? 104 : 0)
        } else {
            ZoomableImageView(
                image: model.isShowingOriginal ? model.currentImage : (model.adjustmentPreview ?? model.currentImage),
                imageURL: model.displayedURL,
                zoomRequest: model.zoomRequest,
                enlargeSmallImages: model.enlargeSmallImages,
                textLines: model.isTextRecognitionOn ? model.recognizedLines : [],
                selectedLines: model.selectedLineIDs,
                showsExtractedText: model.showsExtractedText,
                onTextSelectionChange: { model.selectedLineIDs = $0 },
                onCopyText: { model.copyRecognizedText() }
            ) { model.zoomPercent = $0 }
        }
    }

    /// Shows the floating controls, then fades them out after the pointer rests for a moment.
    private func showControls() {
        if !controlsVisible {
            withAnimation(.easeOut(duration: 0.2)) { controlsVisible = true }
        }
        hideTask?.cancel()
        hideTask = Task {
            try? await Task.sleep(for: .seconds(2.5))
            guard !Task.isCancelled, !isPointerOverControls else { return }
            hideControls(hideCursor: true)
        }
    }

    private func hideControls(hideCursor: Bool) {
        hideTask?.cancel()
        withAnimation(.easeIn(duration: 0.35)) { controlsVisible = false }
        if hideCursor && model.videoPlayer == nil {
            NSCursor.setHiddenUntilMouseMoves(true)
        }
    }

    private func edgeButton(_ symbol: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        let visible = controlsVisible && enabled
        return Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 18, weight: .semibold))
                .frame(width: 44, height: 44)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.primary)
        .glassSurface(in: Circle(), interactive: true)
        .onHover { isPointerOverControls = $0 }
        .padding(16)
        .opacity(visible ? 1 : 0)
        .allowsHitTesting(visible)
    }

    @ViewBuilder
    private var infoPill: some View {
        if let item = model.currentItem, model.imageError == nil {
            HStack(spacing: 8) {
                if item.isVideo {
                    Image(systemName: "video.fill")
                } else if let image = model.currentImage {
                    Text("\(Int(image.size.width)) × \(Int(image.size.height))")
                }
                if let zoom = model.zoomPercent, !item.isVideo {
                    Text("\(zoom)%")
                        .foregroundStyle(.secondary)
                }
                Text("\((model.viewerIndex ?? 0) + 1) / \(model.images.count)")
                    .foregroundStyle(.secondary)
            }
            .font(.callout.monospacedDigit())
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .glassSurface(in: Capsule())
            .padding(14)
            .opacity(controlsVisible ? 1 : 0)
            .allowsHitTesting(false)
        }
    }
}

/// A heavily blurred, lightened copy of the current image behind it. Skipped for images with
/// transparent areas: there the "blur" would just be a giant copy of the shapes showing through. It fills the letterbox
/// with the photo's own colors, which is what the Liquid Glass controls refract.
struct AmbientBackdrop: View {
    let item: FileItem?
    @State private var image: NSImage?

    var body: some View {
        Color.clear
            .overlay {
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .blur(radius: 60, opaque: true)
                        .saturation(1.4)
                        .overlay(Color.white.opacity(0.3)) // keep it light
                        .id(ObjectIdentifier(image))
                        .transition(.opacity)
                }
            }
            .clipped()
            .animation(.easeInOut(duration: 0.4), value: image.map(ObjectIdentifier.init))
            .allowsHitTesting(false)
            .task(id: item?.url) {
                guard let item else {
                    image = nil
                    return
                }
                // A small thumbnail is plenty for a 60pt blur, and cheap to render.
                var thumbnail = ThumbnailLoader.shared.latest(for: item.url)
                if thumbnail == nil {
                    thumbnail = await ThumbnailLoader.shared.thumbnail(for: item, maxPixel: 128)
                }
                image = thumbnail.flatMap { Transparency.hasTransparentPixels($0) ? nil : $0 }
            }
    }
}

/// Status and actions for recognized text. Stays visible (doesn't auto-hide) while text mode is on.
struct TextRecognitionBar: View {
    @Environment(BrowserModel.self) private var model

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "text.viewfinder")
                .foregroundStyle(.tint)
            if model.isRecognizingText {
                ProgressView()
                    .controlSize(.small)
                Text("Recognizing text…")
            } else if model.recognizedLines.isEmpty {
                Text("No text found")
                    .foregroundStyle(.secondary)
            } else {
                Text(summary)
                    .monospacedDigit()
                Divider().frame(height: 16)
                Button("Copy") { model.copyRecognizedText() }
                    .disabled(model.selectedLineIDs.isEmpty)
                    .help("Copy the selected lines (⌘C)")
                Button("Copy All") { model.copyRecognizedText(all: true) }
                Button("Select All") { model.selectAllRecognizedText() }
                    .help("Select every line (⌘A)")
                Divider().frame(height: 16)
                Button {
                    model.showsExtractedText.toggle()
                } label: {
                    Image(systemName: model.showsExtractedText ? "eye" : "eye.slash")
                }
                .help(model.showsExtractedText ? "Peek at the original image under the text" : "Show the extracted text")
            }
            Button {
                model.isTextRecognitionOn = false
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .help("Hide text (Esc)")
        }
        .buttonStyle(.borderless)
        .font(.callout)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .glassSurface(in: Capsule())
    }

    private var summary: String {
        let count = model.recognizedLines.count
        let selected = model.selectedLineIDs.count
        let lines = "\(count) line\(count == 1 ? "" : "s")"
        return selected == 0 ? "\(lines) · click to select" : "\(lines) · \(selected) selected"
    }
}

/// AppKit's standard movie player (scrubber, volume, speed, PiP, AirPlay).
struct VideoPlayerView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .floating
        view.showsFullScreenToggleButton = false
        view.allowsPictureInPicturePlayback = true
        view.player = player
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        if view.player !== player {
            view.player = player
        }
    }
}

struct FilmstripView: View {
    @Environment(BrowserModel.self) private var model

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                LazyHStack(spacing: 4) {
                    ForEach(Array(model.images.enumerated()), id: \.element.id) { index, item in
                        ThumbnailView(item: item, size: 64)
                            .padding(4)
                            .background(
                                RoundedRectangle(cornerRadius: 10)
                                    .fill(index == model.viewerIndex ? Color.accentColor : .clear)
                            )
                            .contentShape(Rectangle())
                            .onTapGesture {
                                model.endTextEditing()
                                model.openImage(at: index)
                            }
                            .help(item.name)
                            .id(item.url)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
            }
            .scrollIndicators(.hidden)
            .frame(height: 88)
            .onChange(of: model.viewerIndex, initial: true) {
                guard let url = model.currentItem?.url else { return }
                withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(url, anchor: .center) }
            }
        }
    }
}
