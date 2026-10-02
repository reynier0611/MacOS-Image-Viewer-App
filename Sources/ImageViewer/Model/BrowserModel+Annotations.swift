import AppKit
import Foundation

/// Tags and notes, stored in each file's own metadata (see `Annotations`), not in the app.
extension BrowserModel {
    func annotations(for item: FileItem) -> Annotations {
        mediaInfo[item.url]?.annotations ?? Annotations()
    }

    /// Reads a file's metadata right away when background indexing hasn't reached it yet, so the
    /// inspector shows its tags and note immediately.
    func loadMediaInfoIfNeeded(_ items: [FileItem]) async {
        for item in items where mediaInfo[item.url] == nil && !item.isDirectory {
            let info = await MediaIndex.read(item)
            if mediaInfo[item.url] == nil { mediaInfo[item.url] = info }
        }
    }

    /// Every tag in the current listing, most used first: the suggestions while typing a tag.
    var knownTags: [String] {
        var counts: [String: (tag: String, count: Int)] = [:]
        for item in allImages {
            for tag in mediaInfo[item.url]?.annotations.tags ?? [] {
                counts[tag.lowercased(), default: (tag, 0)].count += 1
            }
        }
        return counts.values.sorted { $0.count != $1.count ? $0.count > $1.count : $0.tag < $1.tag }.map(\.tag)
    }

    /// Adds the tags typed in `text` ("beach, family") to `items`.
    func addTags(_ text: String, to items: [FileItem]) {
        let tags = Annotations.tags(from: text)
        guard !tags.isEmpty else { return }
        editAnnotations(tags.map { .addTag($0) }, on: items, actionName: "Add Tag")
    }

    func removeTag(_ tag: String, from items: [FileItem]) {
        editAnnotations([.removeTag(tag)], on: items, actionName: "Remove Tag")
    }

    func setNote(_ note: String, for item: FileItem) {
        editAnnotations([.setNote(note)], on: [item], actionName: "Edit Note")
    }

    private func editAnnotations(_ edits: [Annotations.Edit], on items: [FileItem], actionName: String) {
        let storable = items.filter(Annotations.canStore)
        guard !storable.isEmpty else { return }
        let apply = { [self] in
            applyAnnotationEdits(Dictionary(uniqueKeysWithValues: storable.map { ($0.url, edits) }), actionName: actionName)
        }
        if storable.allSatisfy({ mediaInfo[$0.url] != nil }) {
            apply()
        } else {
            Task {
                await loadMediaInfoIfNeeded(storable) // so Undo knows what was there before
                apply()
            }
        }
    }

    /// Shows the changes immediately, writes them into the files in the background, and registers
    /// the exact reverse for Undo (only for what actually changed in each file).
    func applyAnnotationEdits(_ edits: [URL: [Annotations.Edit]], actionName: String) {
        var applied: [URL: [Annotations.Edit]] = [:]
        var inverse: [URL: [Annotations.Edit]] = [:]
        var previous: [URL: Annotations] = [:]
        for (url, list) in edits {
            var current = mediaInfo[url]?.annotations ?? Annotations()
            previous[url] = current
            for edit in list {
                let next = current.applying(edit)
                guard next != current else { continue }
                applied[url, default: []].append(edit)
                inverse[url, default: []].insert(edit.inverse ?? .setNote(current.note), at: 0)
                current = next
            }
            mediaInfo[url, default: MediaInfo()].annotations = current
        }
        guard !applied.isEmpty else { return }
        if !currentFilter.tokens.isEmpty { refilter() }

        undoManager?.registerUndo(withTarget: self) { model in
            MainActor.assumeIsolated { model.applyAnnotationEdits(inverse, actionName: actionName) }
        }
        undoManager?.setActionName(actionName)

        let toWrite = applied
        enqueueMetadataWrite(Array(toWrite.keys), what: actionName == "Edit Note" ? "note" : "tags") { url in
            try Annotations.write(toWrite[url]!, to: url)
        } onFailure: { model, failed in
            for url in failed {
                model.mediaInfo[url, default: MediaInfo()].annotations = previous[url] ?? Annotations()
            }
        }
    }
}
