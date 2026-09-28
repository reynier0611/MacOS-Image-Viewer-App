# Image Viewer

A native macOS image viewer and browser (SwiftUI, macOS 14 Sonoma or later, Apple Silicon and Intel). Always uses the light theme, even when the Mac is in Dark Mode. On macOS 26 (Tahoe) the floating controls use Liquid Glass; older macOS versions get a frosted-glass look instead.

- Opens every image format macOS can decode (JPEG, PNG, HEIC, WebP, AVIF, JPEG XL, TIFF, GIF, BMP, PSD, EXR, SVG, and camera RAW such as CR2/CR3, NEF, ARW, DNG, RAF) and plays videos (MOV, MP4, M4V; H.264, HEVC, ProRes). Space plays/pauses a video.
- Browse any folder as a grid of thumbnails, with a sidebar (Favorites, drives, recent folders) and a clickable path bar.
- Open an image to see it as large as the window allows. Use ← → to go through the folder, and Esc to go back to the grid.
- Zoom (pinch, ⌘= / ⌘-, double-click for 100%), drag to pan, full screen with **F**.
- In the viewer, the arrows, info and filmstrip float over the image and fade out when the mouse rests.
- Filmstrip under the viewer, and an inspector (⌘I) with file info, dimensions, camera EXIF and GPS (with "Show in Maps").
- Select several images in the grid by dragging a rectangle over them (the grid scrolls when you reach the top or bottom edge), ⌘-click, ⇧-click or ⌘A.
- Move the selection to another folder: drag it onto a folder tile, a sidebar folder or a folder in the path bar. You can also right-click ▸ **Move to** (subfolders, the enclosing folder, recent destinations, or Choose Folder…) or use **New Folder with Selection** (⌃⌘N). A name clash never overwrites: the incoming file becomes “name 2.jpg”.
- Move the selection to the Trash (⌘⌫). Undo (⌘Z) reverses any move or trash, including a whole batch. Also Rename, Copy Image, Copy Path, Reveal in Finder, Open in Preview, and Share/AirDrop.
- Sort by name, date taken, date modified/created or size. Changes made to the folder outside the app show up automatically.
- **Search** (toolbar) matches file names *and what's in the photo*, like "beach", "dog" or "sky". Recognition runs on this Mac with Apple's Vision framework and is cached, so each photo is analyzed once. **Filter** by type (photos, videos, RAW) and by date taken (today, last 7/30 days, this year, last year, or a custom range).
- **Rotate and flip** without losing quality (⌘L / ⌘R). Only the file's orientation tag changes, so pixels are never re-compressed. Works on JPEG, HEIC, PNG and TIFF, one image or a whole selection, with undo. Camera RAW files can't be rotated in place.
- **Find Duplicates** (⌥⌘D) finds identical copies and visually similar photos (Strict / Normal / Loose), suggests the best copy, and moves the rest to the Trash after you review them.
- **Batch Rename** (⇧⌘R) renames a selection with a pattern such as `{date}_{n}` (tokens: `{name} {n} {date} {time} {year} {month} {day}`), with a live preview. Undo reverses the whole batch.
- **Export** (⌘E) saves copies as JPEG, HEIC, PNG or TIFF, optionally resized, keeping camera details and removing location by default. Originals are never changed.
- The inspector can also show a **histogram** and a **map** of where photos were taken, for one photo or a whole selection. Both are off by default: turn them on with the buttons at the top of the inspector.
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
| Drag on empty space | Select with a rectangle (hold ⌘ to add) |
| Click empty space | Deselect all |
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
| ⇧⌘M | Move to Folder… |
| ⌃⌘N | New Folder with Selection… |
| ⌘Z | Undo trash / rename |
| ⇧⌘C / ⌥⌘C | Copy image / copy path |
| ⌥⌘R | Reveal in Finder |
| ⌘L / ⌘R | Rotate left / right |
| ⇧⌘R | Batch rename… |
| ⌘E | Export… |
| ⌥⌘D | Find duplicates… |
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
