import SwiftUI

/// The floating Adjust Color panel on the right of the viewer.
struct AdjustPanel: View {
    @Environment(BrowserModel.self) private var model

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Adjust Color")
                    .font(.headline)
                Spacer()
                compareButton
            }
            Toggle(isOn: $model.adjustments.auto) {
                Label("Auto Enhance", systemImage: "sparkles")
            }
            .toggleStyle(.button)
            .help("Apple's automatic exposure, color and contrast correction")

            group("Light") {
                row("Exposure", $model.adjustments.exposure)
                row("Contrast", $model.adjustments.contrast)
                row("Highlights", $model.adjustments.highlights)
                row("Shadows", $model.adjustments.shadows)
            }
            group("Color") {
                row("Saturation", $model.adjustments.saturation)
                row("Vibrance", $model.adjustments.vibrance)
                row("Temperature", $model.adjustments.temperature)
                row("Tint", $model.adjustments.tint)
            }
            group("Detail") {
                row("Sharpness", $model.adjustments.sharpness, range: 0...1)
            }

            HStack {
                Button("Reset") { model.adjustments = Adjustments() }
                    .disabled(model.adjustments.isUnchanged)
                Spacer()
                Button("Cancel") { model.endAdjusting() }
                Button("Save…") { model.saveAdjustments() }
                    .keyboardShortcut("s")
                    .buttonStyle(.borderedProminent)
                    .disabled(model.adjustments.isUnchanged || model.isSavingAdjustments)
            }
            if model.isSavingAdjustments {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Saving at full resolution…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(16)
        .frame(width: 270)
        .glassSurface(in: RoundedRectangle(cornerRadius: 20))
    }

    /// Hold to see the original.
    private var compareButton: some View {
        Image(systemName: model.isShowingOriginal ? "eye.slash" : "eye")
            .frame(width: 26, height: 22)
            .contentShape(Rectangle())
            .foregroundStyle(model.adjustments.isUnchanged ? .tertiary : .primary)
            .onLongPressGesture(minimumDuration: 0, perform: {}, onPressingChanged: { pressing in
                model.isShowingOriginal = pressing
            })
            .help("Hold to compare with the original")
    }

    private func group<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title.uppercased())
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            content()
        }
    }

    private func row(_ title: String, _ value: Binding<Double>, range: ClosedRange<Double> = -1...1) -> some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.callout)
                .frame(width: 82, alignment: .leading)
            Slider(value: value, in: range)
                .controlSize(.small)
            // Click the number to put that slider back to zero.
            Button {
                value.wrappedValue = 0
            } label: {
                Text(value.wrappedValue == 0 ? "0" : String(format: "%+.0f", value.wrappedValue * 100))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(value.wrappedValue == 0 ? .tertiary : .secondary)
                    .frame(width: 30, alignment: .trailing)
            }
            .buttonStyle(.plain)
            .help("Reset \(title)")
        }
    }
}
