# Convertor

A zero-click, offline file converter for macOS, modelled on [Tangerine](https://tangerineformac.com).
It lives in the menu bar. **Drag any file, tap a modifier key mid-drag, and drop it on a segment of the wheel**:

| Key | Wheel | Examples |
|-----|-------|----------|
| ⇧ Shift | Convert | JPG → PNG/WebP/HEIC/AVIF/PDF, MOV → MP4/WebM/GIF/MP3, WAV → MP3/FLAC/Opus, DOCX → PDF/MD, SRT ↔ VTT, CSV ↔ TSV, ZIP ↔ TAR/GZIP |
| ⌘ Command | Tools | compress, resize, rotate, strip EXIF, combine images to PDF, 720p, mute, 2× speed, join videos, normalize audio, trim silence, waveform video, split/merge/compress PDF, extract archives |
| ⌃ Control | Actions | AirDrop, Copy, Copy Path, Move, Float (pin on top), open in Terminal |

Press another key while the wheel is open to switch wheels. Drop on the centre to cancel.
Results are saved next to the original (configurable in Settings). Nothing leaves your Mac.

## Build & install

Requires macOS 13+ and Xcode 15+ (or the Command Line Tools).

```sh
scripts/build_app.sh --install
```

This compiles the app, downloads a static `ffmpeg` (from ffmpeg.martin-riedl.de), bundles it into
`Convertor.app`, ad-hoc signs it and copies it to `/Applications`.

- `FFMPEG=/path/to/ffmpeg scripts/build_app.sh` bundles your own static ffmpeg instead.
- `SKIP_FFMPEG=1 scripts/build_app.sh` skips bundling; the app then falls back to Homebrew's ffmpeg if installed.

## How it works

- **Gesture:** a global `leftMouseDragged` monitor notices new drags via the drag pasteboard's change count,
  then polls modifier keys. Neither needs Accessibility permission.
- **Wheel:** a borderless, non-activating `NSPanel` centred on the cursor; it is itself the drop target and
  hit-tests the drop point against the donut segments.
- **Engines:** Apple frameworks first (ImageIO, Core Image, AVFoundation, PDFKit, NSAttributedString,
  `ditto`/`tar`), ffmpeg for everything else (WebP/AVIF output, MP3/FLAC/OGG/Opus/WMA, MKV/WebM/AVI/WMV,
  audio filters).

## Not supported (yet)

Tangerine also handles PAGES, EPUB, PPTX/Slides, XLSX/ODS and PDF → Office layouts. Those need
third-party parsers and aren't included.
