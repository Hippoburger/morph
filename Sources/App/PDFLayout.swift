import AppKit
import PDFKit

// Rebuilds a PDF page as a document instead of a list of lines. Lines that wrap are joined back into
// paragraphs, the gaps between them become paragraph spacing, each piece of text gets the font the
// PDF really uses (PDFKit reports Helvetica for anything it doesn't have), and invisible OCR text is
// dropped. Whatever is drawn between the lines (a signature, a rule, a logo) becomes a picture in
// its place. A page with no visible text at all, a handwritten or scanned one, becomes one picture.
// shortcut: one column read top to bottom; tables and multi-column pages come out as one column.

enum PDFLayout {
    static func pages(_ doc: PDFDocument) throws -> [PageDocument.Page] {
        try (0..<doc.pageCount).compactMap { doc.page(at: $0) }.map(page)
    }

    /// The text of the PDF as paragraphs, for TXT. Pages without visible text give their OCR text.
    static func text(_ doc: PDFDocument) -> String {
        (0..<doc.pageCount).compactMap { doc.page(at: $0) }.map { page -> String in
            let shows = PDFPages.shows(page)
            guard shows.contains(where: \.visible) else { return page.string ?? "" }
            return paragraphs(page, shows).map { $0.runs.map(\.text).joined().trimmingCharacters(in: .whitespaces) }.joined(separator: "\n\n")
        }.joined(separator: "\n\n")
    }

    // MARK: Page

    private static func page(_ page: PDFPage) throws -> PageDocument.Page {
        let box = page.bounds(for: .mediaBox)
        let shows = PDFPages.shows(page)
        let image = try PDFPages.render(page)
        guard shows.contains(where: \.visible) else {
            let size = page.rotation % 180 == 0 ? box.size : CGSize(width: box.height, height: box.width)
            return .init(blocks: [try PageDocument.picture(image, points: size)], size: size, margins: (18, 18, 18, 18))
        }
        let paragraphs = paragraphs(page, shows)
        let lines = paragraphs.flatMap(\.lines)
        let left = lines.map(\.bounds.minX).min() ?? 72
        let right = box.width - (lines.map(\.bounds.maxX).max() ?? box.width - 72)
        let ink = Ink(image, pageHeight: box.height)

        var blocks: [PageDocument.Block] = []
        var bottom = box.height // where the last block ended, in page points (y up)
        var top: CGFloat?
        func drawing(between upper: CGFloat, and lower: CGFloat) throws {
            guard let (picture, rect) = ink.crop(top: upper - 1, bottom: lower + 1) else { return }
            if top == nil { top = rect.maxY }
            blocks.append(try PageDocument.picture(picture, points: rect.size, spaceBefore: blocks.isEmpty ? 0 : bottom - rect.maxY,
                                                   indent: max(0, rect.minX - left), png: true))
            bottom = rect.minY
        }
        for paragraph in paragraphs {
            let first = paragraph.lines[0]
            try drawing(between: bottom, and: first.bounds.maxY)
            let extra = paragraph.lineHeight - first.bounds.height // what "at least" line height adds above a line
            if top == nil { top = first.bounds.maxY + extra }
            blocks.append(.paragraph(runs: paragraph.runs, spaceBefore: blocks.isEmpty ? 0 : max(0, bottom - first.bounds.maxY - extra),
                                     lineHeight: paragraph.lineHeight, align: paragraph.align(left: left, right: box.width - right)))
            bottom = paragraph.lines.last!.bounds.minY
        }
        try drawing(between: bottom, and: 0)
        let topMargin = max(0, box.height - (top ?? box.height - 72))
        return .init(blocks: blocks, size: box.size, margins: (left, max(18, right), topMargin, min(max(left, 18), 72)))
    }

    // MARK: Lines and paragraphs

    private struct Line {
        var text: String
        var runs: [PageDocument.Run]
        var bounds: CGRect
        var size: CGFloat
    }

    private struct Paragraph {
        var lines: [Line]
        var lineHeight: CGFloat

        var runs: [PageDocument.Run] {
            var runs: [PageDocument.Run] = []
            for (i, line) in lines.enumerated() {
                var lineRuns = line.runs
                // A line broken after a hyphen joins the next without a space ("third-" + "year").
                if i < lines.count - 1, !(line.text.hasSuffix("-") && lines[i + 1].text.first?.isLowercase == true), !lineRuns.isEmpty,
                   lineRuns[lineRuns.count - 1].text.last != " " {
                    lineRuns[lineRuns.count - 1].text += " "
                }
                for run in lineRuns {
                    if let last = runs.last, last.sameStyle(run) { runs[runs.count - 1].text += run.text } else { runs.append(run) }
                }
            }
            return runs
        }

        /// Centered when every line sits in the middle; justified when every line but the last reaches
        /// the right edge of the text.
        func align(left: CGFloat, right: CGFloat) -> PageDocument.Align {
            if lines.allSatisfy({ $0.bounds.minX - left > 20 && abs(($0.bounds.minX - left) - (right - $0.bounds.maxX)) < 4 }) { return .center }
            if lines.count > 2, lines.dropLast().allSatisfy({ right - $0.bounds.maxX < 1.5 }) { return .justify }
            return .left
        }
    }

    private static func paragraphs(_ page: PDFPage, _ shows: [PDFPages.Show]) -> [Paragraph] {
        let box = page.bounds(for: .mediaBox)
        let string = (page.string ?? "") as NSString
        let attributed = page.attributedString
        guard string.length > 0, let selection = page.selection(for: box) else { return [] }

        // The font of every character: from the nearest show operator that starts on its line, at or
        // left of it. (PDFKit's characterIndex(at:) can land on a neighbouring line, so it isn't used.)
        func show(at bounds: CGRect) -> PDFPages.Show? {
            shows.filter { $0.point.y >= bounds.minY - 1 && $0.point.y <= bounds.maxY && $0.point.x <= bounds.midX }
                .max { $0.point.x < $1.point.x }
        }
        let links = page.annotations.compactMap { a -> (CGRect, String)? in
            a.type == "Link" ? a.url.map { (a.bounds, $0.absoluteString) } : nil
        }
        let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)

        var lines: [Line] = []
        for sel in selection.selectionsByLine() {
            let range = sel.range(at: 0, on: page)
            guard range.location != NSNotFound, range.length > 0 else { continue }
            var runs: [PageDocument.Run] = []
            var visible = false, sizes: [CGFloat] = []
            var previous: PDFPages.Show?
            // Web addresses and emails written out in the text, which many PDFs don't mark as links.
            let lineText = string.substring(with: NSRange(location: range.location, length: min(range.length, string.length - range.location)))
            let written = detector?.matches(in: lineText, range: NSRange(location: 0, length: (lineText as NSString).length))
                .compactMap { m in m.url.map { (NSRange(location: m.range.location + range.location, length: m.range.length), $0.absoluteString) } } ?? []
            for i in range.location..<min(NSMaxRange(range), string.length) {
                let ch = string.substring(with: NSRange(location: i, length: 1))
                if ch == "\n" || ch == "\r" { continue }
                // characterBounds(at:) counts characters differently from page.string; a selection doesn't.
                let charBounds = page.selection(for: NSRange(location: i, length: 1))?.bounds(for: page) ?? .zero
                // Some characters get odd bounds from PDFKit; they take the font before them.
                let show = show(at: charBounds) ?? previous
                previous = show
                if show?.visible ?? true, ch != " " { visible = true }
                let nsFont = attributed?.length == string.length ? attributed?.attribute(.font, at: i, effectiveRange: nil) as? NSFont : nil
                let size = nsFont?.pointSize ?? 11
                sizes.append(size)
                let style = show.map { fontStyle($0.font) } ?? (family: nsFont?.familyName ?? "Helvetica", bold: false, italic: false)
                let center = CGPoint(x: charBounds.midX, y: charBounds.midY)
                var run = PageDocument.Run(text: ch, font: style.family, size: size, bold: style.bold, italic: style.italic,
                                           color: hex(attributed?.length == string.length ? attributed?.attribute(.foregroundColor, at: i, effectiveRange: nil) as? NSColor : nil),
                                           link: links.first { $0.0.contains(center) }?.1 ?? written.first { NSLocationInRange(i, $0.0) }?.1)
                if run.link != nil, run.color == nil { run.color = "0563C1" }
                if let last = runs.last, last.sameStyle(run) { runs[runs.count - 1].text += ch } else { runs.append(run) }
            }
            guard visible, !runs.isEmpty else { continue }
            let text = runs.map(\.text).joined().trimmingCharacters(in: .whitespaces)
            lines.append(Line(text: text, runs: runs, bounds: sel.bounds(for: page), size: sizes.max() ?? 11))
        }
        lines.sort { $0.bounds.maxY > $1.bounds.maxY }

        // A line continues the paragraph above when it's the same size, starts at the same place, sits
        // close below, and the line above ran the full width (so it wrapped rather than ended).
        let rightEdge = lines.map(\.bounds.maxX).max() ?? box.width
        let width = rightEdge - (lines.map(\.bounds.minX).min() ?? 0)
        var paragraphs: [[Line]] = []
        for line in lines {
            if let prev = paragraphs.last?.last, abs(prev.size - line.size) < 0.5, abs(prev.bounds.minX - line.bounds.minX) < 3,
               prev.bounds.minY - line.bounds.maxY < line.bounds.height * 0.6, prev.bounds.maxX > rightEdge - width * 0.15 {
                paragraphs[paragraphs.count - 1].append(line)
            } else {
                paragraphs.append([line])
            }
        }
        // Line height from paragraphs that have more than one line, per text size; single lines use it too.
        var pitch: [CGFloat: CGFloat] = [:]
        for p in paragraphs where p.count > 1 {
            pitch[p[0].size] = (p[0].bounds.minY - p[p.count - 1].bounds.minY) / CGFloat(p.count - 1)
        }
        return paragraphs.map { Paragraph(lines: $0, lineHeight: pitch[$0[0].size] ?? $0[0].bounds.height) }
    }

    /// "AAAAAC+Calibri-Bold" → ("Calibri", bold). Subset prefixes go, and a PostScript name of an
    /// installed font becomes its family name ("TimesNewRomanPSMT" → "Times New Roman").
    private static func fontStyle(_ base: String) -> (family: String, bold: Bool, italic: Bool) {
        let name = base.split(separator: "+", maxSplits: 1).last.map(String.init) ?? base
        let style = name.lowercased()
        let bold = ["bold", "black", "heavy", "semibold"].contains { style.contains($0) }
        let italic = style.contains("italic") || style.contains("oblique")
        if let family = NSFont(name: name, size: 12)?.familyName { return (family, bold, italic) }
        var family = String(name.split(whereSeparator: { $0 == "-" || $0 == "," }).first ?? Substring(name))
        for suffix in ["PSMT", "MT", "PS"] where family.hasSuffix(suffix) { family.removeLast(suffix.count) }
        // "SegoeUI" → "Segoe UI"
        family = family.replacingOccurrences(of: "([a-z])([A-Z])", with: "$1 $2", options: .regularExpression)
        return (family, bold, italic)
    }

    private static func hex(_ color: NSColor?) -> String? {
        guard let c = color?.usingColorSpace(.sRGB), max(c.redComponent, c.greenComponent, c.blueComponent) > 0.15 else { return nil }
        return String(format: "%02X%02X%02X", Int(c.redComponent * 255), Int(c.greenComponent * 255), Int(c.blueComponent * 255))
    }

    // MARK: Ink

    /// Finds what's drawn in a band of the rendered page, compared with the page's own background.
    private struct Ink {
        let image: CGImage
        let pixels: [UInt8]
        let scale: CGFloat
        let pageHeight: CGFloat

        init(_ image: CGImage, pageHeight: CGFloat) {
            self.image = image
            self.pageHeight = pageHeight
            scale = CGFloat(image.height) / pageHeight
            var px = [UInt8](repeating: 0, count: image.width * image.height * 4)
            px.withUnsafeMutableBytes { buf in
                CGContext(data: buf.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
                          space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)?
                    .draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            }
            pixels = px
        }

        /// The drawing between two heights (page points, y up), cropped to its ink, and where it sits.
        func crop(top: CGFloat, bottom: CGFloat) -> (CGImage, CGRect)? {
            let w = image.width
            let y0 = max(0, Int((pageHeight - top) * scale)), y1 = min(image.height, Int((pageHeight - bottom) * scale))
            guard y1 - y0 > 2 else { return nil }
            let bg = Array(pixels[0..<3])
            var minX = w, maxX = -1, minY = Int.max, maxY = -1
            for y in y0..<y1 {
                for x in 0..<w {
                    let o = (y * w + x) * 4
                    if abs(Int(pixels[o]) - Int(bg[0])) > 24 || abs(Int(pixels[o + 1]) - Int(bg[1])) > 24 || abs(Int(pixels[o + 2]) - Int(bg[2])) > 24 {
                        minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
                    }
                }
            }
            guard maxX >= minX, maxY >= minY, (maxX - minX) * (maxY - minY) > 4 else { return nil }
            let pad = 2
            let rect = CGRect(x: max(0, minX - pad), y: max(0, minY - pad), width: min(w, maxX + pad) - max(0, minX - pad),
                              height: min(image.height, maxY + pad) - max(0, minY - pad))
            guard let cropped = image.cropping(to: rect) else { return nil }
            let points = CGRect(x: rect.minX / scale, y: pageHeight - rect.maxY / scale, width: rect.width / scale, height: rect.height / scale)
            return (cropped, points)
        }
    }
}
