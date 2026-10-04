import Foundation

// MARK: - The script canvas's raw image files — parsing only
//
// Two formats, both written by a script with numpy and `struct` only (plan §3.1, D5), both
// little-endian, row-major, row 0 = the TOP of the image (y max), column 0 = x min:
//
//   OBJKCNV1  "OBJKCNV1", u32 W, u32 H, f32 value of index 0, f32 value of index 255, u32 0,
//             256 × RGB palette (768 bytes), W·H uint8 indices.          Size = 796 + W·H exactly.
//   OBJKRGB1  "OBJKRGB1", u32 W, u32 H, 8 zero bytes, W·H RGBA premultiplied.
//                                                                         Size = 24 + 4·W·H exactly.
//
// This is the pure half: bytes in, a description of where everything lies out. No CGImage, no file
// access, no `CommandError` — `ScriptCanvasImage` builds the image and maps `ParseError` onto the
// API's errors. Compiled alone and asserted against the committed fixtures
// (@see tools/test_script_canvas_image.swift).
//
// The Python writer is `tools/scripts/spectral-gain/canvasfile.py`; the two must agree on the
// header, the sizes and the caps.
nonisolated enum ScriptCanvasImageFile {

    static let cnvMagic: [UInt8] = Array("OBJKCNV1".utf8)
    static let rgbMagic: [UInt8] = Array("OBJKRGB1".utf8)
    static let cnvHeaderSize = 796
    static let rgbHeaderSize = 24
    static let paletteSize = 768

    /// The caps, the writer's too.
    static let maxWidth = 16384
    static let maxHeight = 4096
    static let maxPixels = 32 * 1024 * 1024

    enum Kind: Equatable {
        /// 8-bit indices into a 256-entry RGB palette (`paletteRange`, 768 bytes, offsets from the
        /// start of the data); index 0 stands for `v0` and index 255 for `v255`.
        case indexed(v0: Float, v255: Float, paletteRange: Range<Int>)
        /// Premultiplied RGBA, 4 bytes a pixel.
        case rgba
    }

    struct Parsed: Equatable {
        var kind: Kind
        var width: Int
        var height: Int
        /// Where the pixels lie, as offsets from the start of the data (`data.startIndex + offset`).
        var pixelRange: Range<Int>
    }

    enum ParseError: Error, Equatable, CustomStringConvertible {
        /// Neither magic, or too short to hold a header.
        case notACanvasFile
        case zeroDimension
        case overCaps(width: Int, height: Int)
        case sizeMismatch(expected: Int, actual: Int)
        case nonFiniteRange

        var description: String {
            switch self {
            case .notACanvasFile: return "not an OBJKCNV1 or OBJKRGB1 file"
            case .zeroDimension: return "zero dimension"
            case .overCaps(let w, let h): return "image \(w)x\(h) is over the caps"
            case .sizeMismatch(let e, let a): return "size does not match the header (expected \(e) bytes, found \(a))"
            case .nonFiniteRange: return "value range is not finite"
            }
        }
    }

    /// True when `data` begins with one of the two magics (so the caller can fall back on ImageIO
    /// for anything else). Does not look further.
    static func hasCanvasMagic(_ data: Data) -> Bool {
        guard data.count >= 8 else { return false }
        let head = Array(data.prefix(8))
        return head == cnvMagic || head == rgbMagic
    }

    /// Reads the header and checks the size. Never reads the pixels.
    static func parse(_ data: Data) throws -> Parsed {
        guard data.count >= 8 else { throw ParseError.notACanvasFile }
        let magic = Array(data.prefix(8))
        if magic == cnvMagic {
            guard data.count >= cnvHeaderSize else { throw ParseError.notACanvasFile }
            let (w, h) = try dimensions(data)
            let v0 = Float(bitPattern: u32(data, 16))
            let v255 = Float(bitPattern: u32(data, 20))
            guard v0.isFinite, v255.isFinite else { throw ParseError.nonFiniteRange }
            let expected = cnvHeaderSize + w * h
            guard data.count == expected else {
                throw ParseError.sizeMismatch(expected: expected, actual: data.count)
            }
            let paletteStart = cnvHeaderSize - paletteSize
            return Parsed(kind: .indexed(v0: v0, v255: v255,
                                         paletteRange: paletteStart..<(paletteStart + paletteSize)),
                          width: w, height: h, pixelRange: cnvHeaderSize..<expected)
        }
        if magic == rgbMagic {
            guard data.count >= rgbHeaderSize else { throw ParseError.notACanvasFile }
            let (w, h) = try dimensions(data)
            let expected = rgbHeaderSize + 4 * w * h
            guard data.count == expected else {
                throw ParseError.sizeMismatch(expected: expected, actual: data.count)
            }
            return Parsed(kind: .rgba, width: w, height: h, pixelRange: rgbHeaderSize..<expected)
        }
        throw ParseError.notACanvasFile
    }

    // MARK: private

    private static func dimensions(_ data: Data) throws -> (Int, Int) {
        let w = Int(u32(data, 8))
        let h = Int(u32(data, 12))
        guard w >= 1, h >= 1 else { throw ParseError.zeroDimension }
        guard w <= maxWidth, h <= maxHeight, w * h <= maxPixels else {
            throw ParseError.overCaps(width: w, height: h)
        }
        return (w, h)
    }

    /// A little-endian u32 at `offset` from the start of the data, byte by byte (a `Data` slice is
    /// not guaranteed to be aligned, nor to start at index 0).
    private static func u32(_ data: Data, _ offset: Int) -> UInt32 {
        let i = data.startIndex + offset
        return UInt32(data[i])
            | UInt32(data[i + 1]) << 8
            | UInt32(data[i + 2]) << 16
            | UInt32(data[i + 3]) << 24
    }
}
