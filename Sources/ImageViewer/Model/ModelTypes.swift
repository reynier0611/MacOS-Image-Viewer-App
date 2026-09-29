import AVFoundation
import AppKit
import Observation
import SwiftUI
import UniformTypeIdentifiers

enum ZoomAction: Equatable {
    case fit, actualSize, zoomIn, zoomOut
}

struct ZoomRequest: Equatable {
    let action: ZoomAction
    let id = UUID()
}

struct MoveDestination: Identifiable {
    let title: String
    let url: URL
    var id: String { url.path }
}

extension UTType {
    /// Drag payload for images dragged within the app (the actual URLs live in `BrowserModel.draggedItems`).
    static let imageViewerSelection = UTType(exportedAs: "local.imageviewer.selection")
}

enum MediaTypeFilter: String, CaseIterable, Identifiable {
    case all = "All"
    case photos = "Photos"
    case videos = "Videos"
    case raw = "RAW"
    var id: String { rawValue }
}

enum DateFilter: String, CaseIterable, Identifiable {
    case any = "Any Date"
    case today = "Today"
    case last7Days = "Last 7 Days"
    case last30Days = "Last 30 Days"
    case thisYear = "This Year"
    case lastYear = "Last Year"
    case custom = "Custom Range…"
    var id: String { rawValue }

    func range(from: Date, to: Date) -> ClosedRange<Date> {
        let calendar = Calendar.current
        let now = Date()
        let today = calendar.startOfDay(for: now)
        let year = calendar.component(.year, from: now)
        func startOfYear(_ y: Int) -> Date { calendar.date(from: DateComponents(year: y, month: 1, day: 1))! }
        switch self {
        case .any: return Date.distantPast...Date.distantFuture
        case .today: return today...now
        case .last7Days: return calendar.date(byAdding: .day, value: -7, to: today)!...now
        case .last30Days: return calendar.date(byAdding: .day, value: -30, to: today)!...now
        case .thisYear: return startOfYear(year)...now
        case .lastYear: return startOfYear(year - 1)...startOfYear(year).addingTimeInterval(-1)
        case .custom:
            let start = calendar.startOfDay(for: min(from, to))
            let end = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: max(from, to)))!.addingTimeInterval(-1)
            return start...end
        }
    }
}

/// Where the app starts when opened on its own (not by opening a file or folder).
enum LaunchFolder: String, CaseIterable, Identifiable {
    case home = "Home"
    case pictures = "Pictures"
    case desktop = "Desktop"
    case custom = "Other…"
    var id: String { rawValue }
}

enum ViewerBackground: String, CaseIterable, Identifiable {
    /// A blurred copy of the photo fills the space around it (gives the glass controls color).
    case blurredPhoto = "Blurred photo"
    case plain = "Plain"
    var id: String { rawValue }
}

struct RenamePlan: Identifiable {
    let item: FileItem
    let newName: String
    var id: URL { item.url }
}

struct Toast: Identifiable, Equatable {
    let id = UUID()
    let message: String
    let canUndo: Bool
}

/// The search and filter rules, independent of app state so they can be tested directly.
struct MediaFilter {
    var type: MediaTypeFilter = .all
    /// Allowed "date taken" range; nil means any date.
    var dates: ClosedRange<Date>?
    /// Lowercased search words; every word must match.
    var tokens: [String] = []

    init(type: MediaTypeFilter = .all, dates: ClosedRange<Date>? = nil, searchText: String = "") {
        self.type = type
        self.dates = dates
        tokens = searchText.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
    }

    /// Every word must appear in the file name or in something recognized in the photo.
    func matches(_ item: FileItem, captureDate: Date, labels: [String]) -> Bool {
        switch type {
        case .all: break
        case .photos: if item.isVideo { return false }
        case .videos: if !item.isVideo { return false }
        case .raw: if !item.isRaw { return false }
        }
        if let dates, !dates.contains(captureDate) { return false }
        let name = item.name.lowercased()
        return tokens.allSatisfy { token in
            name.contains(token) || labels.contains { $0.contains(token) }
        }
    }

    /// Folders stay visible unless a search is typed; then they must match by name.
    func matchesFolder(_ folder: FileItem) -> Bool {
        tokens.allSatisfy { folder.name.lowercased().contains($0) }
    }
}
