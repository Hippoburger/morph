import AppKit
import PDFKit

// Reads a PDF page's content stream for what PDFKit doesn't say: where each run of text starts, the
// font it really uses, and whether it's drawn at all. Handwriting from a notes app or a scan can carry
// an OCR layer drawn invisibly (text render mode 3) so the page can be searched; pulling that out gives
// a word salad, so PDFLayout keeps such pages, and drawn parts of other pages, as pictures.

enum PDFPages {
    /// Where a run of text starts on the page (in page points), its font's PostScript name and
    /// whether it's drawn at all.
    struct Show { let point: CGPoint; let font: String; let visible: Bool }

    /// True when the page shows no text: everything it draws as text is invisible, or there is none.
    static func isPicture(_ page: PDFPage) -> Bool {
        !shows(page).contains(where: \.visible)
    }

    /// Every text-showing operator in the page's content, in order.
    // shortcut: positions are where each show operator starts; text after it in the same operator
    // isn't measured (that needs glyph widths). Fine while fonts change between operators, as in the
    // PDFs Word, Pages and iOS write. Text inside form XObjects isn't seen.
    static func shows(_ page: PDFPage) -> [Show] {
        guard let ref = page.pageRef else { return [] }
        let scan = Scan()
        var resources: CGPDFDictionaryRef?
        if let dict = ref.dictionary, CGPDFDictionaryGetDictionary(dict, "Resources", &resources), let resources {
            CGPDFDictionaryGetDictionary(resources, "Font", &scan.fonts)
        }
        let table = CGPDFOperatorTableCreate()!
        CGPDFOperatorTableSetCallback(table, "Tr") { scanner, info in
            var mode: CGPDFInteger = 0
            if CGPDFScannerPopInteger(scanner, &mode) { Scan.from(info).state.mode = Int(mode) }
        }
        CGPDFOperatorTableSetCallback(table, "Tf") { scanner, info in
            var size: CGPDFReal = 0
            var name: UnsafePointer<CChar>?
            guard CGPDFScannerPopNumber(scanner, &size), CGPDFScannerPopName(scanner, &name), let name else { return }
            Scan.from(info).setFont(name)
        }
        CGPDFOperatorTableSetCallback(table, "q") { _, info in Scan.from(info).stack.append(Scan.from(info).state) }
        CGPDFOperatorTableSetCallback(table, "Q") { _, info in
            let s = Scan.from(info)
            if let last = s.stack.popLast() { s.state = last }
        }
        CGPDFOperatorTableSetCallback(table, "cm") { scanner, info in
            if let m = Scan.matrix(scanner) { Scan.from(info).state.ctm = m.concatenating(Scan.from(info).state.ctm) }
        }
        CGPDFOperatorTableSetCallback(table, "BT") { _, info in Scan.from(info).setLine(.identity) }
        CGPDFOperatorTableSetCallback(table, "Tm") { scanner, info in
            if let m = Scan.matrix(scanner) { Scan.from(info).setLine(m) }
        }
        CGPDFOperatorTableSetCallback(table, "Td") { scanner, info in
            var x: CGPDFReal = 0, y: CGPDFReal = 0
            if CGPDFScannerPopNumber(scanner, &y), CGPDFScannerPopNumber(scanner, &x) { Scan.from(info).move(x, y) }
        }
        CGPDFOperatorTableSetCallback(table, "TD") { scanner, info in
            var x: CGPDFReal = 0, y: CGPDFReal = 0
            guard CGPDFScannerPopNumber(scanner, &y), CGPDFScannerPopNumber(scanner, &x) else { return }
            Scan.from(info).state.leading = -y
            Scan.from(info).move(x, y)
        }
        CGPDFOperatorTableSetCallback(table, "TL") { scanner, info in
            var leading: CGPDFReal = 0
            if CGPDFScannerPopNumber(scanner, &leading) { Scan.from(info).state.leading = leading }
        }
        CGPDFOperatorTableSetCallback(table, "T*") { _, info in Scan.from(info).move(0, -Scan.from(info).state.leading) }
        for op in ["Tj", "TJ"] {
            CGPDFOperatorTableSetCallback(table, op) { _, info in Scan.from(info).show() }
        }
        for op in ["'", "\""] {
            CGPDFOperatorTableSetCallback(table, op) { _, info in
                let s = Scan.from(info)
                s.move(0, -s.state.leading)
                s.show()
            }
        }
        let stream = CGPDFContentStreamCreateWithPage(ref)
        let scanner = CGPDFScannerCreate(stream, table, Unmanaged.passUnretained(scan).toOpaque())
        CGPDFScannerScan(scanner)
        CGPDFScannerRelease(scanner)
        CGPDFContentStreamRelease(stream)
        return scan.shows
    }

    /// The page drawn on white at 2× its size.
    static func render(_ page: PDFPage) throws -> CGImage {
        let bounds = page.bounds(for: .mediaBox)
        let rotated = page.rotation % 180 != 0
        let scale = 2.0
        let w = Int((rotated ? bounds.height : bounds.width) * scale), h = Int((rotated ? bounds.width : bounds.height) * scale)
        return try ImageEngine.render(width: w, height: h, opaque: true) { ctx, _ in
            ctx.scaleBy(x: scale, y: scale)
            page.draw(with: .mediaBox, to: ctx)
        }
    }

    /// The graphics and text state the scanner needs, saved and restored with q and Q.
    private final class Scan {
        struct State { var ctm = CGAffineTransform.identity; var mode = 0; var font = ""; var leading: CGFloat = 0 }
        var state = State()
        var stack: [State] = []
        var line = CGAffineTransform.identity
        var fonts: CGPDFDictionaryRef?
        var shows: [Show] = []

        static func from(_ info: UnsafeMutableRawPointer?) -> Scan { Unmanaged<Scan>.fromOpaque(info!).takeUnretainedValue() }

        static func matrix(_ scanner: CGPDFScannerRef) -> CGAffineTransform? {
            var v = [CGPDFReal](repeating: 0, count: 6)
            for i in (0..<6).reversed() { guard CGPDFScannerPopNumber(scanner, &v[i]) else { return nil } }
            return CGAffineTransform(a: v[0], b: v[1], c: v[2], d: v[3], tx: v[4], ty: v[5])
        }

        func setFont(_ name: UnsafePointer<CChar>) {
            var font: CGPDFDictionaryRef?
            var base: UnsafePointer<CChar>?
            if let fonts, CGPDFDictionaryGetDictionary(fonts, name, &font), let font, CGPDFDictionaryGetName(font, "BaseFont", &base), let base {
                state.font = String(cString: base)
            } else {
                state.font = String(cString: name)
            }
        }

        func setLine(_ m: CGAffineTransform) { line = m }
        func move(_ x: CGFloat, _ y: CGFloat) { line = CGAffineTransform(translationX: x, y: y).concatenating(line) }

        func show() {
            shows.append(Show(point: CGPoint.zero.applying(line.concatenating(state.ctm)), font: state.font, visible: state.mode != 3))
        }
    }
}
