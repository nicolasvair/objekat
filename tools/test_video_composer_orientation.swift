// The picture's ORIENTATION through both outputs of `VideoComposer`, with no app and no window:
// `video.render_frame`'s offscreen texture (`renderStill`) and the preview's drawable
// (`encode(_:intoDrawable:)`, into a `CAMetalLayer` set up as `VideoPreviewController.attach` sets it).
//
// What it pins (2026-11-26): CoreImage does not orient a drawable's texture as it orients a texture of
// ours — the composition rendered STRAIGHT into a drawable came out upside down while the stills were
// upright, so the preview window showed every picture mirrored top to bottom. A frame whose top half is
// white and bottom half black must read white on its first row and black on its last, in both outputs,
// at the stills' size and at Retina drawable sizes.
//
// From `tools/`:
//
//     swiftc -parse-as-library ../objekat/Video/VideoComposer.swift test_video_composer_orientation.swift \
//         -o /tmp/vorient && /tmp/vorient
//
// Exit: 0 if every assertion passes, 1 otherwise.

import Foundation
import CoreImage
import CoreVideo
import CoreGraphics
import Metal
import QuartzCore

var fails: [String] = []
var total = 0

func check(_ label: String, _ ok: Bool, _ detail: String = "") {
    total += 1
    if ok { print("ok    " + label) }
    else { fails.append(label); print("FAIL  \(label)  \(detail)") }
}

/// A BGRA buffer: the top half white, the bottom half black (row 0 = top, CoreVideo's order).
func topWhite(width: Int = 64, height: Int = 36) -> CVPixelBuffer {
    var pb: CVPixelBuffer?
    let attrs: [String: Any] = [kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
                                kCVPixelBufferMetalCompatibilityKey as String: true]
    CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, attrs as CFDictionary, &pb)
    let b = pb!
    CVPixelBufferLockBaseAddress(b, [])
    let base = CVPixelBufferGetBaseAddress(b)!.assumingMemoryBound(to: UInt8.self)
    let bpr = CVPixelBufferGetBytesPerRow(b)
    for y in 0..<height {
        let v: UInt8 = y < height / 2 ? 255 : 0
        for x in 0..<width {
            let p = base + y * bpr + x * 4
            p[0] = v; p[1] = v; p[2] = v; p[3] = 255
        }
    }
    CVPixelBufferUnlockBaseAddress(b, [])
    return b
}

/// The mean of the green channel over one row of BGRA bytes.
func rowLevel(_ bytes: [UInt8], width: Int, row: Int) -> Double {
    var s = 0
    for x in 0..<width { s += Int(bytes[(row * width + x) * 4 + 1]) }
    return Double(s) / Double(width)
}

func bytes(of image: CGImage) -> [UInt8] {
    let w = image.width, h = image.height
    var out = [UInt8](repeating: 0, count: w * h * 4)
    let ctx = CGContext(data: &out, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue)!
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))   // CGContext rows: top first in memory
    return out
}

@main
struct Main {
    static func main() {
        guard let c = VideoComposer() else { print("no Metal device"); exit(1) }
        let input = VideoComposer.Input(buffer: topWhite(), orientation: .up, opacity: 1)

        // 1. The still (`video.render_frame`).
        for (w, h) in [(64, 36), (640, 360)] {
            guard let img = c.renderStill([input], size: CGSize(width: w, height: h)) else {
                check("still \(w)x\(h) rendered", false); continue
            }
            let b = bytes(of: img)
            let top = rowLevel(b, width: w, row: 1), bottom = rowLevel(b, width: w, row: h - 2)
            check("still \(w)x\(h): top white, bottom black", top > 200 && bottom < 50,
                  "top \(top) bottom \(bottom)")
        }

        // 2. The drawable (the preview window), set up as the controller sets it.
        for (w, h) in [(640, 360), (1280, 720), (2560, 1440)] {
            let layer = CAMetalLayer()
            layer.device = c.device
            layer.pixelFormat = .bgra8Unorm
            layer.framebufferOnly = false
            layer.drawableSize = CGSize(width: w, height: h)
            guard let drawable = layer.nextDrawable(), let cb = c.queue.makeCommandBuffer() else {
                check("drawable \(w)x\(h) obtained", false); continue
            }
            c.encode([input], intoDrawable: drawable.texture, commandBuffer: cb)
            // Read it back: a plain copy into a shared texture.
            let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: w, height: h,
                                                                mipmapped: false)
            desc.storageMode = .shared
            let readback = c.device.makeTexture(descriptor: desc)!
            let blit = cb.makeBlitCommandEncoder()!
            blit.copy(from: drawable.texture, to: readback)
            blit.endEncoding()
            cb.commit()
            cb.waitUntilCompleted()
            var b = [UInt8](repeating: 0, count: w * h * 4)
            readback.getBytes(&b, bytesPerRow: w * 4, from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
            let top = rowLevel(b, width: w, row: 1), bottom = rowLevel(b, width: w, row: h - 2)
            check("drawable \(w)x\(h): top white, bottom black (row 0 = top of the window)",
                  top > 200 && bottom < 50, "top \(top) bottom \(bottom)")
        }

        print("\(total - fails.count)/\(total) passed")
        exit(fails.isEmpty ? 0 : 1)
    }
}
