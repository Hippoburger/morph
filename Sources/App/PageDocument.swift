import Foundation
import ImageIO
import UniformTypeIdentifiers

// Writes a PDF rebuilt by PDFLayout as DOCX, ODT, RTF or HTML: paragraphs of styled text, and
// pictures for what's drawn (a signature, a rule, a handwritten page). AppKit's writers can't name a
// font that isn't installed (Calibri, on most Macs) and drop pictures, so these formats are put
// together here.

enum PageDocument {
    struct Run: Equatable {
        var text: String
        var font: String
        var size: CGFloat
        var bold = false
        var italic = false
        /// Hex RGB, nil for black.
        var color: String?
        var link: String?

        func sameStyle(_ o: Run) -> Bool {
            font == o.font && size == o.size && bold == o.bold && italic == o.italic && color == o.color && link == o.link
        }
    }

    enum Align { case left, center, justify }

    enum Block {
        /// `lineHeight` is the distance between baselines, used as a minimum so bigger text still fits.
        case paragraph(runs: [Run], spaceBefore: CGFloat, lineHeight: CGFloat, align: Align)
        /// `ext` is "png" or "jpeg"; `indent` is the distance from the left margin.
        case picture(Data, ext: String, pixels: CGSize, points: CGSize, spaceBefore: CGFloat, indent: CGFloat)
    }

    struct Page {
        var blocks: [Block]
        var size: CGSize
        /// Left, right, top, bottom.
        var margins: (CGFloat, CGFloat, CGFloat, CGFloat)
    }

    static func picture(_ image: CGImage, points: CGSize, spaceBefore: CGFloat = 0, indent: CGFloat = 0, png: Bool = false) throws -> Block {
        let data = NSMutableData()
        let type = png ? UTType.png : .jpeg
        guard let dest = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil) else {
            throw ConversionError("Couldn't encode the picture.")
        }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: 0.88] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw ConversionError("Couldn't encode the picture.") }
        return .picture(data as Data, ext: png ? "png" : "jpeg", pixels: CGSize(width: image.width, height: image.height),
                        points: points, spaceBefore: spaceBefore, indent: indent)
    }

    static func write(_ pages: [Page], to url: URL, ext: String) throws {
        guard let first = pages.first else { throw ConversionError("The PDF has no pages.") }
        let layout = Layout(size: first.size, margins: first.margins)
        switch ext {
        case "docx": try docx(pages, layout, to: url)
        case "odt": try odt(pages, layout, to: url)
        // Without LibreOffice (see DocumentEngine) a .doc is RTF, which Word, Pages and LibreOffice all open.
        case "rtf", "doc": try Data(rtf(pages, layout).utf8).write(to: url)
        case "html": try html(pages, title: url.deletingPathExtension().lastPathComponent).write(to: url, atomically: true, encoding: .utf8)
        default: throw ConversionError("Can't write \(ext.uppercased()) from a PDF.")
        }
    }

    // MARK: Layout

    /// The first page's size and margins; DOCX, ODT and RTF use one for the whole document.
    private struct Layout {
        let size: CGSize
        let margins: (CGFloat, CGFloat, CGFloat, CGFloat)

        /// A picture's size, shrunk if needed to fit inside the margins with room for its line.
        func fitted(_ points: CGSize) -> CGSize {
            let box = CGSize(width: size.width - margins.0 - margins.1, height: (size.height - margins.2 - margins.3) * 0.97)
            let s = min(1, box.width / points.width, box.height / points.height)
            return CGSize(width: floor(points.width * s), height: floor(points.height * s))
        }
    }

    private static func twips(_ pt: CGFloat) -> Int { Int((pt * 20).rounded()) }

    private static func xml(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
            .unicodeScalars.filter { $0.value >= 0x20 || $0 == "\t" }.map(String.init).joined()
    }

    /// Consecutive runs grouped by the link they share, for formats that wrap a link around its runs.
    private static func byLink(_ runs: [Run]) -> [(link: String?, runs: [Run])] {
        var groups: [(link: String?, runs: [Run])] = []
        for run in runs {
            if let last = groups.last, last.link == run.link { groups[groups.count - 1].runs.append(run) } else { groups.append((run.link, [run])) }
        }
        return groups
    }

    // MARK: DOCX

    private static func docx(_ pages: [Page], _ layout: Layout, to url: URL) throws {
        let emu = 12700.0 // per point
        var body = "", rels = "", files: [(String, Data)] = [], n = 0
        for (i, page) in pages.enumerated() {
            for (j, block) in page.blocks.enumerated() {
                let breakBefore = i > 0 && j == 0 ? "<w:pageBreakBefore/>" : ""
                n += 1
                switch block {
                case .paragraph(let runs, let spaceBefore, let lineHeight, let align):
                    let jc = align == .left ? "" : "<w:jc w:val=\"\(align == .center ? "center" : "both")\"/>"
                    body += "<w:p><w:pPr>\(breakBefore)<w:spacing w:before=\"\(twips(spaceBefore))\" w:after=\"0\" "
                        + "w:line=\"\(twips(lineHeight))\" w:lineRule=\"atLeast\"/>\(jc)</w:pPr>"
                    for group in byLink(runs) {
                        let text = group.runs.map(docxRun).joined()
                        if let link = group.link {
                            n += 1
                            rels += "<Relationship Id=\"rIdLink\(n)\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/hyperlink\" Target=\"\(xml(link))\" TargetMode=\"External\"/>"
                            body += "<w:hyperlink r:id=\"rIdLink\(n)\">\(text)</w:hyperlink>"
                        } else {
                            body += text
                        }
                    }
                    body += "</w:p>"
                case .picture(let data, let ext, _, let points, let spaceBefore, let indent):
                    let fit = layout.fitted(points)
                    let cx = Int(fit.width * emu), cy = Int(fit.height * emu)
                    files.append(("word/media/picture\(n).\(ext)", data))
                    rels += "<Relationship Id=\"rIdPic\(n)\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/image\" Target=\"media/picture\(n).\(ext)\"/>"
                    body += """
                    <w:p><w:pPr>\(breakBefore)<w:spacing w:before="\(twips(spaceBefore))" w:after="0"/><w:ind w:left="\(twips(indent))"/></w:pPr><w:r><w:drawing>\
                    <wp:inline distT="0" distB="0" distL="0" distR="0"><wp:extent cx="\(cx)" cy="\(cy)"/><wp:docPr id="\(n)" name="Picture \(n)"/>\
                    <a:graphic><a:graphicData uri="http://schemas.openxmlformats.org/drawingml/2006/picture"><pic:pic>\
                    <pic:nvPicPr><pic:cNvPr id="\(n)" name="picture\(n).\(ext)"/><pic:cNvPicPr/></pic:nvPicPr>\
                    <pic:blipFill><a:blip r:embed="rIdPic\(n)"/><a:stretch><a:fillRect/></a:stretch></pic:blipFill>\
                    <pic:spPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="\(cx)" cy="\(cy)"/></a:xfrm><a:prstGeom prst="rect"><a:avLst/></a:prstGeom></pic:spPr>\
                    </pic:pic></a:graphicData></a:graphic></wp:inline></w:drawing></w:r></w:p>
                    """
                }
            }
        }
        let (l, r, t, b) = layout.margins
        let document = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main" \
        xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" \
        xmlns:wp="http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing" \
        xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" \
        xmlns:pic="http://schemas.openxmlformats.org/drawingml/2006/picture"><w:body>\(body)\
        <w:sectPr><w:pgSz w:w="\(twips(layout.size.width))" w:h="\(twips(layout.size.height))"/>\
        <w:pgMar w:top="\(twips(t))" w:right="\(twips(r))" w:bottom="\(twips(b))" w:left="\(twips(l))" w:header="0" w:footer="0" w:gutter="0"/>\
        </w:sectPr></w:body></w:document>
        """
        files += [
            ("[Content_Types].xml", Data("""
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">\
            <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>\
            <Default Extension="xml" ContentType="application/xml"/><Default Extension="jpeg" ContentType="image/jpeg"/>\
            <Default Extension="png" ContentType="image/png"/>\
            <Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/></Types>
            """.utf8)),
            ("_rels/.rels", Data("""
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\
            <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/></Relationships>
            """.utf8)),
            ("word/_rels/document.xml.rels", Data("""
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\(rels)</Relationships>
            """.utf8)),
            ("word/document.xml", Data(document.utf8)),
        ]
        try zip(files, to: url)
    }

    private static func docxRun(_ run: Run) -> String {
        let f = xml(run.font), sz = Int((run.size * 2).rounded())
        var props = "<w:rFonts w:ascii=\"\(f)\" w:hAnsi=\"\(f)\" w:cs=\"\(f)\"/>"
        if run.bold { props += "<w:b/>" }
        if run.italic { props += "<w:i/>" }
        if let color = run.color { props += "<w:color w:val=\"\(color)\"/>" }
        if run.link != nil { props += "<w:u w:val=\"single\"/>" }
        props += "<w:sz w:val=\"\(sz)\"/><w:szCs w:val=\"\(sz)\"/>"
        return "<w:r><w:rPr>\(props)</w:rPr><w:t xml:space=\"preserve\">\(xml(run.text))</w:t></w:r>"
    }

    // MARK: ODT

    private static func odt(_ pages: [Page], _ layout: Layout, to url: URL) throws {
        var body = "", styles = "", manifest = "", files: [(String, Data)] = [], n = 0
        var textStyles: [String: String] = [:] // properties -> style name
        func span(_ run: Run) -> String {
            var props = "fo:font-family=\"\(xml(run.font))\" fo:font-size=\"\(run.size)pt\""
            if run.bold { props += " fo:font-weight=\"bold\"" }
            if run.italic { props += " fo:font-style=\"italic\"" }
            if let color = run.color { props += " fo:color=\"#\(color)\"" }
            if run.link != nil { props += " style:text-underline-style=\"solid\" style:text-underline-width=\"auto\" style:text-underline-color=\"font-color\"" }
            let name = textStyles[props] ?? {
                let name = "T\(textStyles.count + 1)"
                textStyles[props] = name
                styles += "<style:style style:name=\"\(name)\" style:family=\"text\"><style:text-properties \(props)/></style:style>"
                return name
            }()
            return "<text:span text:style-name=\"\(name)\">\(xml(run.text))</text:span>"
        }
        for (i, page) in pages.enumerated() {
            for (j, block) in page.blocks.enumerated() {
                n += 1
                let breakBefore = i > 0 && j == 0 ? " fo:break-before=\"page\"" : ""
                switch block {
                case .paragraph(let runs, let spaceBefore, let lineHeight, let align):
                    let alignment = align == .left ? "start" : align == .center ? "center" : "justify"
                    styles += "<style:style style:name=\"P\(n)\" style:family=\"paragraph\"><style:paragraph-properties fo:margin-top=\"\(spaceBefore)pt\" "
                        + "fo:margin-bottom=\"0pt\" style:line-height-at-least=\"\(lineHeight)pt\" fo:text-align=\"\(alignment)\"\(breakBefore)/></style:style>"
                    body += "<text:p text:style-name=\"P\(n)\">"
                    for group in byLink(runs) {
                        let spans = group.runs.map(span).joined()
                        body += group.link.map { "<text:a xlink:type=\"simple\" xlink:href=\"\(xml($0))\">\(spans)</text:a>" } ?? spans
                    }
                    body += "</text:p>"
                case .picture(let data, let ext, _, let points, let spaceBefore, let indent):
                    let fit = layout.fitted(points)
                    files.append(("Pictures/picture\(n).\(ext)", data))
                    manifest += "<manifest:file-entry manifest:full-path=\"Pictures/picture\(n).\(ext)\" manifest:media-type=\"image/\(ext)\"/>"
                    styles += "<style:style style:name=\"P\(n)\" style:family=\"paragraph\"><style:paragraph-properties fo:margin-top=\"\(spaceBefore)pt\" "
                        + "fo:margin-bottom=\"0pt\" fo:margin-left=\"\(indent)pt\"\(breakBefore)/></style:style>"
                    body += """
                    <text:p text:style-name="P\(n)"><draw:frame draw:name="Picture \(n)" text:anchor-type="as-char" \
                    svg:width="\(fit.width)pt" svg:height="\(fit.height)pt"><draw:image xlink:href="Pictures/picture\(n).\(ext)" \
                    xlink:type="simple" xlink:show="embed" xlink:actuate="onLoad"/></draw:frame></text:p>
                    """
                }
            }
        }
        let ns = """
        xmlns:office="urn:oasis:names:tc:opendocument:xmlns:office:1.0" xmlns:style="urn:oasis:names:tc:opendocument:xmlns:style:1.0" \
        xmlns:text="urn:oasis:names:tc:opendocument:xmlns:text:1.0" xmlns:draw="urn:oasis:names:tc:opendocument:xmlns:drawing:1.0" \
        xmlns:fo="urn:oasis:names:tc:opendocument:xmlns:xsl-fo-compatible:1.0" xmlns:xlink="http://www.w3.org/1999/xlink" \
        xmlns:svg="urn:oasis:names:tc:opendocument:xmlns:svg-compatible:1.0" office:version="1.3"
        """
        let content = """
        <?xml version="1.0" encoding="UTF-8"?>
        <office:document-content \(ns)><office:automatic-styles>\(styles)</office:automatic-styles>\
        <office:body><office:text>\(body)</office:text></office:body></office:document-content>
        """
        let (l, r, t, b) = layout.margins
        let pageStyles = """
        <?xml version="1.0" encoding="UTF-8"?>
        <office:document-styles \(ns)><office:automatic-styles><style:page-layout style:name="Layout">\
        <style:page-layout-properties fo:page-width="\(layout.size.width)pt" fo:page-height="\(layout.size.height)pt" \
        fo:margin-top="\(t)pt" fo:margin-bottom="\(b)pt" fo:margin-left="\(l)pt" fo:margin-right="\(r)pt"/>\
        </style:page-layout></office:automatic-styles><office:master-styles>\
        <style:master-page style:name="Standard" style:page-layout-name="Layout"/></office:master-styles></office:document-styles>
        """
        files += [
            ("META-INF/manifest.xml", Data("""
            <?xml version="1.0" encoding="UTF-8"?>
            <manifest:manifest xmlns:manifest="urn:oasis:names:tc:opendocument:xmlns:manifest:1.0" manifest:version="1.3">\
            <manifest:file-entry manifest:full-path="/" manifest:media-type="application/vnd.oasis.opendocument.text"/>\
            <manifest:file-entry manifest:full-path="content.xml" manifest:media-type="text/xml"/>\
            <manifest:file-entry manifest:full-path="styles.xml" manifest:media-type="text/xml"/>\(manifest)</manifest:manifest>
            """.utf8)),
            ("content.xml", Data(content.utf8)),
            ("styles.xml", Data(pageStyles.utf8)),
        ]
        try zip(files, to: url, mimetype: "application/vnd.oasis.opendocument.text")
    }

    // MARK: RTF

    private static func rtf(_ pages: [Page], _ layout: Layout) -> String {
        var fonts: [String] = [], colors: [String] = [], body = ""
        func index(_ value: String, in list: inout [String]) -> Int {
            if let i = list.firstIndex(of: value) { return i }
            list.append(value)
            return list.count - 1
        }
        func run(_ r: Run) -> String {
            var out = "{\\f\(index(r.font, in: &fonts))\\fs\(Int((r.size * 2).rounded()))"
            if r.bold { out += "\\b" }
            if r.italic { out += "\\i" }
            if let c = r.color { out += "\\cf\(index(c, in: &colors) + 1)" }
            if r.link != nil { out += "\\ul" }
            return out + " " + rtfEscape(r.text) + "}"
        }
        for (i, page) in pages.enumerated() {
            for (j, block) in page.blocks.enumerated() {
                let breakBefore = i > 0 && j == 0 ? "\\pagebb" : ""
                switch block {
                case .paragraph(let runs, let spaceBefore, let lineHeight, let align):
                    let q = align == .left ? "\\ql" : align == .center ? "\\qc" : "\\qj"
                    body += "\\pard\(breakBefore)\(q)\\sb\(twips(spaceBefore))\\sa0\\sl\(twips(lineHeight))\\slmult0 "
                    for group in byLink(runs) {
                        let text = group.runs.map(run).joined()
                        body += group.link.map { "{\\field{\\*\\fldinst{HYPERLINK \"\(rtfEscape($0))\"}}{\\fldrslt{\(text)}}}" } ?? text
                    }
                    body += "\\par\n"
                case .picture(let data, let ext, let pixels, let points, let spaceBefore, let indent):
                    let fit = layout.fitted(points)
                    body += "\\pard\(breakBefore)\\ql\\sb\(twips(spaceBefore))\\sa0\\li\(twips(indent)){\\pict\\\(ext == "png" ? "pngblip" : "jpegblip")"
                    body += "\\picw\(Int(pixels.width))\\pich\(Int(pixels.height))\\picwgoal\(twips(fit.width))\\pichgoal\(twips(fit.height))\n"
                    body += hex(data).chunked(128).joined(separator: "\n") + "}\\par\n"
                }
            }
        }
        let (l, r, t, b) = layout.margins
        let fontTable = fonts.enumerated().map { "{\\f\($0)\\fnil \(rtfEscape($1));}" }.joined()
        let colorTable = colors.map { hex -> String in
            let v = Int(hex, radix: 16) ?? 0
            return "\\red\(v >> 16 & 0xFF)\\green\(v >> 8 & 0xFF)\\blue\(v & 0xFF);"
        }.joined()
        return "{\\rtf1\\ansi\\ansicpg1252\\deff0{\\fonttbl\(fontTable)}{\\colortbl;\(colorTable)}"
            + "\\paperw\(twips(layout.size.width))\\paperh\(twips(layout.size.height))\\margl\(twips(l))\\margr\(twips(r))\\margt\(twips(t))\\margb\(twips(b))\n"
            + body + "}\n"
    }

    private static func hex(_ data: Data) -> String {
        let digits = Array("0123456789abcdef".utf8)
        var bytes = [UInt8](repeating: 0, count: data.count * 2)
        for (i, b) in data.enumerated() {
            bytes[i * 2] = digits[Int(b >> 4)]
            bytes[i * 2 + 1] = digits[Int(b & 0x0F)]
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    private static func rtfEscape(_ s: String) -> String {
        var out = ""
        for unit in s.utf16 {
            switch unit {
            case 0x5C: out += "\\\\"
            case 0x7B: out += "\\{"
            case 0x7D: out += "\\}"
            case 0x20..<0x80: out += String(UnicodeScalar(UInt8(unit)))
            default: out += "\\u\(Int16(bitPattern: unit))?"
            }
        }
        return out
    }

    // MARK: HTML

    private static func html(_ pages: [Page], title: String) -> String {
        var out = """
        <!doctype html><html><head><meta charset="utf-8"><title>\(xml(title))</title>
        <style>body{margin:0;background:#888}.page{margin:16px auto;background:#fff;box-shadow:0 1px 4px #0005;box-sizing:border-box}\
        .page p{margin:0}.page img{display:block;max-width:100%;height:auto}a{color:inherit}</style>
        </head><body>

        """
        for page in pages {
            let (l, r, t, b) = page.margins
            out += "<div class=\"page\" style=\"width:\(page.size.width)pt;min-height:\(page.size.height)pt;padding:\(t)pt \(r)pt \(b)pt \(l)pt\">\n"
            for block in page.blocks {
                switch block {
                case .paragraph(let runs, let spaceBefore, let lineHeight, let align):
                    let alignment = align == .left ? "left" : align == .center ? "center" : "justify"
                    out += "<p style=\"margin-top:\(spaceBefore)pt;line-height:\(lineHeight)pt;text-align:\(alignment)\">"
                    for group in byLink(runs) {
                        let spans = group.runs.map { r -> String in
                            var css = "font-family:'\(xml(r.font))',sans-serif;font-size:\(r.size)pt"
                            if r.bold { css += ";font-weight:bold" }
                            if r.italic { css += ";font-style:italic" }
                            if let c = r.color { css += ";color:#\(c)" }
                            return "<span style=\"\(css)\">\(xml(r.text))</span>"
                        }.joined()
                        out += group.link.map { "<a href=\"\(xml($0))\">\(spans)</a>" } ?? spans
                    }
                    out += "</p>\n"
                case .picture(let data, let ext, _, let points, let spaceBefore, let indent):
                    out += "<img style=\"margin:\(spaceBefore)pt 0 0 \(indent)pt;width:\(points.width)pt\" alt=\"\" src=\"data:image/\(ext);base64,\(data.base64EncodedString())\">\n"
                }
            }
            out += "</div>\n"
        }
        return out + "</body></html>\n"
    }

    // MARK: Zip

    /// A zip of `files`, with an uncompressed `mimetype` entry first when given, as ODF requires.
    private static func zip(_ files: [(String, Data)], to url: URL, mimetype: String? = nil) throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("morph-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: dir) }
        for (path, data) in files {
            let file = dir.appendingPathComponent(path)
            try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: file)
        }
        let archive = dir.appendingPathComponent("out.zip")
        if let mimetype {
            try Data(mimetype.utf8).write(to: dir.appendingPathComponent("mimetype"))
            try Shell.run("/usr/bin/zip", ["-X", "-0", "-q", archive.path, "mimetype"], in: dir)
        }
        try Shell.run("/usr/bin/zip", ["-X", "-r", "-q", "-nw", archive.path] + files.map(\.0), in: dir)
        try fm.moveItem(at: archive, to: url)
    }
}

private extension String {
    func chunked(_ size: Int) -> [String] {
        var out: [String] = [], i = startIndex
        while i < endIndex {
            let j = index(i, offsetBy: size, limitedBy: endIndex) ?? endIndex
            out.append(String(self[i..<j]))
            i = j
        }
        return out
    }
}
