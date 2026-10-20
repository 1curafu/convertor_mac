# Developing Convertor

User documentation is in the [README](../README.md).

## Build

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
