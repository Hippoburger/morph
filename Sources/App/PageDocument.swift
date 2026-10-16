import Foundation
import ImageIO
import UniformTypeIdentifiers

// Writes a document one PDF page at a time, each page either its text or a picture of it, for PDFs
// with handwritten or scanned pages (see PDFPages). AppKit's writers drop pictures, so DOCX, ODT, RTF
// and HTML are put together here.

enum PageDocument {
    enum Page {
        case text(String)
        /// JPEG data, its pixel size and the PDF page's size in points.
        case picture(Data, pixels: CGSize, points: CGSize)
    }

    static func picture(_ image: CGImage, points: CGSize) throws -> Page {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw ConversionError("Couldn't encode the page.")
        }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: 0.88] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw ConversionError("Couldn't encode the page.") }
        return .picture(data as Data, pixels: CGSize(width: image.width, height: image.height), points: points)
    }

    static func write(_ pages: [Page], to url: URL, ext: String) throws {
        switch ext {
        case "docx": try docx(pages, to: url)
        case "odt": try odt(pages, to: url)
        case "rtf": try Data(rtf(pages).utf8).write(to: url)
        case "html": try html(pages, title: url.deletingPathExtension().lastPathComponent).write(to: url, atomically: true, encoding: .utf8)
        case "doc":
            // Word 97's binary format can't be written here. LibreOffice can turn the DOCX into one;
            // without it the file is RTF, which Word, Pages and LibreOffice all open as a .doc.
            if let soffice = Tool.libreoffice.path {
                let docx = OutputPath.temporary(ext: "docx")
                defer { try? FileManager.default.removeItem(at: docx) }
                try self.docx(pages, to: docx)
                let dir = docx.deletingLastPathComponent().appendingPathComponent("morph-\(UUID().uuidString)", isDirectory: true)
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                defer { try? FileManager.default.removeItem(at: dir) }
                let profile = FileManager.default.temporaryDirectory.appendingPathComponent("morph-libreoffice-profile", isDirectory: true).absoluteString
                try Shell.run(soffice, ["-env:UserInstallation=\(profile)", "--headless", "--convert-to", "doc", "--outdir", dir.path, docx.path])
                try FileManager.default.moveItem(at: dir.appendingPathComponent(docx.deletingPathExtension().lastPathComponent + ".doc"), to: url)
            } else {
                try Data(rtf(pages).utf8).write(to: url)
            }
        default:
            throw ConversionError("Can't write \(ext.uppercased()) with pictures in it.")
        }
    }

    // MARK: Sizes

    /// The page size every page of the document gets: the first PDF page's, or US Letter.
    private static func pageSize(_ pages: [Page]) -> CGSize {
        for case .picture(_, _, let points) in pages { return points }
        return CGSize(width: 612, height: 792)
    }

    private static let margin: CGFloat = 18 // points, a quarter inch

    /// A picture's size in points, fitted inside the page's margins with room for the line it sits on.
    private static func fitted(_ points: CGSize, on page: CGSize) -> CGSize {
        let box = CGSize(width: page.width - margin * 2, height: (page.height - margin * 2) * 0.97)
        let s = min(box.width / points.width, box.height / points.height)
        return CGSize(width: floor(points.width * s), height: floor(points.height * s))
    }

    private static func lines(_ text: String) -> [String] {
        text.components(separatedBy: .newlines)
    }

    private static func xml(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
            .unicodeScalars.filter { $0.value >= 0x20 || $0 == "\t" }.map(String.init).joined()
    }

    // MARK: DOCX

    private static func docx(_ pages: [Page], to url: URL) throws {
        let size = pageSize(pages)
        let emu = 12700.0 // per point
        var body = "", rels = "", files: [(String, Data)] = []
        for (i, page) in pages.enumerated() {
            let breakBefore = i == 0 ? "" : "<w:pageBreakBefore/>"
            switch page {
            case .text(let text):
                for (j, line) in lines(text).enumerated() {
                    body += "<w:p><w:pPr>\(j == 0 ? breakBefore : "")<w:spacing w:after=\"0\"/></w:pPr><w:r><w:t xml:space=\"preserve\">\(xml(line))</w:t></w:r></w:p>"
                }
            case .picture(let data, _, let points):
                let n = i + 1, fit = fitted(points, on: size)
                let cx = Int(fit.width * emu), cy = Int(fit.height * emu)
                files.append(("word/media/page\(n).jpeg", data))
                rels += "<Relationship Id=\"rIdPage\(n)\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/image\" Target=\"media/page\(n).jpeg\"/>"
                body += """
                <w:p><w:pPr>\(breakBefore)<w:spacing w:before="0" w:after="0"/><w:jc w:val="center"/></w:pPr><w:r><w:drawing>\
                <wp:inline distT="0" distB="0" distL="0" distR="0"><wp:extent cx="\(cx)" cy="\(cy)"/><wp:docPr id="\(n)" name="Page \(n)"/>\
                <a:graphic><a:graphicData uri="http://schemas.openxmlformats.org/drawingml/2006/picture"><pic:pic>\
                <pic:nvPicPr><pic:cNvPr id="\(n)" name="page\(n).jpeg"/><pic:cNvPicPr/></pic:nvPicPr>\
                <pic:blipFill><a:blip r:embed="rIdPage\(n)"/><a:stretch><a:fillRect/></a:stretch></pic:blipFill>\
                <pic:spPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="\(cx)" cy="\(cy)"/></a:xfrm><a:prstGeom prst="rect"><a:avLst/></a:prstGeom></pic:spPr>\
                </pic:pic></a:graphicData></a:graphic></wp:inline></w:drawing></w:r></w:p>
                """
            }
        }
        let twips = { (pt: CGFloat) in Int(pt * 20) }
        let document = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main" \
        xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" \
        xmlns:wp="http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing" \
        xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" \
        xmlns:pic="http://schemas.openxmlformats.org/drawingml/2006/picture"><w:body>\(body)\
        <w:sectPr><w:pgSz w:w="\(twips(size.width))" w:h="\(twips(size.height))"/>\
        <w:pgMar w:top="\(twips(margin))" w:right="\(twips(margin))" w:bottom="\(twips(margin))" w:left="\(twips(margin))" w:header="0" w:footer="0" w:gutter="0"/>\
        </w:sectPr></w:body></w:document>
        """
        files += [
            ("[Content_Types].xml", Data("""
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">\
            <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>\
            <Default Extension="xml" ContentType="application/xml"/><Default Extension="jpeg" ContentType="image/jpeg"/>\
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

    // MARK: ODT

    private static func odt(_ pages: [Page], to url: URL) throws {
        let size = pageSize(pages)
        var body = "", manifest = "", files: [(String, Data)] = []
        for (i, page) in pages.enumerated() {
            let style = i == 0 ? "P" : "Break"
            switch page {
            case .text(let text):
                for (j, line) in lines(text).enumerated() {
                    body += "<text:p text:style-name=\"\(j == 0 ? style : "P")\">\(xml(line))</text:p>"
                }
            case .picture(let data, _, let points):
                let n = i + 1, fit = fitted(points, on: size)
                files.append(("Pictures/page\(n).jpeg", data))
                manifest += "<manifest:file-entry manifest:full-path=\"Pictures/page\(n).jpeg\" manifest:media-type=\"image/jpeg\"/>"
                body += """
                <text:p text:style-name="\(style)"><draw:frame draw:name="Page \(n)" text:anchor-type="as-char" \
                svg:width="\(fit.width)pt" svg:height="\(fit.height)pt"><draw:image xlink:href="Pictures/page\(n).jpeg" \
                xlink:type="simple" xlink:show="embed" xlink:actuate="onLoad"/></draw:frame></text:p>
                """
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
        <office:document-content \(ns)><office:automatic-styles>\
        <style:style style:name="P" style:family="paragraph" style:parent-style-name="Standard"><style:paragraph-properties fo:text-align="center" fo:margin-top="0pt" fo:margin-bottom="0pt"/></style:style>\
        <style:style style:name="Break" style:family="paragraph" style:parent-style-name="P"><style:paragraph-properties fo:break-before="page"/></style:style>\
        </office:automatic-styles><office:body><office:text>\(body)</office:text></office:body></office:document-content>
        """
        let styles = """
        <?xml version="1.0" encoding="UTF-8"?>
        <office:document-styles \(ns)><office:automatic-styles><style:page-layout style:name="Layout">\
        <style:page-layout-properties fo:page-width="\(size.width)pt" fo:page-height="\(size.height)pt" \
        fo:margin-top="\(margin)pt" fo:margin-bottom="\(margin)pt" fo:margin-left="\(margin)pt" fo:margin-right="\(margin)pt"/>\
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
            ("styles.xml", Data(styles.utf8)),
        ]
        try zip(files, to: url, mimetype: "application/vnd.oasis.opendocument.text")
    }

    // MARK: RTF

    private static func rtf(_ pages: [Page]) -> String {
        let size = pageSize(pages)
        let twips = { (pt: CGFloat) in Int(pt * 20) }
        var out = "{\\rtf1\\ansi\\ansicpg1252\\deff0{\\fonttbl{\\f0\\fswiss Helvetica;}}"
        out += "\\paperw\(twips(size.width))\\paperh\(twips(size.height))\\margl\(twips(margin))\\margr\(twips(margin))\\margt\(twips(margin))\\margb\(twips(margin))\n"
        for (i, page) in pages.enumerated() {
            if i > 0 { out += "\\page\n" }
            switch page {
            case .text(let text):
                out += "\\pard\\ql\\f0\\fs24 "
                out += lines(text).map(rtfEscape).joined(separator: "\\par\n") + "\\par\n"
            case .picture(let data, let pixels, let points):
                let fit = fitted(points, on: size)
                out += "\\pard\\qc{\\pict\\jpegblip\\picw\(Int(pixels.width))\\pich\(Int(pixels.height))"
                out += "\\picwgoal\(twips(fit.width))\\pichgoal\(twips(fit.height))\n"
                out += hex(data).chunked(128).joined(separator: "\n")
                out += "}\\par\n"
            }
        }
        return out + "}\n"
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
        <style>body{margin:0;background:#888}.page{max-width:900px;margin:16px auto;background:#fff;box-shadow:0 1px 4px #0005}\
        .page img{display:block;width:100%;height:auto}.page.text{padding:48px;font:15px/1.5 -apple-system,Helvetica,sans-serif;white-space:pre-wrap}</style>
        </head><body>

        """
        for (i, page) in pages.enumerated() {
            switch page {
            case .text(let text):
                out += "<div class=\"page text\">\(xml(text))</div>\n"
            case .picture(let data, _, _):
                out += "<div class=\"page\"><img alt=\"Page \(i + 1)\" src=\"data:image/jpeg;base64,\(data.base64EncodedString())\"></div>\n"
            }
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
