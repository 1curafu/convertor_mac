# Convertor

A zero-click, offline file converter for macOS, modelled on [Tangerine](https://tangerineformac.com).
It lives in the menu bar. **Drag any file, tap a key mid-drag, and drop it on a segment of the wheel.**
Results are saved next to the original (configurable in Settings). Nothing leaves your Mac.

| Key | Wheel |
|-----|-------|
| ⇧ Shift | **Convert** to another format |
| ⌘ Command | **Tools**: compress, edit, crop, trim… |
| ⌃ Control | **Actions**: AirDrop, Copy, Copy Path, Move, Float, Terminal |

Tap another key while the wheel is open to switch wheels. Drop on the centre to cancel.
The menu bar window also has a drop zone with the same options.

## Formats

| Category | Converts to | Notes |
|---|---|---|
| Images | JPG, PNG, WebP, HEIC, AVIF, TIFF, BMP, PDF | SVG/RAW input; EXIF rotation applied |
| Video | MP4, MOV, MKV, WebM, AVI, WMV, GIF, MP3 | |
| Audio | MP3, M4A, WAV, FLAC, OGG, Opus, AIFF, WMA | |
| PDF | DOCX, Pages, PPTX, XLSX, JPG, PNG, EPUB, TXT, Markdown | Images at 300 DPI; scanned pages via on-device OCR |
| Documents | Pages, PDF, DOCX, TXT, Markdown, HTML, EPUB, PNG, JPG | DOCX/DOC/RTF/ODT/Pages/MD/HTML input |
| Slides | PDF, PNG, JPG (+ PPTX from Keynote) | PPTX/PPT/Key input |
| Spreadsheets | XLSX, ODS, CSV, TSV, PDF | XLS/Numbers input |
| EPUB | PDF, DOCX, Pages, TXT, Markdown, HTML | |
| Subtitles | SRT, VTT, TXT | |
| Archives | ZIP, TAR, GZIP, Extract | RAR input |

PDF → Word/Pages gives editable paragraphs (the original layout may change), like Tangerine.
PDF → PowerPoint puts each page on its own slide as a picture, so it looks exactly like the PDF.

## Tools

| Files | Tools (⌘ wheel) |
|---|---|
| Images | Compress · Metadata · Edit (light, colour, effects, rotate) · Annotate (arrows, shapes, text, numbered callouts) · Add background · Crop · Redact (detects faces and text) · Create PDF / Collage for several images |
| Video | Compress · Metadata · Mute · Trim · Crop · Speed · Snapshot · Split · Redact · Join for several videos |
| Audio | Compress · Metadata · Normalize · Visualize (waveform video) · Trim (optionally removing silence at the ends) · Channels · Bleep |
| PDF | Compress · Metadata · Split · Organize pages (reorder, rotate, duplicate, delete) · Merge for several PDFs |

Tools that need a window open an editor with a live preview. Editors that draw on one file
(annotate, redact, trim, bleep…) are offered only for single files; the others (edit, crop,
add background, speed…) apply the same settings to every selected file.

## Build & install

Requires **macOS 26** and Xcode 26 (or its Command Line Tools).

```sh
scripts/build_app.sh --install
```

This compiles the app, downloads a static `ffmpeg` (from ffmpeg.martin-riedl.de), bundles it into
`Convertor.app`, ad-hoc signs it and copies it to `/Applications`.

- `FFMPEG=/path/to/ffmpeg scripts/build_app.sh` bundles your own static ffmpeg instead.
- `SKIP_FFMPEG=1 scripts/build_app.sh` skips bundling; the app then falls back to Homebrew's ffmpeg.

### Optional apps

- **Pages, Keynote, Numbers** (free on the Mac App Store) handle `.pages`, `.key` and `.numbers`, and
  produce layout-faithful PDFs from Word, PowerPoint and Excel files. The first time, macOS asks whether
  Convertor may control them (System Settings → Privacy & Security → Automation).
- **LibreOffice**, if installed, is used for slides and old spreadsheets when Keynote/Numbers are missing.

## How it works

- **Gesture:** a global `leftMouseDragged` monitor spots new drags through the drag pasteboard's change
  count, then polls modifier keys. Neither needs Accessibility permission.
- **Wheel:** a borderless, non-activating `NSPanel` centred on the cursor (Liquid Glass background). It is
  the drop target itself and hit-tests the drop point against the donut segments.
- **Engines:** Apple frameworks first (ImageIO, Core Image, Vision, AVFoundation, PDFKit,
  NSAttributedString, `ditto`/`tar`), ffmpeg for the rest. XLSX, ODS, EPUB and PPTX are written natively.

## Tests

`swift test` converts real files end to end (images, PDFs, documents, spreadsheets, subtitles, archives,
audio and video edits). Set `CONVERTOR_FFMPEG` to an ffmpeg binary to include the media tests.
CI runs the suite on macOS 26 and opens the produced XLSX/PPTX/DOCX/ODS/EPUB files with independent
Python libraries (`scripts/validate_outputs.py`).
