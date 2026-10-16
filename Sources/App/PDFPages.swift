import AppKit
import PDFKit

// Tells a PDF page of real text from one that's a picture: handwriting from a notes app or a scan.
// Those can still carry text, but it's an OCR layer drawn invisibly (text render mode 3) under the
// picture so the page can be searched, and pulling it out gives a word salad in random sizes. Such a
// page is worth keeping as an image instead.

enum PDFPages {
    /// True when the page shows no text: everything it draws as text is invisible, or there is none.
    static func isPicture(_ page: PDFPage) -> Bool {
        guard let ref = page.pageRef else { return false }
        let scan = Scan()
        let table = CGPDFOperatorTableCreate()!
        CGPDFOperatorTableSetCallback(table, "Tr") { scanner, info in
            var mode: CGPDFInteger = 0
            if CGPDFScannerPopInteger(scanner, &mode) { Scan.from(info).setMode(Int(mode)) }
        }
        CGPDFOperatorTableSetCallback(table, "q") { _, info in Scan.from(info).save() }
        CGPDFOperatorTableSetCallback(table, "Q") { _, info in Scan.from(info).restore() }
        for op in ["Tj", "TJ", "'", "\""] {
            CGPDFOperatorTableSetCallback(table, op) { _, info in Scan.from(info).show() }
        }
        let stream = CGPDFContentStreamCreateWithPage(ref)
        let scanner = CGPDFScannerCreate(stream, table, Unmanaged.passUnretained(scan).toOpaque())
        CGPDFScannerScan(scanner)
        CGPDFScannerRelease(scanner)
        CGPDFContentStreamRelease(stream)
        return scan.visible == 0
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

    /// Text render modes live in the graphics state, so they're saved and restored with it.
    private final class Scan {
        var modes = [0]
        var visible = 0

        static func from(_ info: UnsafeMutableRawPointer?) -> Scan { Unmanaged<Scan>.fromOpaque(info!).takeUnretainedValue() }
        func setMode(_ mode: Int) { modes[modes.count - 1] = mode }
        func save() { modes.append(modes[modes.count - 1]) }
        func restore() { if modes.count > 1 { modes.removeLast() } }
        func show() { if modes[modes.count - 1] != 3 { visible += 1 } }
    }
}
