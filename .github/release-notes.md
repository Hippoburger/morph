## What's new in 0.2.1

**PDF to Word now looks like the PDF.**

Converting a PDF to Word (or ODT, RTF, HTML, DOC) used to put every line in its own paragraph, in
Helvetica, so sentences broke in the middle and the spacing was lost. Now:

- Wrapped lines are joined back into paragraphs, with the spacing between them kept.
- Text keeps the font the PDF uses (Calibri, Times, Arial…), including bold and italic.
- Signatures, rules and logos drawn on the page come along as pictures, in place.
- Hidden text that iOS lays over a signature or handwriting is left out.
- Web addresses and emails become clickable links.

See [CHANGELOG.md](https://github.com/Hippoburger/morph/blob/main/CHANGELOG.md) for earlier versions.

## Install

Download **Morph-0.2.1.dmg** below, open it and drag Morph into Applications.

Morph isn't notarized yet, so the first time you open it macOS says it can't check it for malware.
Click **Done**, then go to **System Settings → Privacy & Security**, scroll down and press
**Open Anyway** next to Morph. After that it opens normally.

Then open Morph once and press **Turn On…** to add **Convert to** to Finder's right-click menu.
