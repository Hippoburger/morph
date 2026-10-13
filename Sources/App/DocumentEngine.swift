import AppKit
import PDFKit

// Documents. Word, ODT, RTF, TXT and HTML go through NSAttributedString, which reads and writes all of
// them; PDFs are written by printing a text view and read through PDFKit. Slides, spreadsheets and
// the office formats' PDFs go through LibreOffice when it's installed, which lays them out far better.

@MainActor
enum DocumentEngine {
    static func convert(_ input: URL, from src: String, to dst: String, out: URL) async throws -> [URL] {
        let sk = Formats.kind(of: src), dk = Formats.kind(of: dst)
        if Formats.need(from: src, to: dst) == .tool(.libreoffice) || (sk == .text && dk == .pdf && src != "txt" && Tool.libreoffice.path != nil) {
            try await libreoffice(input, to: dst, out: out)
            return [out]
        }
        switch (sk, dk) {
        case (.text, .text):
            try write(read(input, ext: src), to: out, ext: dst)
        case (.text, .pdf):
            try renderPDF(read(input, ext: src), to: out)
        case (.pdf, .text):
            try write(readPDF(input), to: out, ext: dst)
        case (.pdf, .image):
            return try await pdfToImages(input, ext: dst, first: out)
        case (.csv, .text):
            try csvHTML(input).write(to: out, atomically: true, encoding: .utf8)
        case (.csv, .pdf):
            try renderPDF(attributed(html: csvHTML(input)), to: out)
        default:
            throw ConversionError("Morph can't turn \(src.uppercased()) into \(dst.uppercased()).")
        }
        return [out]
    }

    // MARK: Rich text

    private static let types: [String: NSAttributedString.DocumentType] = [
        "txt": .plain, "rtf": .rtf, "html": .html, "doc": .docFormat, "docx": .officeOpenXML, "odt": .openDocument,
    ]

    private static func read(_ url: URL, ext: String) throws -> NSAttributedString {
        var options: [NSAttributedString.DocumentReadingOptionKey: Any] = [:]
        if let type = types[ext] { options[.documentType] = type }
        if ext == "txt" || ext == "html" { options[.characterEncoding] = String.Encoding.utf8.rawValue }
        do {
            return try NSAttributedString(url: url, options: options, documentAttributes: nil)
        } catch where ext == "txt" {
            // Not UTF-8: let AppKit guess the encoding.
            return try NSAttributedString(url: url, options: [.documentType: NSAttributedString.DocumentType.plain], documentAttributes: nil)
        }
    }

    private static func write(_ text: NSAttributedString, to url: URL, ext: String) throws {
        if ext == "txt" {
            try text.string.write(to: url, atomically: true, encoding: .utf8)
            return
        }
        guard let type = types[ext] else { throw ConversionError("Can't write \(ext.uppercased()).") }
        var attrs: [NSAttributedString.DocumentAttributeKey: Any] = [.documentType: type]
        if ext == "html" { attrs[.characterEncoding] = String.Encoding.utf8.rawValue }
        try text.data(from: NSRange(location: 0, length: text.length), documentAttributes: attrs).write(to: url)
    }

    private static func attributed(html: String) throws -> NSAttributedString {
        try NSAttributedString(data: Data(html.utf8),
                               options: [.documentType: NSAttributedString.DocumentType.html, .characterEncoding: String.Encoding.utf8.rawValue],
                               documentAttributes: nil)
    }

    // MARK: PDF

    /// Lays the text out on the locale's paper size with 0.75" margins and prints it to a file.
    private static func renderPDF(_ text: NSAttributedString, to url: URL) throws {
        let info = NSPrintInfo(dictionary: [.jobDisposition: NSPrintInfo.JobDisposition.save, .jobSavingURL: url])
        info.paperSize = NSPrintInfo.shared.paperSize
        for edge in [\NSPrintInfo.leftMargin, \.rightMargin, \.topMargin, \.bottomMargin] { info[keyPath: edge] = 54 }
        info.horizontalPagination = .fit
        info.verticalPagination = .automatic
        info.isHorizontallyCentered = false
        info.isVerticallyCentered = false

        let width = info.paperSize.width - info.leftMargin - info.rightMargin
        let view = NSTextView(frame: NSRect(x: 0, y: 0, width: width, height: 100))
        // Printing takes the view's appearance; in dark mode default text would come out white.
        view.appearance = NSAppearance(named: .aqua)
        view.drawsBackground = false
        view.isVerticallyResizable = true
        view.textStorage?.setAttributedString(text)
        if let container = view.textContainer, let layout = view.layoutManager {
            layout.ensureLayout(for: container)
            view.frame.size.height = max(100, layout.usedRect(for: container).height + view.textContainerInset.height * 2)
        }
        let op = NSPrintOperation(view: view, printInfo: info)
        op.showsPrintPanel = false
        op.showsProgressPanel = false
        guard op.run() else { throw ConversionError("Couldn't write the PDF.") }
    }

    private static func readPDF(_ url: URL) throws -> NSAttributedString {
        guard let doc = PDFDocument(url: url) else { throw ConversionError("Couldn't open the PDF.") }
        if doc.isLocked { throw ConversionError("The PDF is password protected.") }
        let text = NSMutableAttributedString()
        for i in 0..<doc.pageCount {
            guard let page = doc.page(at: i)?.attributedString else { continue }
            if text.length > 0 { text.append(NSAttributedString(string: "\n\n")) }
            text.append(page)
        }
        guard text.length > 0 else { throw ConversionError("The PDF has no text in it (it may be scanned).") }
        return text
    }

    /// One image per page at 144 dpi: `name.png` for a single page, `name page 1.png` and on for more.
    private static func pdfToImages(_ url: URL, ext: String, first: URL) async throws -> [URL] {
        guard let doc = PDFDocument(url: url), doc.pageCount > 0 else { throw ConversionError("Couldn't open the PDF.") }
        if doc.isLocked { throw ConversionError("The PDF is password protected.") }
        let dir = first.deletingLastPathComponent()
        let base = first.deletingPathExtension().lastPathComponent
        var outputs: [URL] = []
        for i in 0..<doc.pageCount {
            guard let page = doc.page(at: i) else { continue }
            let bounds = page.bounds(for: .mediaBox)
            let rotated = page.rotation % 180 != 0
            let scale = 2.0
            let w = Int((rotated ? bounds.height : bounds.width) * scale), h = Int((rotated ? bounds.width : bounds.height) * scale)
            let image = try ImageEngine.render(width: w, height: h, opaque: true) { ctx, _ in
                ctx.scaleBy(x: scale, y: scale)
                page.draw(with: .mediaBox, to: ctx)
            }
            let out = doc.pageCount == 1 ? first : OutputPath.unique(in: dir, base: "\(base) page \(i + 1)", ext: ext)
            try await Task.detached { try ImageEngine.write(image, to: out, ext: ext) }.value
            outputs.append(out)
        }
        return outputs
    }

    // MARK: CSV

    private static func csvHTML(_ url: URL) throws -> String {
        let rows = parseCSV(try String(contentsOf: url, encoding: .utf8))
        func esc(_ s: String) -> String {
            s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
        }
        var html = """
        <!doctype html><html><head><meta charset="utf-8"><title>\(esc(url.deletingPathExtension().lastPathComponent))</title>
        <style>body{font:13px -apple-system,Helvetica,sans-serif}table{border-collapse:collapse}td,th{border:1px solid #ccc;padding:4px 8px;text-align:left}th{background:#f2f2f2}</style>
        </head><body><table>

        """
        for (i, row) in rows.enumerated() {
            let tag = i == 0 ? "th" : "td"
            html += "<tr>" + row.map { "<\(tag)>\(esc($0))</\(tag)>" }.joined() + "</tr>\n"
        }
        return html + "</table></body></html>\n"
    }

    /// RFC 4180: quoted fields, doubled quotes, newlines inside quotes.
    private static func parseCSV(_ text: String) -> [[String]] {
        var rows: [[String]] = [], row: [String] = [], field = "", quoted = false
        var chars = text.makeIterator()
        var pending: Character? = nil
        while let c = pending ?? chars.next() {
            pending = nil
            if quoted {
                if c == "\"" {
                    if let n = chars.next() {
                        if n == "\"" { field.append("\"") } else { quoted = false; pending = n }
                    } else { quoted = false }
                } else { field.append(c) }
            } else {
                switch c {
                case "\"": quoted = true
                case ",": row.append(field); field = ""
                case "\n", "\r\n", "\r": row.append(field); rows.append(row); row = []; field = ""
                default: field.append(c)
                }
            }
        }
        if !field.isEmpty || !row.isEmpty { row.append(field); rows.append(row) }
        return rows
    }

    // MARK: LibreOffice

    private static func libreoffice(_ input: URL, to dst: String, out: URL) async throws {
        guard let soffice = Tool.libreoffice.path else { throw MissingToolError(tool: .libreoffice) }
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("morph-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        // Its own profile, so a LibreOffice window that's already open doesn't swallow the job.
        let profile = fm.temporaryDirectory.appendingPathComponent("morph-libreoffice-profile", isDirectory: true).absoluteString
        try await Task.detached {
            _ = try Shell.run(soffice, ["-env:UserInstallation=\(profile)", "--headless", "--convert-to", dst, "--outdir", dir.path, input.path])
        }.value
        guard let produced = try fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil).first else {
            throw ConversionError("LibreOffice didn't produce a \(dst.uppercased()) file.")
        }
        try fm.moveItem(at: produced, to: out)
    }
}
