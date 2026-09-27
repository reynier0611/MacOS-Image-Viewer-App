# Image Viewer

A native macOS image viewer and browser (SwiftUI, macOS 14 Sonoma or later, Apple Silicon and Intel). Always uses the light theme, even when the Mac is in Dark Mode.

- Browse any folder as a grid of thumbnails, with a sidebar (Favorites, drives, recent folders) and a clickable path bar.
- Open an image to see it as large as the window allows. Use ← → to go through the folder, and Esc to go back to the grid.
- Zoom (pinch, ⌘= / ⌘-, double-click for 100%), drag to pan, full screen with **F**.
- Filmstrip under the viewer, and an inspector (⌘I) with file info, dimensions, camera EXIF and GPS (with "Show in Maps").
- Select several images in the grid (⌘-click, ⇧-click, ⌘A) and move them all to the Trash at once (⌘⌫). Undo (⌘Z) brings them all back. Also Rename, Copy Image, Copy Path, Reveal in Finder, Open in Preview, and Share/AirDrop.
- Sort by name, date or size. Changes made to the folder outside the app show up automatically.
- Open from Finder (right-click an image or folder, then **Open With ▸ Image Viewer**), drag onto the window or Dock icon, or use ⌘O.

## Build and install (this Mac)

Requires the Xcode Command Line Tools (`xcode-select --install`). The full Xcode app is not needed.

```sh
./install.sh        # builds a universal app and copies it to /Applications
```

`./build.sh` only builds `build/Image Viewer.app` and `build/ImageViewer.zip`.

## Install on your other MacBooks

The app isn't notarized by Apple, so pick one of these:

1. **Build it there** (simplest if the Command Line Tools are installed): copy this folder over and run `./install.sh`.
2. **Copy the prebuilt zip:** AirDrop `build/ImageViewer.zip` to the other Mac, then in Terminal:
   ```sh
   ./install.sh ~/Downloads/ImageViewer.zip
   ```
   Or do it by hand: unzip, drag it to Applications, then run
   `xattr -dr com.apple.quarantine "/Applications/Image Viewer.app"`.

   Without that last step, macOS says the app "can't be opened". You can also allow it under
   System Settings ▸ Privacy & Security ▸ **Open Anyway**.

The first time you browse Desktop, Documents, Downloads or an external drive, macOS asks for permission. Click Allow.

## Keyboard shortcuts

| In the grid | |
|---|---|
| ← → ↑ ↓ | Move selection |
| ⌘-click | Add or remove an image from the selection |
| ⇧-click | Add a range to the selection |
| ⌘A | Select all |
| Esc | Collapse a multi-selection to one item |
| Return / Space / ⌘↓ | Open image or folder |
| ⌘↑ | Enclosing folder |
| ⌘[ / ⌘] | Back / Forward |
| ⌘= / ⌘- | Bigger / smaller thumbnails |

| In the viewer | |
|---|---|
| ← → (or ↑ ↓) | Previous / next image |
| Home / End | First / last image |
| Esc or Space | Back to the grid |
| F | Full screen (hides the sidebar) |
| ⌘= / ⌘- | Zoom in / out |
| ⌘9 / ⌘0 | Zoom to fit / actual pixels |
| Double-click | Toggle fit ↔ 100% |

| Anywhere | |
|---|---|
| ⌘O | Open folder or image |
| ⇧⌘G | Go to folder by typing a path |
| ⌘I | Inspector (metadata) |
| ⌥⌘F | Filmstrip |
| ⌘⌫ | Move to Trash |
| ⌘Z | Undo trash / rename |
| ⇧⌘C / ⌥⌘C | Copy image / copy path |
| ⌘R | Reveal in Finder |
| ⇧⌘O | Open in Preview (for editing/markup) |
| ⇧⌘. | Show hidden files |

## Code layout

```
Sources/ImageViewer/
  ImageViewerApp.swift      App entry, window, Finder "Open With" handling
  BrowserModel.swift        All state: folder, selection, viewer, history, file ops, keyboard
  FileItem.swift            A folder or image in the listing
  ImageLoading.swift        Thumbnail and full-size decoding and caches (ImageIO)
  ImageMetadata.swift       EXIF / TIFF / GPS extraction for the inspector
  AppCommands.swift         Menu bar
  Views/                    Sidebar, grid, viewer (AppKit zoom view), inspector
```
