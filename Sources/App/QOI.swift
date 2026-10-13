import Foundation

// The Quite OK Image format (qoiformat.org), which nothing in macOS reads or writes.
// Pixels are straight (non-premultiplied) RGBA8.

enum QOI {
    private static func hash(_ p: (UInt8, UInt8, UInt8, UInt8)) -> Int {
        (Int(p.0) * 3 + Int(p.1) * 5 + Int(p.2) * 7 + Int(p.3) * 11) % 64
    }

    static func decode(_ data: Data) throws -> (width: Int, height: Int, rgba: [UInt8]) {
        let b = [UInt8](data)
        guard b.count >= 22, b[0] == 0x71, b[1] == 0x6F, b[2] == 0x69, b[3] == 0x66 else { throw ConversionError("Not a QOI file.") }
        func u32(_ i: Int) -> Int { Int(b[i]) << 24 | Int(b[i + 1]) << 16 | Int(b[i + 2]) << 8 | Int(b[i + 3]) }
        let w = u32(4), h = u32(8)
        guard w > 0, h > 0, w * h <= 400_000_000 else { throw ConversionError("QOI image is empty or too large.") }
        var out = [UInt8](repeating: 0, count: w * h * 4)
        var index = [(UInt8, UInt8, UInt8, UInt8)](repeating: (0, 0, 0, 0), count: 64)
        var px: (UInt8, UInt8, UInt8, UInt8) = (0, 0, 0, 255)
        var i = 14, run = 0
        let end = b.count - 8
        for o in stride(from: 0, to: out.count, by: 4) {
            if run > 0 {
                run -= 1
            } else if i < end {
                let b1 = b[i]; i += 1
                if b1 == 0xFE {
                    px.0 = b[i]; px.1 = b[i + 1]; px.2 = b[i + 2]; i += 3
                } else if b1 == 0xFF {
                    px = (b[i], b[i + 1], b[i + 2], b[i + 3]); i += 4
                } else {
                    switch b1 >> 6 {
                    case 0: px = index[Int(b1)]
                    case 1:
                        px.0 &+= ((b1 >> 4) & 3) &- 2
                        px.1 &+= ((b1 >> 2) & 3) &- 2
                        px.2 &+= (b1 & 3) &- 2
                    case 2:
                        let b2 = b[i]; i += 1
                        let vg = (b1 & 0x3F) &- 32
                        px.0 &+= vg &- 8 &+ ((b2 >> 4) & 0x0F)
                        px.1 &+= vg
                        px.2 &+= vg &- 8 &+ (b2 & 0x0F)
                    default: run = Int(b1 & 0x3F)
                    }
                }
                index[hash(px)] = px
            }
            out[o] = px.0; out[o + 1] = px.1; out[o + 2] = px.2; out[o + 3] = px.3
        }
        return (w, h, out)
    }

    static func encode(width w: Int, height h: Int, rgba: [UInt8]) -> Data {
        var out = [UInt8]()
        out.reserveCapacity(14 + w * h * 5 + 8)
        out += [0x71, 0x6F, 0x69, 0x66]
        for v in [w, h] { out += [UInt8(v >> 24 & 0xFF), UInt8(v >> 16 & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)] }
        out += [4, 0]
        var index = [(UInt8, UInt8, UInt8, UInt8)](repeating: (0, 0, 0, 0), count: 64)
        var prev: (UInt8, UInt8, UInt8, UInt8) = (0, 0, 0, 255)
        var run = 0
        let last = rgba.count - 4
        for o in stride(from: 0, to: rgba.count, by: 4) {
            let px = (rgba[o], rgba[o + 1], rgba[o + 2], rgba[o + 3])
            if px == prev {
                run += 1
                if run == 62 || o == last { out.append(0xC0 | UInt8(run - 1)); run = 0 }
                continue
            }
            if run > 0 { out.append(0xC0 | UInt8(run - 1)); run = 0 }
            let h = hash(px)
            if index[h] == px {
                out.append(UInt8(h))
            } else {
                index[h] = px
                if px.3 == prev.3 {
                    let vr = Int8(bitPattern: px.0 &- prev.0)
                    let vg = Int8(bitPattern: px.1 &- prev.1)
                    let vb = Int8(bitPattern: px.2 &- prev.2)
                    let vgr = vr &- vg, vgb = vb &- vg
                    if (-2...1).contains(vr), (-2...1).contains(vg), (-2...1).contains(vb) {
                        out.append(0x40 | UInt8(vr + 2) << 4 | UInt8(vg + 2) << 2 | UInt8(vb + 2))
                    } else if (-8...7).contains(vgr), (-32...31).contains(vg), (-8...7).contains(vgb) {
                        out.append(0x80 | UInt8(vg + 32))
                        out.append(UInt8(vgr + 8) << 4 | UInt8(vgb + 8))
                    } else {
                        out += [0xFE, px.0, px.1, px.2]
                    }
                } else {
                    out += [0xFF, px.0, px.1, px.2, px.3]
                }
            }
            prev = px
        }
        out += [0, 0, 0, 0, 0, 0, 0, 1]
        return Data(out)
    }
}
