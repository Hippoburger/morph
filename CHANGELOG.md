# Changelog

## 0.1.3

### Fixed

- **FLAC files made from MP3 audio now play in QuickTime and Music.** Converting an MP3, or a video
  with MP3 audio, to FLAC through ffmpeg wrote a tiny 47-sample block that Apple's decoder rejects,
  so the file failed with "An unknown error occurred (1718449215)". Morph now asks for standard
  4608-sample blocks.

### Checked

These bugs, found in a similar converter, were checked against Morph and don't affect it:

- Photos keep the rotation and mirroring Preview shows (JPEG EXIF orientation, HEIC rotation and
  mirroring). The orientation is applied to the pixels, so converting the result again can't flip it.
- Converting a silent video to audio says "This video has no sound", whether it goes through
  AVFoundation or ffmpeg.
- BMP files always open in Preview and Finder. Transparent areas are filled with white, because many
  apps show transparent BMP pixels as black.

## 0.1.2

### Fixed

- **Handwritten and scanned PDFs now convert properly to documents.** PDFs from notes apps (GoodNotes,
  Notability, Apple Notes) and scanners hide an invisible layer of machine-read text under the page so
  it can be searched. Converting one to Word used to pull out that text, in random sizes, and lose
  the page itself. Morph now keeps any page without visible text as a picture of the page, so the
  document looks exactly like the PDF. Pages of real typed text still come out as editable text, and
  a PDF can mix both.
- This applies to DOCX, DOC, ODT, RTF and HTML. Each page keeps the PDF's page size.
- A PDF with no text at all, such as a scan without OCR, now converts to those formats instead of failing.

## 0.1.1

### Fixed

- **WebP output** failed with Homebrew's ffmpeg, which is built without the WebP encoder. Morph now
  uses Google's `cwebp` (`brew install webp`), and still uses ffmpeg when its build includes WebP.
- **OGG output** failed for the same reason (no Vorbis encoder). It now falls back to Opus audio in an
  Ogg file, which plays everywhere Ogg does.
- Morph now checks which encoders your ffmpeg has instead of assuming them, and falls back to Apple's
  hardware H.264 encoder when libx264 is missing.
- The Finder menu now detects tools installed by Homebrew, so it no longer shows "needs ffmpeg" when
  ffmpeg is installed.
- Converting a silent video to audio now says "This video has no sound" instead of showing an
  ffmpeg error.

## 0.1.0

- First release: right-click a file in Finder → **Convert to** → pick a format.
- 40 formats across images, video, audio and documents, most using what macOS already has.
- Optional ffmpeg and LibreOffice for the remaining formats.
- Multi-step conversions (for example DOCX → PDF → PNG) and a `morph` command-line tool.
