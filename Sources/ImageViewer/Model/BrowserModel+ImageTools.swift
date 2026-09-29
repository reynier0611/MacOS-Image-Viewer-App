import AVFoundation
import AppKit
import Observation
import SwiftUI
import UniformTypeIdentifiers

/// Rotate/flip, batch rename, and export.
extension BrowserModel {
    // MARK: Rotate & flip

    /// Rotates or flips the open image, or every selected image, without re-compressing.
    func changeOrientation(_ change: OrientationChange, item: FileItem? = nil) {
        let targets = fileActionTargets(for: item).filter { !$0.isVideo }
        applyOrientation(change, to: targets.map(\.url))
    }

    func applyOrientation(_ change: OrientationChange, to urls: [URL]) {
        guard !urls.isEmpty else { return }
        var changed: [URL] = []
        var failures: [String] = []
        for url in urls {
            do {
                try ImageEditing.changeOrientation(of: url, by: change)
                changed.append(url)
            } catch {
                failures.append(error.localizedDescription)
            }
        }
        if !changed.isEmpty {
            for url in changed {
                ImageLoader.shared.invalidate(url)
                ThumbnailLoader.shared.invalidate(url)
                textCache[url] = nil
                if recognizedURL == url { recognizedURL = nil }
            }
            let viewing = displayedURL.flatMap { changed.contains($0) ? $0 : nil }
            if viewing != nil {
                displayedURL = nil // force the viewer to decode the new orientation
            }
            load(select: selection, viewing: viewing ?? (isViewing ? displayedURL : nil), fallbackIndex: viewerIndex)
            undoManager?.registerUndo(withTarget: self) { model in
                MainActor.assumeIsolated { model.applyOrientation(change.inverse, to: changed) }
            }
            undoManager?.setActionName(change.rawValue)
        }
        if !failures.isEmpty {
            errorMessage = failures.count == 1 ? failures[0] : "\(failures.count) images couldn't be changed.\n" + failures.joined(separator: "\n")
        }
    }

    // MARK: Batch rename

    /// Images the batch tools (rename, export) work on: the open image, or the selection in the grid.
    var batchTargets: [FileItem] {
        fileActionTargets().filter { !$0.isDirectory }
    }

    /// Date taken for each item, reading metadata directly for anything not indexed yet.
    nonisolated static func captureDates(for items: [FileItem], known: [URL: MediaInfo]) async -> [URL: Date] {
        var dates: [URL: Date] = [:]
        for item in items {
            let date = known[item.url]?.captureDate
                ?? (item.isVideo ? nil : MediaIndex.readImage(item.url).captureDate)
            dates[item.url] = date ?? min(item.created, item.modified)
        }
        return dates
    }

    /// Tokens: {name} original name, {n} counter, {date} 2026-09-28, {time} 143012,
    /// {year} {month} {day}. The extension is always kept.
    nonisolated static func renamePlans(
        for items: [FileItem], template: String, start: Int, digits: Int, dates: [URL: Date]
    ) -> [RenamePlan] {
        let dateFormat = DateFormatter()
        dateFormat.locale = Locale(identifier: "en_US_POSIX")
        func format(_ date: Date, _ pattern: String) -> String {
            dateFormat.dateFormat = pattern
            return dateFormat.string(from: date)
        }
        return items.enumerated().map { index, item in
            let date = dates[item.url] ?? min(item.created, item.modified)
            let counter = String(format: "%0\(max(1, digits))d", start + index)
            var base = template
                .replacingOccurrences(of: "{name}", with: item.url.deletingPathExtension().lastPathComponent)
                .replacingOccurrences(of: "{n}", with: counter)
                .replacingOccurrences(of: "{date}", with: format(date, "yyyy-MM-dd"))
                .replacingOccurrences(of: "{time}", with: format(date, "HHmmss"))
                .replacingOccurrences(of: "{year}", with: format(date, "yyyy"))
                .replacingOccurrences(of: "{month}", with: format(date, "MM"))
                .replacingOccurrences(of: "{day}", with: format(date, "dd"))
            base = base.trimmingCharacters(in: .whitespaces)
            let ext = item.url.pathExtension
            return RenamePlan(item: item, newName: ext.isEmpty ? base : "\(base).\(ext)")
        }
    }

    /// Why the plan can't be applied, or nil if it's fine.
    nonisolated static func problem(with plans: [RenamePlan]) -> String? {
        var seen: Set<String> = []
        let sources = Set(plans.map { $0.item.url.path.lowercased() })
        for plan in plans {
            let base = (plan.newName as NSString).deletingPathExtension
            if base.isEmpty { return "A name would be empty." }
            if plan.newName.contains("/") || plan.newName.contains(":") { return "Names can't contain “/” or “:”." }
            if plan.newName.hasPrefix(".") { return "Names can't start with a period." }
            let key = plan.newName.lowercased()
            if !seen.insert(key).inserted { return "Two files would both be named “\(plan.newName)”. Add {n} to the pattern." }
            let destination = plan.item.url.deletingLastPathComponent().appendingPathComponent(plan.newName)
            if FileManager.default.fileExists(atPath: destination.path), !sources.contains(destination.path.lowercased()) {
                return "“\(plan.newName)” already exists in this folder."
            }
        }
        return nil
    }

    func applyBatchRename(_ plans: [RenamePlan]) {
        let moves = plans
            .filter { $0.newName != $0.item.name }
            .map { (from: $0.item.url, to: $0.item.url.deletingLastPathComponent().appendingPathComponent($0.newName)) }
        guard !moves.isEmpty, Self.problem(with: plans) == nil else { return }
        let sources = Set(moves.map { $0.from.path.lowercased() })
        // Renames that swap names, or only change letter case, go through temporary names first.
        // Both phases happen in one event, so ⌘Z undoes the whole batch in one step.
        if moves.contains(where: { sources.contains($0.to.path.lowercased()) }) {
            let temporary = moves.map { move in
                (from: move.from, to: move.from.deletingLastPathComponent()
                    .appendingPathComponent(".rename-\(UUID().uuidString).\(move.from.pathExtension)"))
            }
            applyMoves(temporary)
            applyMoves(zip(temporary, moves).map { (from: $0.0.to, to: $0.1.to) })
        } else {
            applyMoves(moves)
        }
        undoManager?.setActionName("Rename \(moves.count) Items")
        showToast("Renamed \(moves.count) item\(moves.count == 1 ? "" : "s")", canUndo: true)
    }

    // MARK: Export

    func runExport(
        _ items: [FileItem], options: ExportOptions, to directory: URL,
        progress: @escaping @MainActor (Int) -> Void
    ) async -> [String] {
        var failures: [String] = []
        for (index, item) in items.enumerated() where !item.isVideo {
            if Task.isCancelled { break }
            let url = item.url
            do {
                _ = try await Task.detached(priority: .userInitiated) {
                    try Exporter.export(url, to: directory, options: options)
                }.value
            } catch {
                failures.append("“\(item.name)”: \(error.localizedDescription)")
            }
            progress(index + 1)
        }
        let exported = items.filter { !$0.isVideo }.count - failures.count
        if exported > 0 {
            showToast("Exported \(exported) image\(exported == 1 ? "" : "s") to “\(FileManager.default.displayName(atPath: directory.path))”", canUndo: false)
        }
        return failures
    }
}
