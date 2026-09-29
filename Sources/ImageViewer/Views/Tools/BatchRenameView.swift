import AppKit
import SwiftUI

struct BatchRenameView: View {
    @Environment(BrowserModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var items: [FileItem] = []
    @State private var dates: [URL: Date] = [:]
    @State private var template = "{date}_{n}"
    @State private var start = 1
    @State private var digits = 3

    private static let tokens = ["{name}", "{n}", "{date}", "{time}", "{year}", "{month}", "{day}"]

    private var plans: [RenamePlan] {
        BrowserModel.renamePlans(for: items, template: template, start: start, digits: digits, dates: dates)
    }

    var body: some View {
        let plans = plans
        let problem = items.isEmpty ? nil : BrowserModel.problem(with: plans)
        VStack(alignment: .leading, spacing: 14) {
            Text("Rename \(items.count) Item\(items.count == 1 ? "" : "s")")
                .font(.title3.bold())

            TextField("Pattern", text: $template)
                .textFieldStyle(.roundedBorder)
                .font(.body.monospaced())
            HStack(spacing: 6) {
                Text("Insert:")
                    .foregroundStyle(.secondary)
                ForEach(Self.tokens, id: \.self) { token in
                    Button(token) { template += token }
                        .controlSize(.small)
                }
            }
            HStack(spacing: 24) {
                Stepper("Start at \(start)", value: $start, in: 0...99_999)
                Stepper("Digits: \(digits)", value: $digits, in: 1...6)
            }

            List(plans.prefix(500)) { plan in
                HStack {
                    Text(plan.item.name)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Image(systemName: "arrow.right")
                        .foregroundStyle(.tertiary)
                    Text(plan.newName)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .listStyle(.bordered)

            if let problem {
                Label(problem, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
            }
            HStack {
                Text("{date} and {time} are when each photo was taken. Undo with ⌘Z.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Rename") {
                    model.applyBatchRename(plans)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(problem != nil || items.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 600, height: 540)
        .task {
            items = model.batchTargets
            dates = await BrowserModel.captureDates(for: items, known: model.mediaInfo)
        }
    }
}

// MARK: - Export
