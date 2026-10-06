// The script canvas's raw image files — the parser, asserted against the committed fixtures.
//
// `ScriptCanvasImageFile` depends on Foundation alone: bytes in, a description out. The fixtures
// (`tools/fixtures/spectral/`, written by `tools/scripts/spectral-gain/make_fixture.py`) pin the
// FILE FORMAT only — both are 4 columns × 3 rows and every pixel is distinct and known:
//
//   fixture.objkcnv   v0 = -100, v255 = 0, palette = magma,  index(c, r) = (r·4 + c)·21
//   fixture.objkrgb   a = 40·(c + r) + 55, pixel(c, r) = (a·c/3, a·r/2, a/2, a)  (integer division)
//
//     swiftc -parse-as-library \
//         ../objekat/Shared/ScriptCanvasImageFile.swift test_script_canvas_image.swift \
//         -o /tmp/sci && /tmp/sci
//
// Run from `tools/` (or from anywhere: the fixtures are found relative to this file). Exit: 0 if
// every assertion passes, 1 otherwise. It compiles and passes (46/46, run on a Mac); it was first
// written on a machine with no Swift compiler.

import Foundation

var fails: [String] = []
var total = 0

func check(_ label: String, _ ok: Bool, _ detail: String = "") {
    total += 1
    if ok { print("ok    " + label) }
    else { fails.append(label); print("FAIL  \(label)  \(detail)") }
}

func fixtureData(_ name: String) -> Data? {
    let here = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    let candidates = [here.appendingPathComponent("fixtures/spectral/" + name),
                      URL(fileURLWithPath: "fixtures/spectral/" + name),
                      URL(fileURLWithPath: "tools/fixtures/spectral/" + name)]
    for url in candidates {
        if let d = try? Data(contentsOf: url) { return d }
    }
    return nil
}

func le32(_ v: UInt32) -> [UInt8] {
    [UInt8(v & 0xff), UInt8((v >> 8) & 0xff), UInt8((v >> 16) & 0xff), UInt8((v >> 24) & 0xff)]
}

/// Whether parsing throws exactly this error.
func throwsError(_ data: Data, _ expected: ScriptCanvasImageFile.ParseError) -> Bool {
    do {
        _ = try ScriptCanvasImageFile.parse(data)
        return false
    } catch let e as ScriptCanvasImageFile.ParseError {
        return e == expected
    } catch {
        return false
    }
}

func throwsAnything(_ data: Data) -> Bool {
    (try? ScriptCanvasImageFile.parse(data)) == nil
}

@main
enum ScriptCanvasImageTest {
  static func main() {

    // MARK: - The indexed fixture

    guard let cnv = fixtureData("fixture.objkcnv"), let rgb = fixtureData("fixture.objkrgb") else {
        print("FAIL  the fixtures could not be found (tools/fixtures/spectral/)")
        exit(1)
    }

    check("the indexed fixture is 796 + 12 bytes", cnv.count == 796 + 12, "\(cnv.count)")
    check("it begins with the magic", ScriptCanvasImageFile.hasCanvasMagic(cnv))
    do {
        let p = try ScriptCanvasImageFile.parse(cnv)
        check("indexed: width 4, height 3", p.width == 4 && p.height == 3)
        check("indexed: pixels lie at 796 for 12 bytes", p.pixelRange == 796..<808)
        if case .indexed(let v0, let v255, let paletteRange) = p.kind {
            check("indexed: v0 is -100", v0 == -100)
            check("indexed: v255 is 0", v255 == 0)
            check("indexed: the palette is 768 bytes at 28", paletteRange == 28..<796)
            let palette = Array(cnv[(cnv.startIndex + paletteRange.lowerBound)..<(cnv.startIndex + paletteRange.upperBound)])
            check("indexed: palette entry 0 is magma's black", palette[0] == 0 && palette[1] == 0 && palette[2] == 4)
            check("indexed: palette entry 255 is magma's pale yellow",
                  palette[765] == 252 && palette[766] == 253 && palette[767] == 191)
            check("indexed: palette entry 128", palette[384] == 183 && palette[385] == 55 && palette[386] == 121)
        } else {
            check("indexed: the kind is indexed", false)
        }
        var allIndices = true
        var detail = ""
        for r in 0..<3 {
            for c in 0..<4 {
                let got = cnv[cnv.startIndex + p.pixelRange.lowerBound + r * 4 + c]
                let want = UInt8((r * 4 + c) * 21)
                if got != want { allIndices = false; detail += " (c\(c),r\(r)) got \(got) want \(want)" }
            }
        }
        check("indexed: the pixel at every (c, r) is (r·4 + c)·21", allIndices, detail)
        check("indexed: the top-left pixel is index 0, the bottom-right 231",
              cnv[cnv.startIndex + 796] == 0 && cnv[cnv.startIndex + 796 + 11] == 231)
    } catch {
        check("the indexed fixture parses", false, "\(error)")
    }

    // MARK: - The RGBA fixture

    check("the rgba fixture is 24 + 48 bytes", rgb.count == 24 + 48, "\(rgb.count)")
    check("it begins with the magic", ScriptCanvasImageFile.hasCanvasMagic(rgb))
    do {
        let p = try ScriptCanvasImageFile.parse(rgb)
        check("rgba: width 4, height 3", p.width == 4 && p.height == 3)
        check("rgba: pixels lie at 24 for 48 bytes", p.pixelRange == 24..<72)
        check("rgba: the kind is rgba", p.kind == .rgba)
        var all = true
        var detail = ""
        for r in 0..<3 {
            for c in 0..<4 {
                let a = 40 * (c + r) + 55
                let want = [a * c / 3, a * r / 2, a / 2, a].map { UInt8($0) }
                let base = rgb.startIndex + p.pixelRange.lowerBound + 4 * (r * 4 + c)
                let got = Array(rgb[base..<(base + 4)])
                if got != want { all = false; detail += " (c\(c),r\(r)) got \(got) want \(want)" }
                if got[0] > got[3] || got[1] > got[3] || got[2] > got[3] {
                    all = false; detail += " (c\(c),r\(r)) not premultiplied"
                }
            }
        }
        check("rgba: the pixel at every (c, r) is the known one", all, detail)
    } catch {
        check("the rgba fixture parses", false, "\(error)")
    }

    // MARK: - Refusals

    check("an empty file is refused", throwsError(Data(), .notACanvasFile))
    check("seven bytes are refused", throwsError(Data([1, 2, 3, 4, 5, 6, 7]), .notACanvasFile))
    check("no magic, no canvas file", !ScriptCanvasImageFile.hasCanvasMagic(Data("PNG\r\n\u{1a}\n\0\0".utf8)))

    var wrongMagic = cnv
    wrongMagic[wrongMagic.startIndex + 7] = UInt8(ascii: "2")
    check("a wrong magic is refused", throwsError(wrongMagic, .notACanvasFile))
    check("a wrong magic is not a canvas magic", !ScriptCanvasImageFile.hasCanvasMagic(wrongMagic))
    check("a PNG's first bytes are refused",
          throwsError(Data([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0, 0, 0, 0]), .notACanvasFile))

    check("an indexed header cut short is refused",
          throwsError(cnv.prefix(400), .notACanvasFile))
    check("an rgba header cut short is refused",
          throwsError(rgb.prefix(20), .notACanvasFile))
    check("an indexed file missing its last pixel is refused",
          throwsError(cnv.prefix(cnv.count - 1), .sizeMismatch(expected: 808, actual: 807)))
    check("an rgba file missing its last byte is refused",
          throwsError(rgb.prefix(rgb.count - 1), .sizeMismatch(expected: 72, actual: 71)))
    var longer = cnv
    longer.append(0)
    check("an indexed file with a trailing byte is refused",
          throwsError(longer, .sizeMismatch(expected: 808, actual: 809)))
    var rgbLonger = rgb
    rgbLonger.append(contentsOf: [0, 0, 0, 0])
    check("an rgba file with a trailing pixel is refused",
          throwsError(rgbLonger, .sizeMismatch(expected: 72, actual: 76)))

    func patched(_ data: Data, at offset: Int, _ bytes: [UInt8]) -> Data {
        var d = data
        for (i, b) in bytes.enumerated() { d[d.startIndex + offset + i] = b }
        return d
    }
    check("a zero width is refused", throwsError(patched(cnv, at: 8, le32(0)), .zeroDimension))
    check("a zero height is refused", throwsError(patched(cnv, at: 12, le32(0)), .zeroDimension))
    check("an rgba zero width is refused", throwsError(patched(rgb, at: 8, le32(0)), .zeroDimension))
    check("an rgba zero height is refused", throwsError(patched(rgb, at: 12, le32(0)), .zeroDimension))
    check("a width over 16384 is refused",
          throwsError(patched(cnv, at: 8, le32(16385)), .overCaps(width: 16385, height: 3)))
    check("a height over 4096 is refused",
          throwsError(patched(cnv, at: 12, le32(4097)), .overCaps(width: 4, height: 4097)))
    check("more than 32 M pixels is refused",
          throwsError(patched(patched(rgb, at: 8, le32(16384)), at: 12, le32(2049)),
                      .overCaps(width: 16384, height: 2049)))
    check("a huge dimension does not overflow",
          throwsError(patched(cnv, at: 8, le32(0xffff_ffff)), .overCaps(width: 4_294_967_295, height: 3)))

    // The caps themselves are allowed — the size check then says the file is too short, which
    // proves the dimensions passed.
    check("exactly 16384 × 2048 passes the caps (and fails on size only)",
          throwsError(patched(patched(rgb, at: 8, le32(16384)), at: 12, le32(2048)),
                      .sizeMismatch(expected: 24 + 4 * 16384 * 2048, actual: 72)))
    check("exactly 4 × 4096 passes the caps",
          throwsError(patched(cnv, at: 12, le32(4096)), .sizeMismatch(expected: 796 + 4 * 4096, actual: 808)))

    let nan = Float.nan.bitPattern
    check("a NaN value range is refused", throwsError(patched(cnv, at: 16, le32(nan)), .nonFiniteRange))
    check("an infinite value range is refused",
          throwsError(patched(cnv, at: 20, le32(Float.infinity.bitPattern)), .nonFiniteRange))

    // A Data SLICE does not start at index 0: the parser must read relative to its start.
    var padded = Data([9, 9, 9])
    padded.append(cnv)
    let slice = padded.suffix(from: 3)
    check("a slice with a non-zero start index parses",
          (try? ScriptCanvasImageFile.parse(slice))?.pixelRange == 796..<808)
    check("…and is recognised", ScriptCanvasImageFile.hasCanvasMagic(slice))

    check("every error describes itself",
          ScriptCanvasImageFile.ParseError.sizeMismatch(expected: 1, actual: 2).description.contains("expected 1")
          && !ScriptCanvasImageFile.ParseError.zeroDimension.description.isEmpty)
    check("throwsAnything sanity", throwsAnything(Data()) && !throwsAnything(cnv))

    print("\n\(total - fails.count)/\(total) assertions pass")
    if !fails.isEmpty {
        print("FAILED: " + fails.joined(separator: "; "))
        exit(1)
    }
  }
}
