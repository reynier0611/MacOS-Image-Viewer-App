import SwiftUI

extension View {
    /// Liquid Glass on macOS 26 (Tahoe); a frosted material on macOS 14–15.
    @ViewBuilder
    func glassSurface<S: Shape>(in shape: S, interactive: Bool = false) -> some View {
        if #available(macOS 26.0, *) {
            glassEffect(interactive ? .regular.interactive() : .regular, in: shape)
        } else {
            background(.regularMaterial, in: shape)
                .overlay(shape.stroke(.white.opacity(0.5), lineWidth: 0.5))
                .shadow(color: .black.opacity(0.15), radius: 8, y: 3)
        }
    }

    /// Groups nearby glass shapes so they blend together on macOS 26.
    @ViewBuilder
    func glassGroup(spacing: CGFloat = 20) -> some View {
        if #available(macOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) { self }
        } else {
            self
        }
    }
}
