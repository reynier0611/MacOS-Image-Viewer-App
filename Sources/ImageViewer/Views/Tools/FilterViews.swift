import AppKit
import SwiftUI

struct FilterButton: View {
    @Environment(BrowserModel.self) private var model
    @State private var isPresented = false

    var body: some View {
        Button { isPresented.toggle() } label: {
            Label(
                "Filter",
                systemImage: model.hasActiveFilters ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle"
            )
        }
        .help("Filter by type and date taken")
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            FilterPanel()
                .padding(16)
                .frame(width: 320)
        }
    }
}

struct FilterPanel: View {
    @Environment(BrowserModel.self) private var model

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 14) {
            Picker("Show", selection: $model.typeFilter) {
                ForEach(MediaTypeFilter.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)

            Picker("Rating", selection: $model.ratingFilter) {
                ForEach(RatingFilter.allCases) { Text($0.rawValue).tag($0) }
            }
            Picker("Taken", selection: $model.dateFilter) {
                ForEach(DateFilter.allCases) { Text($0.rawValue).tag($0) }
            }
            if model.dateFilter == .custom {
                DatePicker("From", selection: $model.customDateFrom, displayedComponents: .date)
                DatePicker("To", selection: $model.customDateTo, displayedComponents: .date)
            }
            Text("“Taken” uses the date stored in the photo or video, or the file's date when there isn't one.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Clear Filters") { model.clearFilters() }
                    .disabled(!model.isFiltering)
            }
        }
    }
}

/// Shown above the grid while a search or filter hides some items.
struct FilterStatusBar: View {
    @Environment(BrowserModel.self) private var model

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "line.3.horizontal.decrease.circle.fill")
                .foregroundStyle(.tint)
            Text("Showing \(model.images.count) of \(model.allImages.count)")
                .fontWeight(.medium)
            ForEach(chips, id: \.self) { chip in
                Text(chip)
                    .font(.caption)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(.tint.opacity(0.15), in: Capsule())
            }
            if model.isAnalyzingContent {
                ProgressView(value: Double(model.contentAnalysisDone), total: Double(max(1, model.contentAnalysisTotal)))
                    .frame(width: 70)
                Text("Recognizing contents…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Button("Clear") { model.clearFilters() }
                .buttonStyle(.borderless)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .glassSurface(in: Capsule())
    }

    private var chips: [String] {
        var chips: [String] = []
        let search = model.searchText.trimmingCharacters(in: .whitespaces)
        if !search.isEmpty { chips.append("“\(search)”") }
        if model.typeFilter != .all { chips.append(model.typeFilter.rawValue) }
        if model.ratingFilter != .any { chips.append(model.ratingFilter.rawValue) }
        if model.dateFilter == .custom {
            chips.append("\(model.customDateFrom.formatted(date: .abbreviated, time: .omitted)) – \(model.customDateTo.formatted(date: .abbreviated, time: .omitted))")
        } else if model.dateFilter != .any {
            chips.append(model.dateFilter.rawValue)
        }
        return chips
    }
}

// MARK: - Tools menu
