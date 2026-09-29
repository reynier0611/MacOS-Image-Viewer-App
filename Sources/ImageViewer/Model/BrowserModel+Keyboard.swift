import AVFoundation
import AppKit
import Observation
import SwiftUI
import UniformTypeIdentifiers

/// Plain-key handling (arrows, space, escape…). Command shortcuts live in AppCommands.
extension BrowserModel {
    // MARK: Keyboard

    func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            return MainActor.assumeIsolated { self.handleKey(event) } ? nil : event
        }
    }

    /// Plain (unmodified) keys. Command shortcuts live in the menus (see AppCommands).
    func handleKey(_ event: NSEvent) -> Bool {
        guard let window = event.window,
              !(window is NSPanel),
              window.attachedSheet == nil,
              window.sheetParent == nil
        else { return false }
        if let editor = window.firstResponder as? NSTextView {
            // In the toolbar search field, ↓ (like Finder) and Return move on to the results.
            if editor.delegate is NSSearchField, [125, 36, 76].contains(event.keyCode) {
                endTextEditing(in: window)
                return true
            }
            return false // typing in a text field: leave the keys alone
        }
        if window.firstResponder is NSText { return false }

        let modifiers = event.modifierFlags
            .intersection(.deviceIndependentFlagsMask)
            .subtracting([.numericPad, .function, .capsLock])
        if modifiers == .command, event.charactersIgnoringModifiers == "a", !isViewing {
            selectAll()
            return true
        }
        guard modifiers.isEmpty else { return false }

        switch event.keyCode {
        case 123: step(-1) // ←
        case 124: step(1) // →
        case 125: isViewing ? step(1) : moveSelection(by: gridColumns) // ↓
        case 126: isViewing ? step(-1) : moveSelection(by: -gridColumns) // ↑
        case 36, 76: // return / enter
            guard !isViewing else { return false }
            openSelection()
        case 49: // space: play/pause a video, otherwise open/close the viewer
            if videoPlayer != nil { togglePlayback() } else { toggleViewer() }
        case 53: // escape
            if isTextRecognitionOn {
                isTextRecognitionOn = false
            } else if isViewing {
                closeViewer()
            } else if selectedURLs.count > 1 {
                selectedURLs = selection.map { [$0] } ?? [] // collapse to the focused item
            } else {
                return false
            }
        case 115: showFirst() // home
        case 119: showLast() // end
        default:
            if event.charactersIgnoringModifiers == "f" {
                toggleFullScreen()
            } else {
                return false
            }
        }
        return true
    }
}
