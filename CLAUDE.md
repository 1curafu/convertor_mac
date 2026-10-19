# Convertor: notes for Claude Code

A macOS 26 menu bar app (SwiftUI + AppKit, Swift package) that clones Tangerine: drag a file, tap
⇧/⌘/⌃ mid-drag, drop on a wheel segment to convert, edit or act on it. See README.md for features.

## Build and test

```sh
swift build                                   # compile (needs macOS 26 + Xcode 26)
CONVERTOR_FFMPEG=/path/to/ffmpeg swift test   # end-to-end tests; media tests skip without ffmpeg
scripts/build_app.sh [--install]              # build/Convertor.app with a static ffmpeg bundled
```

- Cloud/Linux sessions can't compile Swift. Push and let CI (`.github/workflows/build.yml`,
  `macos-26` runner) build, run `swift test`, and validate outputs with `scripts/validate_outputs.py`.
- On a CI failure the build step prints just the `: error:` lines, so read the end of the log first.
- Every new format writer or engine path should get a test in `Tests/ConvertorTests/ConvertorTests.swift`.
  Office/ODF/EPUB outputs the tests produce should also be checked in `validate_outputs.py`.

## Layout

| Path | What lives there |
|---|---|
| `Catalog.swift` | `FileKind` detection, `Mode`, `Tool`, `Action`, and which segments each wheel shows (order matches Tangerine) |
| `DragMonitor.swift`, `Wheel.swift` | Global drag detection, the wheel panel, its geometry and drop hit-testing |
| `ConversionCenter.swift` | Runs actions as background jobs (menu bar history) or opens editors |
| `Engine/Engine.swift` | Dispatches convert actions and one-tap tools to the engines |
| `Engine/*Engine.swift` | Image (ImageIO), Media (AVFoundation + ffmpeg), Document (NSAttributedString/PDFKit), Archive, Text (subtitles) |
| `Engine/ImageEdits.swift`, `MediaEdits.swift`, `EditJobs.swift` | The operations behind editor windows |
| `Engine/PDFText.swift`, `Media.swift` | PDF text, OCR and reflow; media probing, frames and waveforms |
| `Formats/` | Native XLSX/ODS, EPUB, PPTX writers, `StructuredText` (Markdown/XHTML), iWork and LibreOffice bridges |
| `Editors/` | SwiftUI editor windows, plus shared components (scaffold, crop overlay, timeline, player) |

## Conventions

- **Never modify the original.** Every output goes through `Output.file`/`Output.folder`, which pick a
  free name next to the source (or the folder chosen in Settings).
- **Apple frameworks first, ffmpeg second.** Use AVFoundation/ImageIO when they can read and write the
  format (`MediaEngine.appleReadable`, `ImageEngine.nativeOutputs`). Otherwise use `FFmpeg.run`.
  Encoder flags live in `FFmpeg.arguments(for:)`.
- **Coordinates:** editor rectangles and points are normalised (0…1, origin top-left). Flip y for Core
  Image and Vision (origin bottom-left).
- **Concurrency:** Swift 5 language mode. Only AppKit text and printing work is `@MainActor`
  (`DocumentEngine.readRich/writeRich/printToPDF`, `EPUB.read`). Keep rendering, OCR and ffmpeg off the
  main actor. Editors hand work to `EditorContext.save`, which runs it as a job.
- **Documents use `DocumentFont`** (Helvetica Neue), never `NSFont.systemFont`. The system font's private
  name doesn't resolve in Word or Pages.
- **Shell out through `Shell.run`/`Shell.capture`**, never a shell string. stderr goes to a temp file so
  long ffmpeg runs can't stall.
- Match the surrounding style: short doc comments on types and non-obvious functions, no comments that
  restate the code.

## Gotchas

- Use `#/regex/#` literals. Bare `/regex/` needs Swift 6 mode.
- `cos`/`sin` on a Double next to CGFloat math is ambiguous. Wrap the result in `CGFloat(...)`.
- ImageIO writes PNG tags only to PNG text chunks, and some formats (WebP, RAW) can't be written at all.
  `ImageEdits.writeMetadata` verifies a lossless write and otherwise re-encodes.
- ODS pads sheets with huge `number-*-repeated` runs. Expand repeats between data and trim only the trailing ones.
- iWork conversions need the app installed and Automation permission. LibreOffice is only a fallback.
- The bundled ffmpeg is a static build from ffmpeg.martin-riedl.de. CI checks the encoders the app relies on.
