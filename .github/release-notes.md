## What's new in 0.1.2

**Handwritten and scanned PDFs now convert properly to Word and other documents.**

PDFs from notes apps (GoodNotes, Notability, Apple Notes) and scanners hide an invisible layer of
machine-read text under each page. Converting one to DOCX used to pull out only that text, garbled and
in random sizes, and drop the handwriting. Now any page without visible text goes into the document as
a picture of the page, so it looks exactly like the PDF. Pages of typed text are still converted to
editable text.

This applies to DOCX, DOC, ODT, RTF and HTML. Scanned PDFs with no text at all now convert too
instead of failing.

See [CHANGELOG.md](https://github.com/Hippoburger/morph/blob/main/CHANGELOG.md) for earlier versions.

## Install

Download **Morph-0.1.2.dmg** below, open it and drag Morph into Applications.

Morph isn't notarized yet, so the first time you open it macOS says it can't check it for malware.
Click **Done**, then go to **System Settings → Privacy & Security**, scroll down and press
**Open Anyway** next to Morph. After that it opens normally.

Then open Morph once and press **Turn On…** to add **Convert to** to Finder's right-click menu.
