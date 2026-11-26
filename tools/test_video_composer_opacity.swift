// The picture graph's OPACITY (plan-video §4.5, Q-F6/Q-F7) with no app, no window and no engine:
// `VideoComposer.swift` compiled alone, solid-colour `CVPixelBuffer`s composed through `renderStill`
// (the very path of `video.render_frame`, the offscreen texture included — `.managed` + `synchronize`,
// which Rosetta does not test for an Intel GPU but at least exercises).
//
// What it pins: the mix is done in ENCODED values (a mid grey 128 at 0.5 over black is 64, not the
// ~93 CoreImage's linear working space would give); two partial layers whose opacities sum to 1 are
// a CROSSFADE and are added, with no dip towards black (128 at 0.5 over 128 at 0.5 stays 128, where
// a plain "over" gives 96); an opaque front layer hides the one behind; a partial front over an
// opaque back is the ordinary "over"; the bands of a letterboxed layer show the layer behind.
//
// From `tools/`:
//
//     swiftc -parse-as-library ../objekat/Video/VideoComposer.swift test_video_composer_opacity.swift \
//         -o /tmp/vcomp && /tmp/vcomp
//     # and under Rosetta:
//     swiftc -target x86_64-apple-macos12.0 -parse-as-library ../objekat/Video/VideoComposer.swift \
//         test_video_composer_opacity.swift -o /tmp/vcomp86 && arch -x86_64 /tmp/vcomp86
//
// Exit: 0 if every assertion passes, 1 otherwise.

import Foundation
import CoreImage
import CoreVideo
import CoreGraphics

var fails: [String] = []
var total = 0

func check(_ label: String, _ ok: Bool, _ detail: String = "") {
    total += 1
    if ok { print("ok    " + label) }
    else { fails.append(label); print("FAIL  \(label)  \(detail)") }
}

/// A solid BGRA buffer.
func solid(_ v: UInt8, width: Int = 64, height: Int = 36) -> CVPixelBuffer {
    var pb: CVPixelBuffer?
    let attrs: [String: Any] = [kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
                                kCVPixelBufferMetalCompatibilityKey as String: true]
    precondition(CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, attrs as CFDictionary, &pb) == kCVReturnSuccess)
    let b = pb!
    CVPixelBufferLockBaseAddress(b, [])
    let base = CVPixelBufferGetBaseAddress(b)!.assumingMemoryBound(to: UInt8.self)
    let stride = CVPixelBufferGetBytesPerRow(b)
    for y in 0..<height { for x in 0..<width {
        let p = base + y * stride + x * 4
        p[0] = v; p[1] = v; p[2] = v; p[3] = 255
    } }
    CVPixelBufferUnlockBaseAddress(b, [])
    return b
}

/// The red byte at (x, y) of a rendered still (top row first).
func pixel(_ img: CGImage, _ x: Int, _ y: Int) -> Int {
    let data = img.dataProvider!.data! as Data
    let stride = img.bytesPerRow
    return Int(data[y * stride + x * 4 + 2])
}

@main
enum VideoComposerOpacityTest {
  static func main() {
    guard let composer = VideoComposer() else {
        print("SKIP  no Metal device")
        exit(0)
    }
    let size = CGSize(width: 64, height: 36)
    func render(_ inputs: [VideoComposer.Input]) -> CGImage? { composer.renderStill(inputs, size: size) }
    func L(_ v: UInt8, _ a: Double, w: Int = 64, h: Int = 36) -> VideoComposer.Input {
        VideoComposer.Input(buffer: solid(v, width: w, height: h), orientation: .up, opacity: a)
    }
    func near(_ got: Int, _ want: Int, _ tol: Int = 2) -> Bool { abs(got - want) <= tol }

    // Sanity: the pipeline keeps a plain opaque grey.
    if let one = render([L(128, 1)]) {
        check("an opaque layer keeps its value (128)", near(pixel(one, 32, 18), 128), "\(pixel(one, 32, 18))")
    } else { check("a still renders", false) }

    // Q-F6: the mix is in encoded values.
    if let half = render([L(128, 0.5)]) {
        let v = pixel(half, 32, 18)
        check("128 at 0.5 over black is 64 (encoded), not ~93 (linear)", near(v, 64), "\(v)")
    } else { check("a half-opaque still renders", false) }

    // Q-F7: a crossfade has no dip.
    if let cross = render([L(50, 0.7), L(200, 0.3)]) {
        let v = pixel(cross, 32, 18)
        check("200 at 0.3 in front of 50 at 0.7: 95 (weights sum to 1)", near(v, 95), "\(v)")
    } else { check("a crossfade renders", false) }
    if let flat = render([L(128, 0.5), L(128, 0.5)]) {
        let v = pixel(flat, 32, 18)
        check("128 at 0.5 crossed with 128 at 0.5 stays 128 (a naive over gives 96)", near(v, 128), "\(v)")
    } else { check("a flat crossfade renders", false) }
    if let early = render([L(50, 0.9), L(200, 0.1)]) {
        let v = pixel(early, 32, 18)
        check("early in a crossfade: 0.9 x 50 + 0.1 x 200 = 65", near(v, 65), "\(v)")
    } else { check("an early crossfade renders", false) }

    // Opaque front hides the back; a partial front over an opaque back is the usual "over".
    if let opaque = render([L(50, 1), L(200, 1)]) {
        check("an opaque front layer hides the one behind", near(pixel(opaque, 32, 18), 200))
    } else { check("opaque stack renders", false) }
    if let over = render([L(50, 1), L(200, 0.5)]) {
        let v = pixel(over, 32, 18)
        check("200 at 0.5 over an opaque 50: 125", near(v, 125), "\(v)")
    } else { check("a partial front renders", false) }
    if let zero = render([L(100, 1), L(200, 0)]) {
        check("a front layer at opacity 0 leaves the one behind untouched", near(pixel(zero, 32, 18), 100))
    } else { check("a transparent front renders", false) }

    // Letterbox: a 4:3 layer in a 16:9 canvas leaves bands the layer behind shows through.
    if let box = render([L(50, 1), L(200, 1, w: 32, h: 24)]) {
        check("letterbox: the centre is the front layer", near(pixel(box, 32, 18), 200))
        check("letterbox: the left band shows the layer behind", near(pixel(box, 1, 18), 50), "\(pixel(box, 1, 18))")
        check("letterbox: the right band shows the layer behind", near(pixel(box, 62, 18), 50))
    } else { check("a letterboxed stack renders", false) }
    if let boxBlack = render([L(200, 1, w: 32, h: 24)]) {
        check("letterbox over nothing: black bands", near(pixel(boxBlack, 1, 18), 0))
    } else { check("a lone letterboxed layer renders", false) }

    print("\n\(total - fails.count)/\(total) passed")
    if !fails.isEmpty { print("FAILURES:"); for f in fails { print(" - " + f) }; exit(1) }
  }
}
