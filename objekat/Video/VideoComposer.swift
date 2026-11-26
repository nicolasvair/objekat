import Foundation
import CoreImage
import CoreVideo
import Metal
import ImageIO
import UniformTypeIdentifiers

// MARK: - The picture graph (plan-video §4.5, §6.1): ONE composition for the preview and the stills
//
// The preview's display link and `video.render_frame` draw through THIS object and no other: the
// same CoreImage graph, the same fit, the same orientation, the same colour space. That is what makes
// a still taken headless a proof of what the window shows, and what will make the export (V6) able to
// claim "pixel preview = pixel export".
//
// What V0 measured and this honours: a single `CIContext` on the Metal queue with
// `cacheIntermediates = false`; the layers composed BOTTOM first; CoreImage renders into a texture
// UPSIDE DOWN, so the finished image is flipped once, here, and nowhere else.
//
// OPACITY (Q6, fades of the picture objects) is honoured here and nowhere else, in the ENCODED space
// (sRGB numbers, what an editor's dissolve does: a mid-grey 128 at 0.5 over black is 64) and not in
// CoreImage's linear working space (which would give ~93): the layers are brought to the encoded
// values (`matchedFromWorkingSpace`), mixed there, and brought back for the context's own output
// conversion — so colours and scale stay as V0 measured, only the weighting of the mix is chosen.
// Two layers whose opacities sum to 1 or less — a CROSSFADE — are ADDED, each weighted by its own
// opacity: the weights sum to 1 over the whole zone and the picture never dips towards black (a plain
// "over" of two partial layers would leave 25 % of black at mid-fade). Past 1 it is the ordinary "over",
// the layer behind weighted so that its share stays what its own opacity says.

nonisolated final class VideoComposer: @unchecked Sendable {

    /// One layer to draw: the decoded frame of a file, the orientation its track asks for, its opacity.
    struct Input {
        var buffer: CVPixelBuffer
        var orientation: CGImagePropertyOrientation
        var opacity: Double
    }

    let device: MTLDevice
    let queue: MTLCommandQueue
    let context: CIContext
    /// Tagged sRGB on the way out, as V0 measured it (the error against a CPU LUT stayed under 0.6/255).
    let colorSpace: CGColorSpace

    init?() {
        guard let d = MTLCreateSystemDefaultDevice(), let q = d.makeCommandQueue(),
              let cs = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        device = d
        queue = q
        colorSpace = cs
        context = CIContext(mtlCommandQueue: q, options: [.cacheIntermediates: false])
    }

    /// A layer fitted (aspect kept) and centred in the canvas, then brought to the ENCODED values the
    /// mix is done in, its alpha scaled by `opacity`.
    private func fitted(_ input: Input, size: CGSize, opacity: Double) -> CIImage? {
        var img = CIImage(cvPixelBuffer: input.buffer).oriented(input.orientation)
        let e = img.extent
        guard e.width > 0, e.height > 0, size.width > 0, size.height > 0 else { return nil }
        let s = min(size.width / e.width, size.height / e.height)
        let w = e.width * s, h = e.height * s
        img = img.transformed(by: CGAffineTransform(translationX: -e.minX, y: -e.minY))
                 .transformed(by: CGAffineTransform(scaleX: s, y: s))
                 .transformed(by: CGAffineTransform(translationX: (size.width - w) / 2,
                                                    y: (size.height - h) / 2))
        img = img.matchedFromWorkingSpace(to: colorSpace) ?? img
        if opacity < 0.999 {
            img = img.applyingFilter("CIColorMatrix", parameters: [
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: CGFloat(max(0, opacity)))])
        }
        return img
    }

    /// The finished image in a `size` canvas, black behind, layers fitted (aspect kept) and centred,
    /// already flipped for a texture. `inputs` are BOTTOM first.
    func image(for inputs: [Input], size: CGSize) -> CIImage {
        let canvas = CGRect(origin: .zero, size: size)
        let black = CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 1)).cropped(to: canvas)
        var out = black
        if inputs.count == 2, inputs[0].opacity + inputs[1].opacity <= 1 + 1e-9 {
            // A crossfade: add the two weighted layers (premultiplied), over black.
            if let back = fitted(inputs[0], size: size, opacity: inputs[0].opacity),
               let front = fitted(inputs[1], size: size, opacity: inputs[1].opacity) {
                out = front.applyingFilter("CIAdditionCompositing", parameters: [kCIInputBackgroundImageKey: back])
                           .composited(over: black)
            }
        } else {
            for (i, input) in inputs.enumerated() {
                var opacity = input.opacity
                // Behind a partial front layer, the share of this one must still be its own opacity.
                if inputs.count == 2, i == 0, inputs[1].opacity < 1 {
                    opacity = min(1, input.opacity / max(1e-6, 1 - inputs[1].opacity))
                }
                guard let img = fitted(input, size: size, opacity: opacity) else { continue }
                out = img.composited(over: out)
            }
        }
        // Back to the working space (the context's output conversion re-encodes it), and CoreImage draws
        // into a texture upside down (V0, measured): one flip, here.
        return (out.cropped(to: canvas).matchedToWorkingSpace(from: colorSpace) ?? out.cropped(to: canvas))
            .transformed(by: CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: size.height))
    }

    /// Encodes the graph on `commandBuffer` (not committed) into `texture`.
    func encode(_ inputs: [Input], into texture: MTLTexture, commandBuffer: MTLCommandBuffer) {
        let size = CGSize(width: texture.width, height: texture.height)
        context.render(image(for: inputs, size: size), to: texture, commandBuffer: commandBuffer,
                       bounds: CGRect(origin: .zero, size: size), colorSpace: colorSpace)
    }

    /// Compiles the CoreImage graph once, off the render path: the first composition of a session costs
    /// 40–100 ms (V0) and would otherwise be paid by the first frame of the first play.
    func prewarm() {
        var pb: CVPixelBuffer?
        let attrs: [String: Any] = [kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
                                    kCVPixelBufferMetalCompatibilityKey as String: true]
        guard CVPixelBufferCreate(nil, 64, 36, kCVPixelFormatType_32BGRA, attrs as CFDictionary, &pb) == kCVReturnSuccess,
              let buffer = pb else { return }
        _ = renderStill([Input(buffer: buffer, orientation: .up, opacity: 1),
                         Input(buffer: buffer, orientation: .right, opacity: 0.5)],
                        size: CGSize(width: 64, height: 36))
    }

    // MARK: A still, off screen

    /// Renders the layers into an offscreen BGRA texture, waits for the GPU, and returns the pixels as a
    /// `CGImage` (top row first).
    func renderStill(_ inputs: [Input], size: CGSize) -> CGImage? {
        let w = Int(size.width), h = Int(size.height)
        guard w > 0, h > 0 else { return nil }
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: w, height: h,
                                                            mipmapped: false)
        desc.usage = [.renderTarget, .shaderWrite, .shaderRead]
        // `.managed`, never `.shared`: on macOS a shared-storage TEXTURE is only accepted by Apple-silicon
        // GPUs (an Intel one fails `makeTexture` or the Metal validation). Managed is valid on both; the
        // CPU copy is brought up to date by the blit below, before `getBytes` reads it.
        desc.storageMode = .managed
        guard let tex = device.makeTexture(descriptor: desc), let cb = queue.makeCommandBuffer() else { return nil }
        encode(inputs, into: tex, commandBuffer: cb)
        if let blit = cb.makeBlitCommandEncoder() {
            blit.synchronize(resource: tex)
            blit.endEncoding()
        }
        cb.commit()
        cb.waitUntilCompleted()
        guard cb.status == .completed else { return nil }
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        tex.getBytes(&bytes, bytesPerRow: w * 4, from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
        guard let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
        let info = CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue
        return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
                       space: colorSpace, bitmapInfo: CGBitmapInfo(rawValue: info), provider: provider,
                       decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    /// Writes a PNG. False if the destination cannot be written.
    static func writePNG(_ image: CGImage, to url: URL) -> Bool {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
        else { return false }
        CGImageDestinationAddImage(dest, image, nil)
        return CGImageDestinationFinalize(dest)
    }
}
