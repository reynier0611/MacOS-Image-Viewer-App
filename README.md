# Image Viewer

A native macOS image viewer and browser (SwiftUI, macOS 14 Sonoma or later, Apple Silicon and Intel). Always uses the light theme, even when the Mac is in Dark Mode. On macOS 26 (Tahoe) the floating controls use Liquid Glass; older macOS versions get a frosted-glass look instead.

- Opens every image format macOS can decode (JPEG, PNG, HEIC, WebP, AVIF, JPEG XL, TIFF, GIF, BMP, PSD, EXR, SVG, and camera RAW such as CR2/CR3, NEF, ARW, DNG, RAF) and plays videos (MOV, MP4, M4V; H.264, HEVC, ProRes). Space plays/pauses a video.
- Browse any folder as a grid of thumbnails. The sidebar is a **folder tree** (Home, iCloud Drive and every drive): expand folders with ▸ to see subfolders, click one to open it. The tree opens itself to whatever folder you're in. Drop photos on a tree folder to move them there; right-click for Rename and Reveal in Finder. There's also a clickable path bar. Opened on its own, the app always starts in your home folder; it doesn't remember where you were.
- Open an image to see it as large as the window allows. Use ← → to go through the folder, and Esc to go back to the grid.
- Zoom (pinch, ⌘= / ⌘-, double-click for 100%), drag to pan, full screen with **F**.
- In the viewer, the arrows and info float over the image and fade out when the mouse rests. The filmstrip stays hidden, so the whole image is visible, until you move the pointer to the bottom edge.
- Filmstrip under the viewer, and an inspector (⌘I) with file info, dimensions, camera EXIF and GPS (with "Show in Maps").
- Select several images in the grid by dragging a rectangle over them (the grid scrolls when you reach the top or bottom edge), ⌘-click, ⇧-click or ⌘A.
- Move the selection to another folder: drag it onto a folder tile, a sidebar folder or a folder in the path bar. You can also right-click ▸ **Move to** (subfolders, the enclosing folder, recent destinations, or Choose Folder…) or use **New Folder with Selection** (⌃⌘N). A name clash never overwrites: the incoming file becomes “name 2.jpg”.
- Move the selection to the Trash (⌘⌫), including **folders** (from the grid or by right-clicking in the sidebar; you're asked to confirm first). Home, drives and standard folders like Desktop are protected. Undo (⌘Z) reverses any move or trash, including a whole batch. Also Rename, Copy Image, Copy Path, Reveal in Finder, Open in Preview, and Share/AirDrop.
- **Star ratings saved inside the photo**: press 1–5 (0 clears, X rejects) on the open image or a whole selection, or use the stars in the inspector or the Rating menus. The rating is written into the file itself as the standard XMP Rating that Lightroom, Bridge, Capture One, digiKam and Windows Explorer read, so it travels with the file. Pixels and "date modified" are untouched, and Undo works. Works for JPEG, HEIC, PNG and TIFF, and for MP4/MOV/M4V videos, where the rating is a small XMP block (the place Adobe tools use) appended to the end of the file without re-encoding or moving anything. RAW files aren't supported yet. Thumbnails show the stars, rejected photos are dimmed, and you can filter and sort by rating.
- **All Subfolders** (toolbar button, or View ▸ Show All Subfolders, ⌥⌘S) flattens the folder: every photo and video from all its subfolders appears in one grid, with no folder tiles, and each thumbnail shows which subfolder it's in. Everything else works the same: viewer, search, filters, ratings, move, trash and undo. Hidden folders and packages (such as the Photos library) are skipped. Files added by other apps anywhere in the tree show up automatically. Turn it off to go back to folders.
- **World map** (the Grid / Map switch in the toolbar, or ⌘1 / ⌘2): every photo and video in the current view that has a location, shown as a pin whose head is its thumbnail. Flattened subfolders, search and filters all apply. Nearby pins merge into a stacked bubble with a count, and split as you zoom in. Click a bubble to see the photos in it (click one to open it) or to Zoom In; photos taken at the very same spot never split apart, so the list is the way to reach them. Click a pin to select it and see a larger preview (name, date and an **Open** button); double-click a pin (or press Return) to open it straight away. Esc goes back to the map. Pins respond even when the window isn't frontmost.
- **Fast revisits:** thumbnails are kept in a disk cache (~/Library/Caches, capped at 500 MB), so folders you've seen before open instantly. Turn it off or clear it in Settings ▸ Privacy.
- Sort by name, date taken, date modified/created, size or rating. Changes made to the folder outside the app show up automatically.
- **Search** (toolbar) matches file names *and what's in the photo*, like "beach", "dog" or "sky". Recognition runs on this Mac with Apple's Vision framework and is cached, so each photo is analyzed once. **Filter** by type (photos, videos, RAW) and by date taken (today, last 7/30 days, this year, last year, or a custom range).
- **Rotate and flip** without losing quality (⌘L / ⌘R). Only the file's orientation tag changes, so pixels are never re-compressed. Works on JPEG, HEIC, PNG and TIFF, one image or a whole selection, with undo. Camera RAW files can't be rotated in place.
- **Find Duplicates** (⌥⌘D) finds identical copies and visually similar photos (Strict / Normal / Loose), in the current folder or, with **Include subfolders**, in every folder inside it (hidden folders and packages such as the Photos library are skipped). Each copy shows which folder it's in. It suggests the best copy and moves the rest to the Trash after you review them.
- **Batch Rename** (⇧⌘R) renames a selection with a pattern such as `{date}_{n}` (tokens: `{name} {n} {date} {time} {year} {month} {day}`), with a live preview. Undo reverses the whole batch.
- **Export** (⌘E) saves copies as JPEG, HEIC, PNG or TIFF, optionally resized, keeping camera details and removing location by default. Originals are never changed.
- **Recognize Text** (⌘T, or the Text button in the viewer) runs macOS's on-device OCR, the engine behind Live Text, and prints what it read in red over each line of text, on an opaque box, so you can check the result against the photo. The eye button on the text bar switches to outlines only, to peek at the original. The highlights follow zoom and pan. Select lines with a click, ⌘-click, ⇧-click, a drag across them, or ⌘A; copy with ⌘C or the Copy / Copy All buttons. Double-click a line to copy just that line. Esc hides the text.
- The inspector (ⓘ, ⌘I) shows a **histogram** for photos and a **map** of where they were taken when the file has a location (for one photo, or every selected photo). Both only appear while the inspector is open.
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

### Folder permissions

macOS asks before an app opens Desktop, Documents, Downloads, or external and network drives. To never be asked, turn on **Full Disk Access** for Image Viewer: **Settings ▸ Privacy ▸ Turn On…** opens the right page in System Settings.

`build.sh` signs the app with your Apple Development or Developer ID certificate when the Mac has one, and says which it used. That gives the app a stable identity, so permissions survive rebuilds and updates. Without a certificate it falls back to an "ad-hoc" signature, which is tied to the exact build, so macOS asks again after every rebuild. Override with `SIGN_IDENTITY="…" ./build.sh` (`SIGN_IDENTITY=-` forces ad-hoc).

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
| 1–5 / 0 / X | Rate / clear / reject (saved in the file) |
| ⌘T | Recognize text (select lines, ⌘C to copy) |
| ⌘L / ⌘R | Rotate left / right |
| ⇧⌘R | Batch rename… |
| ⌘E | Export… |
| ⌥⌘D | Find duplicates… |
| ⇧⌘O | Open in Preview (for editing/markup) |
| ⌘1 / ⌘2 | Grid / world map |
| ⇧⌘. | Show hidden files |

## Settings and help

- **Image Viewer ▸ Settings… (⌘,)**
  - *General*: where the app starts when opened on its own (Home by default), sorting, thumbnail size, hidden files.
  - *Viewer*: blurred-photo or plain background, enlarging small images, the filmstrip.
  - *Privacy*: the remembered "Move to" folders and the cache of recognized photo contents; turn off or clear either.
- **Help ▸ Keyboard Shortcuts (⌘/)** lists every shortcut.

## Tests

```sh
./test.sh                  # all tests (~1 second)
./test.sh --filter Rename  # just some of them
```

The tests use real image files generated in a temporary folder. They cover:

- rotation math and lossless rotation
- export, the histogram, and metadata reading (date taken, GPS)
- search and filter rules, and batch-rename plans
- text recognition and duplicate detection
- the browser model: selection, keyboard focus, rename/move/rotate with undo, settings

`test.sh` works with just the Command Line Tools. It points `swift test` at Swift Testing, which the tools install outside the default search path.

## Code layout

```
Sources/ImageViewer/
  App/          App entry, windows, menu bar
  Model/        BrowserModel (all app state), split by feature:
                +Filtering, +Selection, +Viewer, +FileOperations, +ImageTools, +Keyboard
  Services/     Image loading and caches, metadata, EXIF/GPS index, OCR, duplicates, export, rotation
  Views/        Browser (sidebar, grid, drag & drop), Viewer (zoomable image, text overlay),
                Inspector, Tools (filters, rename, export, duplicates), Settings, Shared
Tests/ImageViewerTests/
```
