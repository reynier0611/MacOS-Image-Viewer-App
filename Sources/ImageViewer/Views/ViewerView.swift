import SwiftUI

struct ViewerView: View {
    @Environment(BrowserModel.self) private var model
    @State private var isHovering = false

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Color(white: 0.94)
                ZoomableImageView(
                    image: model.currentImage,
                    imageURL: model.displayedURL,
                    zoomRequest: model.zoomRequest,
                    enlargeSmallImages: model.enlargeSmallImages
                ) { model.zoomPercent = $0 }
                if let error = model.imageError {
                    ContentUnavailableView(error, systemImage: "exclamationmark.triangle")
                }
            }
            .overlay(alignment: .topTrailing) {
                if model.isLoadingImage {
                    ProgressView()
                        .controlSize(.small)
                        .padding(14)
                }
            }
            .overlay(alignment: .leading) {
                edgeButton("chevron.left", enabled: (model.viewerIndex ?? 0) > 0) { model.step(-1) }
            }
            .overlay(alignment: .trailing) {
                edgeButton("chevron.right", enabled: (model.viewerIndex ?? 0) < model.images.count - 1) { model.step(1) }
            }
            .overlay(alignment: .bottomLeading) { infoPill }
            .onHover { isHovering = $0 }

            if model.showFilmstrip && model.images.count > 1 {
                FilmstripView()
            }
        }
    }

    private func edgeButton(_ symbol: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        let visible = isHovering && enabled
        return Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 20, weight: .semibold))
                .frame(width: 40, height: 72)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white)
        .background(.black.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
        .padding(14)
        .opacity(visible ? 1 : 0)
        .allowsHitTesting(visible)
        .animation(.easeInOut(duration: 0.15), value: visible)
    }

    @ViewBuilder
    private var infoPill: some View {
        if let image = model.currentImage, model.imageError == nil {
            HStack(spacing: 8) {
                Text("\(Int(image.size.width)) × \(Int(image.size.height))")
                if let zoom = model.zoomPercent {
                    Text("\(zoom)%")
                }
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.white.opacity(0.9))
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(.black.opacity(0.45), in: Capsule())
            .padding(12)
            .opacity(isHovering ? 1 : 0)
            .animation(.easeInOut(duration: 0.15), value: isHovering)
            .allowsHitTesting(false)
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
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(index == model.viewerIndex ? Color.accentColor : .clear)
                            )
                            .contentShape(Rectangle())
                            .onTapGesture { model.openImage(at: index) }
                            .help(item.name)
                            .id(item.url)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
            }
            .scrollIndicators(.hidden)
            .frame(height: 84)
            .background(Color(white: 0.985))
            .overlay(alignment: .top) { Divider() }
            .onChange(of: model.viewerIndex, initial: true) {
                guard let url = model.currentItem?.url else { return }
                withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(url, anchor: .center) }
            }
        }
    }
}
