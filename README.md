# Convertor

A zero-click, offline file converter for macOS, modelled on [Tangerine](https://tangerineformac.com).
Convertor converts and edits files without opening any app. It lives in the menu bar
(the ⟳ icon) and works entirely on your Mac. Nothing is uploaded.

## Install

1. Install **Xcode** from the Mac App Store (the Command Line Tools alone aren't enough), open it once,
   then run `sudo xcode-select -s /Applications/Xcode.app/Contents/Developer`.
2. On a Mac with macOS 26 or newer, run:
   ```sh
   git clone -b main https://github.com/1curafu/convertor_mac && cd convertor_mac
   scripts/build_app.sh --install
   ```
3. Convertor opens and appears in the menu bar. It has no Dock icon.
4. Optional: open **Settings → Launch at login** so it's always ready.

## The basic move

1. Start dragging one or more files: from Finder, the Desktop, Mail, anywhere.
2. While still holding the mouse button, **tap a key**:

   | Key | Wheel | What it does |
   |---|---|---|
   | **⇧ Shift** | Convert | Saves a copy in another format |
   | **⌘ Command** | Tools | Compress, edit, crop, trim, … |
   | **⌃ Control** | Actions | AirDrop, copy, move, … |

3. A wheel appears under the cursor. Move onto a segment: it turns orange and its name shows in the middle.
4. Let go of the mouse button. That's it.

- Tap another key while the wheel is open to switch wheels.
- Drop on the **centre** of the wheel to cancel. The file goes back where it was.
- Results are saved **next to the original** with a new name (`photo.png`, `photo compressed.jpg`, …).
  The original is never changed.
- You'll hear a "pop" when a job finishes. Progress and results are listed in the menu bar window.

**No drag handy?** Click the menu bar icon and drop files onto **"…or drop files here"**. Choose
Convert, Tools or Actions at the top, then click a button.

## Convert (⇧)

| You drop | You can get |
|---|---|
| Image | JPG, PNG, WebP, HEIC, AVIF, TIFF, BMP, PDF |
| Video | MP4, MOV, MKV, WebM, AVI, WMV, GIF, MP3 (audio only) |
| Audio | MP3, M4A, WAV, FLAC, OGG, Opus, AIFF, WMA |
| PDF | Word (DOCX), Pages, PowerPoint (PPTX), Excel (XLSX), JPG, PNG, EPUB, TXT, Markdown |
| Document (Word, Pages, RTF, Markdown, HTML, TXT) | Pages, PDF, DOCX, TXT, Markdown, HTML, EPUB, PNG, JPG |
| Slides (PowerPoint, Keynote) | PDF, PNG, JPG, and PPTX from Keynote |
| Spreadsheet (Excel, Numbers, ODS, CSV, TSV) | XLSX, ODS, CSV, TSV, PDF |
| EPUB | PDF, DOCX, Pages, TXT, Markdown, HTML |
| Subtitles (SRT, VTT) | SRT, VTT, TXT |
| Archive (ZIP, TAR, GZIP, RAR) or folder | ZIP, TAR, GZIP |

Good to know:
- **Several pages → images:** a multi-page PDF or document becomes a folder of `Page 1.png`, `Page 2.png`, …
  PDF pages are rendered at 300 DPI.
- **PDF → Word/Pages** gives editable text with headings and bold/italic. The original layout may change.
  Scanned pages are read with text recognition on your Mac.
- **PDF → PowerPoint** puts each page on its own slide as a picture, so it looks exactly like the PDF.
- **PDF → Excel** makes one sheet per page and splits columns where the text has wide gaps.
- **Word → PDF** uses Pages when installed, so the layout matches. Without Pages, the text is reflowed onto Letter pages.
- **iPhone photos** keep the right orientation, and location/camera tags are kept unless you remove them.

## Tools (⌘)

Some tools run straight away. Others open an editor window with a preview: adjust, then click
**Save** (or press Return). **Cancel** (or Esc) closes it without saving.

### Images

| Tool | What it does |
|---|---|
| **Compress** | Smaller JPEG (or HEIC if the image has transparency). Quality is set in Settings. |
| **Metadata** | View and edit title, author, copyright, comment, date taken and location. "Remove location" or "Remove all metadata" for privacy. |
| **Edit** | Exposure, contrast, highlights, shadows, saturation, vibrance, warmth, sharpness, vignette, effects (Mono, Noir, Chrome, …), rotate and flip. Toggle **Original** to compare. |
| **Annotate** | Arrows, rectangles, ellipses, pen, highlighter, text and numbered callouts (1, 2, 3…). Pick a colour and thickness. ⌘Z undoes. |
| **Add BG** | Puts the image on a solid or gradient background, with spacing, rounded corners, shadow and aspect ratio (1:1, 4:5, 16:9, 9:16). Saved as PNG. |
| **Crop** | Drag the corners/edges or the whole box. Pick an aspect ratio, and optionally type an exact output size. |
| **Redact** | Click **Faces** or **Text** to find them automatically, or drag boxes yourself. Choose Blur, Pixelate or Solid. Click × to remove a box. Redacted copies have no metadata. |
| **Create PDF** *(several images)* | One PDF, one page per image. |
| **Collage** *(several images)* | Grid, row, column or featured layout. Set spacing, corners, background and order. |

### Video

| Tool | What it does |
|---|---|
| **Compress** | Smaller MP4 at the same resolution. |
| **Metadata** | Edit title, artist, album, genre, date and comment, or remove all. |
| **Mute** | Removes the sound track. |
| **Trim** | Drag the orange handles on the timeline. Use ◀▶ to step one frame, or "Start/End at playhead". Press play to preview the selection. |
| **Crop** | Draw the crop on a frame. The audio is kept. |
| **Speed** | 0.25× to 4×. The audio keeps its pitch. Press play to preview at that speed. |
| **Snapshot** | Scrub to a frame and press **S** (or the button) to save it as a full-resolution PNG. Repeat as often as you like. |
| **Split** | Move the playhead and click **Split at …** to add cut points. Every part is saved into a new folder. |
| **Redact** | Draw boxes over faces, plates or screens. Blur, pixelate or solid, for the whole video or just a time range. |
| **Join** *(several videos)* | Drag clips into order. They're joined into one MP4, scaled to the first clip's size. |

### Audio

| Tool | What it does |
|---|---|
| **Compress** | 128 kbps MP3 (for MP3s) or M4A. |
| **Metadata** | Edit or remove tags. |
| **Normalize** | Evens out loudness (to −16 LUFS, a common podcast level). |
| **Visualize** | Makes an MP4 for social posts: orange waveform or bars on black, or a still image. Landscape, portrait or square. |
| **Trim** | Handles on the waveform, with an option to remove silence at the start and end. |
| **Channels** | Converts to mono or stereo. |
| **Bleep** | Put the handles around a word and click **Bleep …**. Repeat for every word. Choose a beep or silence. |

### PDF

| Tool | What it does |
|---|---|
| **Compress** | Smaller file, mostly by recompressing images. |
| **Metadata** | Title, author, subject, keywords, or remove all. |
| **Split** | Every page as its own PDF in a new folder. |
| **Organize** | Reorder pages by dragging, rotate, duplicate or delete. ⌘-click to select several. |
| **Merge** *(several PDFs)* | One PDF in the order you selected them. |

### Archives

**Extract** unpacks ZIP, TAR, GZIP and RAR into a folder next to the archive.

### Several files at once

Drag a whole selection to process every file. Tools that apply the same settings everywhere
(Compress, Edit, Crop for images, Add BG, Speed, Channels, Visualize, Metadata) work on all of them.
Tools where you work on one file (Annotate, Redact, Trim, Bleep, Split, Snapshot, video Crop) only appear
for a single file.

## Actions (⌃)

| Action | What it does |
|---|---|
| **AirDrop** | Opens the AirDrop sheet for the files. |
| **Copy** | Copies the files, ready to paste in Finder or an app. |
| **Copy Path** | Copies the full path (one per line). |
| **Move** | Asks for a folder and moves the files there. |
| **Float** | Keeps the file in a small always-on-top window. Drag it out later to drop it anywhere. |
| **Terminal** | Opens Terminal in the file's folder. |

## Settings

Open from the menu bar window → **Settings…**

- **Open the wheel while dragging files:** turn the gesture off without quitting the app.
- **Save results:** next to the original, in Downloads, or in a folder you choose.
- **Reveal results in Finder** and **Play a sound when done.**
- **Image quality** for conversions and **Compression quality** for Compress.
- **Launch at login.**
- **ffmpeg:** shows which ffmpeg the app is using.

## Permissions

- **Dragging** needs no special permission.
- **Pages, Keynote, Numbers:** the first time you convert one of their files, macOS asks
  "Convertor wants to control Pages". Click **Allow**. To change this later, open **System Settings →
  Privacy & Security → Automation → Convertor**.

## Troubleshooting

| Problem | Fix |
|---|---|
| The wheel doesn't appear | Check the gesture is on in Settings, and that you tap the key *while* dragging (after the file starts moving). Dragging inside Convertor's own windows doesn't open the wheel. |
| Build fails with `plugin for module 'SwiftUIMacros' not found` | You're building with the Command Line Tools. Install Xcode and run `sudo xcode-select -s /Applications/Xcode.app/Contents/Developer`. |
| "This format needs ffmpeg" | Rebuild with `scripts/build_app.sh` (it bundles ffmpeg) or run `brew install ffmpeg`. |
| "Pages/Keynote/Numbers is needed" | Install it from the Mac App Store (free). For slides and spreadsheets, LibreOffice works too. |
| "Allow Convertor to control …" | Turn it on in System Settings → Privacy & Security → Automation. |
| A job failed | The menu bar window shows the error under the job. The original file is untouched. |
| "Preview isn't available for MKV" (or similar) | AVFoundation can't play that format. Editing still works; you just can't play it in the window. |
| macOS says the app can't be opened | It's signed only for your Mac. Right-click Convertor in Applications → **Open**, once. |

## For developers

Build options, architecture and tests: [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md).
