import AppKit
import Foundation

/// Star ratings, stored in each image file's own metadata (see `Ratings`), not in the app.
extension BrowserModel {
    func rating(for item: FileItem) -> Int {
        mediaInfo[item.url]?.rating ?? 0
    }

    /// The open image, or the selected images in the grid.
    var ratingTargets: [FileItem] {
        fileActionTargets().filter { !$0.isDirectory }
    }

    /// Sets the rating (0 clears, −1 rejects) on the open image or every selected image.
    func setRating(_ rating: Int, for items: [FileItem]? = nil) {
        let targets = items ?? ratingTargets
        let storable = targets.filter(Ratings.canStore)
        let skipped = targets.count - storable.count
        guard !storable.isEmpty else {
            if skipped > 0 {
                showToast("Ratings can't be saved in \(skipped == 1 ? "this file type" : "these file types") (RAW and video aren't supported yet)", canUndo: false)
            }
            return
        }
        let previous = Dictionary(uniqueKeysWithValues: storable.map { ($0.url, self.rating(for: $0)) })
        applyRatings(Dictionary(uniqueKeysWithValues: storable.map { ($0.url, rating) }), previous: previous)

        var message = "\(Ratings.stars(rating))" + (storable.count > 1 ? " · \(storable.count) photos" : "")
        if skipped > 0 { message += " (\(skipped) skipped: RAW/video)" }
        showToast(message, canUndo: storable.count > 1)
    }

    /// X: rejects the targets, or un-rejects them if they're all rejected already.
    func toggleReject() {
        let targets = ratingTargets.filter(Ratings.canStore)
        let allRejected = !targets.isEmpty && targets.allSatisfy { rating(for: $0) == Ratings.rejected }
        setRating(allRejected ? 0 : Ratings.rejected, for: targets)
    }

    /// Shows the new ratings immediately, writes them into the files in the background (in order),
    /// and registers the old ratings for Undo. A failed write puts the old value back.
    func applyRatings(_ ratings: [URL: Int], previous: [URL: Int]) {
        for (url, rating) in ratings {
            mediaInfo[url, default: MediaInfo()].rating = rating
        }
        ratingsChanged()

        undoManager?.registerUndo(withTarget: self) { model in
            MainActor.assumeIsolated { model.applyRatings(previous, previous: ratings) }
        }
        undoManager?.setActionName("Rating")

        let earlier = ratingWrites
        ratingWrites = Task { [weak self] in
            await earlier?.value
            let failures = await Task.detached(priority: .userInitiated) {
                ratings.compactMap { url, rating -> (URL, String)? in
                    do {
                        try Ratings.write(rating, to: url)
                        return nil
                    } catch {
                        return (url, error.localizedDescription)
                    }
                }
            }.value
            guard let self, !failures.isEmpty else { return }
            for (url, _) in failures {
                self.mediaInfo[url, default: MediaInfo()].rating = previous[url] ?? 0
            }
            self.ratingsChanged()
            self.errorMessage = "Couldn't save the rating in \(failures.count) file\(failures.count == 1 ? "" : "s").\n"
                + failures.map { "“\($0.0.lastPathComponent)”: \($0.1)" }.joined(separator: "\n")
        }
    }

    /// Waits until every requested rating has been written to disk (used by tests).
    func finishRatingWrites() async {
        await ratingWrites?.value
    }

    private func ratingsChanged() {
        if sortKey == .rating {
            applySort()
        } else if ratingFilter != .any {
            refilter()
        }
    }
}
