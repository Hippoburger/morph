# Morph

Right-click a file in Finder, choose **Convert to ▸**, pick a format. The converted file lands next to
the original and never leaves your Mac.

40 formats:

| | |
|---|---|
| Images | JPG PNG WEBP HEIC AVIF GIF TIFF BMP ICO TGA PPM QOI EXR SVG |
| Video | MP4 MOV WEBM MKV AVI |
| Audio | MP3 WAV FLAC AAC M4A OGG OPUS |
| Documents | PDF DOCX DOC ODT RTF TXT HTML PPTX PPT ODP XLSX XLS ODS CSV |

Most of it runs on what macOS already has (ImageIO, AVFoundation, Core Audio, AppKit's text system,
PDFKit). Three optional tools unlock the rest, and Morph tells you when a conversion needs one:

- **ffmpeg** (`brew install ffmpeg`): MP3, OGG, Opus, WebM, MKV and AVI output, and video from
  WebM, MKV and AVI. Morph uses whichever encoders your build has.
- **WebP tools** (`brew install webp`): WebP output.
- **LibreOffice** (`brew install --cask libreoffice`): PowerPoint, Excel and OpenDocument slides and
  sheets, and better-looking Word to PDF.

Image formats open a submenu to resize as you convert (Full Size, 2048, 1280 or 640 px), and photos
keep their date, camera and location (the Morph window has a switch to leave the location out).
**Make Smaller** shrinks photos, videos and PDFs without changing their format. Morph converts
three files at a time; click the spinner in the menu bar to see progress or cancel.

When there's no direct route, Morph chains up to three steps through PNG, PDF, WAV or HTML, so
DOCX → PNG goes DOCX → PDF → PNG and a PDF becomes one image per page.

## Install

Download the DMG from [Releases](https://github.com/Hippoburger/morph/releases/latest), open it and
drag Morph into Applications. It isn't notarized yet, so the first launch needs **System Settings →
Privacy & Security → Open Anyway**. Then open Morph and press **Turn On…** for the Finder menu.

## Build

Needs Xcode (for the macOS SDK and swiftc), nothing else.

    ./build.sh            # build/Morph.app
    ./build.sh install    # also copies it to /Applications and turns on the Finder extension
    ./build.sh dmg        # also packs build/Morph-<version>.dmg

Releases build themselves: bump `VERSION`, add the version to `CHANGELOG.md` and its notes to
`.github/release-notes.md` (the release's description), commit, and push a matching tag (`git tag v0.2.0 && git push
origin v0.2.0`). The workflow in `.github/workflows/release.yml` builds the DMG and publishes it.

It's signed ad hoc, which runs on the Mac that built it. Set `SIGN_IDENTITY` to a Developer ID
identity to sign it for other Macs (they'd also want it notarized).

If **Convert to** doesn't show up, open Morph and press **Turn On…**, or enable it under System
Settings → General → Login Items & Extensions → File Providers & Finder.

## Command line

The app binary doubles as a CLI:

    ln -s /Applications/Morph.app/Contents/MacOS/Morph ~/.local/bin/morph
    morph clip.mov --to mp4
    morph *.heic --to jpg
    morph *.heic --to jpg --size 1280
    morph clip.mov --smaller
    morph report.pdf --targets

## How it fits together

    Sources/Shared/Formats.swift   the format table and route planner, used by both targets
    Sources/Extension/             the Finder Sync extension: builds the menu, hands jobs to the app
    Sources/App/                   the app: engines, the job queue, the window, the CLI

The Finder extension is sandboxed, so it converts nothing itself. It opens
`morph://convert?to=png&file=…` and the app, which isn't sandboxed, does the work with a spinner in
the menu bar, posts a notification and quits when it's idle.

## License

MIT, see [LICENSE](LICENSE).
