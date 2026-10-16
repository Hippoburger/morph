## What's new in 0.1.3

**FLAC files made from MP3 audio now play in QuickTime and Music.**

Converting an MP3, or a video with MP3 audio such as many older MP4s, to FLAC used to produce a file
that QuickTime and Music refused to open, with "An unknown error occurred (1718449215)". ffmpeg's FLAC
encoder was writing a block size Apple's decoder doesn't support. Morph now writes standard blocks, and
every FLAC it makes plays in Apple's apps.

Also checked in this release: photo rotation and mirroring are kept, silent videos give a clear
"This video has no sound" message, and BMPs open everywhere.

See [CHANGELOG.md](https://github.com/Hippoburger/morph/blob/main/CHANGELOG.md) for earlier versions.

## Install

Download **Morph-0.1.3.dmg** below, open it and drag Morph into Applications.

Morph isn't notarized yet, so the first time you open it macOS says it can't check it for malware.
Click **Done**, then go to **System Settings → Privacy & Security**, scroll down and press
**Open Anyway** next to Morph. After that it opens normally.

Then open Morph once and press **Turn On…** to add **Convert to** to Finder's right-click menu.
