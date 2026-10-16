## What's new in 0.2.0

- **Resize while converting.** Image formats in the right-click menu now have Full Size, Large
  (2048 px), Medium (1280 px) and Small (640 px).
- **Make Smaller.** Right-click a photo, video or PDF to shrink it without changing its format.
  Videos become HEVC at up to 1080p, and photos are capped at 2560 px. The original is never
  touched, and the result is only kept if it's at least 5% smaller.
- **Photos keep their date, camera and location.** Converting used to drop them. Prefer not to share
  where a photo was taken? Turn on **Remove location from photos** in the Morph window.
- **Progress and Cancel.** Click the spinner in the menu bar.
- **Faster.** Three files convert at once, and on Apple silicon video uses the hardware encoder.
- Also includes 0.1.3's fix: FLAC files made from MP3 audio now play in QuickTime and Music.

See [CHANGELOG.md](https://github.com/Hippoburger/morph/blob/main/CHANGELOG.md) for details.

## Install

Download **Morph-0.2.0.dmg** below, open it and drag Morph into Applications.

Morph isn't notarized yet, so the first time you open it macOS says it can't check it for malware.
Click **Done**, then go to **System Settings → Privacy & Security**, scroll down and press
**Open Anyway** next to Morph. After that it opens normally.

Then open Morph once and press **Turn On…** to add **Convert to** to Finder's right-click menu.
