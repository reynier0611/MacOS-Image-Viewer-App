import SwiftUI

/// Small stars shown on a thumbnail; a red mark for rejected photos.
struct RatingBadge: View {
    let rating: Int

    var body: some View {
        if rating == Ratings.rejected {
            Image(systemName: "xmark")
                .font(.caption2.bold())
                .foregroundStyle(.white)
                .padding(4)
                .background(.red, in: Circle())
                .help("Rejected")
        } else if rating > 0 {
            Text(String(repeating: "★", count: rating))
                .font(.caption2)
                .foregroundStyle(.yellow)
                .shadow(color: .black.opacity(0.6), radius: 1)
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(.black.opacity(0.35), in: Capsule())
                .help("\(rating) star\(rating == 1 ? "" : "s")")
        }
    }
}

/// Clickable stars, plus a ✕ that clears the rating. The ✕ only appears when there is a rating
/// (or a rejection, set with the X key) to clear; without it the stars sit centered.
struct RatingControl: View {
    let rating: Int
    /// Toolbar size instead of the larger standalone size.
    var compact = false
    let set: (Int) -> Void

    var body: some View {
        HStack(spacing: 2) {
            ForEach(1...5, id: \.self) { star in
                Button {
                    set(star)
                } label: {
                    Image(systemName: star <= rating ? "star.fill" : "star")
                        .foregroundStyle(star <= rating ? .yellow : .secondary)
                }
                .help("\(star) star\(star == 1 ? "" : "s") (press \(star))")
            }
            if rating == Ratings.rejected {
                Text("Rejected")
                    .font(.caption.bold())
                    .foregroundStyle(.red)
                    .padding(.leading, 4)
            }
            if rating != 0 {
                Button {
                    set(0)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .help(rating == Ratings.rejected ? "Clear the rejection (press 0)" : "Clear the rating (press 0)")
                .padding(.leading, 4)
            }
        }
        .buttonStyle(.borderless)
        .font(compact ? .body : .title3)
        .padding(.horizontal, compact ? 6 : 0)
    }
}

/// Rating commands for menus.
struct RatingMenuItems: View {
    @Environment(BrowserModel.self) private var model
    var items: [FileItem]?

    var body: some View {
        Button("No Rating  (0)") { model.setRating(0, for: items) }
        ForEach(1...5, id: \.self) { stars in
            Button("\(String(repeating: "★", count: stars))  (\(stars))") { model.setRating(stars, for: items) }
        }
        Divider()
        Button("Reject  (X)") { model.setRating(Ratings.rejected, for: items) }
    }
}
