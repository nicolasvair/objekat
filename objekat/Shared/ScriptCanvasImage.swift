import Foundation
import CoreGraphics
import ImageIO

// MARK: - An image a script gave the canvas — loaded, with what the readout needs

/// The base image or a layer of a script canvas, decoded once when the script sends it
/// (`script.canvas.set_image` / `set_layer`). Immutable after `load`, which is what lets a
/// `ScriptCanvas` value be copied around freely: the pixels are shared.
///
/// Three kinds of file (@see ScriptCanvasImageFile for the first two, plan §3.1):
///   - `OBJKCNV1` → an INDEXED `CGImage` (the palette is the file's) and the indices kept, which is
///     what `value(column:row:)` — the pointer readout — reads. No conversion loop;
///   - `OBJKRGB1` → premultiplied RGBA, drawn as it comes;
///   - anything else ImageIO can read → a `CGImage`, with no readout.
///
/// Failures are the API's: `not_found` for a file that is not there, `bad_params` for anything
/// else (a corrupt file, a size over the caps, a format nobody reads).
final class ScriptCanvasImage {

    let path: String
    let cgImage: CGImage
    let width: Int
    let height: Int
    /// The indices of an `OBJKCNV1` image, row-major, row 0 = the TOP; nil for the other kinds.
    /// A copy (0-based), never a slice of the file's bytes.
    let indices: Data?
    /// The values of index 0 and index 255 (`OBJKCNV1`); 0 for the other kinds.
    let v0: Float
    let v255: Float
    /// Unique per loaded image: a view that caches what it drew from this image compares it.
    let generation: Int

    nonisolated(unsafe) private static var nextGeneration = 0

    /// True when pixels carry a VALUE (an indexed image) — what `has_values` answers.
    var hasValues: Bool { indices != nil }

    private init(path: String, cgImage: CGImage, width: Int, height: Int,
                 indices: Data?, v0: Float, v255: Float) {
        self.path = path
        self.cgImage = cgImage
        self.width = width
        self.height = height
        self.indices = indices
        self.v0 = v0
        self.v255 = v255
        Self.nextGeneration += 1
        self.generation = Self.nextGeneration
    }

    // MARK: Loading

    static func load(path: String) throws -> ScriptCanvasImage {
        guard FileManager.default.fileExists(atPath: path) else {
            throw CommandError(code: .not_found, message: "file not found: \(path)")
        }
        let url = URL(fileURLWithPath: path)
        guard let data = try? Data(contentsOf: url) else {
            throw CommandError(code: .bad_params, message: "cannot read \(path)")
        }
        if ScriptCanvasImageFile.hasCanvasMagic(data) {
            return try loadCanvasFile(path: path, data: data)
        }
        return try loadWithImageIO(path: path, url: url)
    }

    private static func bad(_ message: String) -> CommandError {
        CommandError(code: .bad_params, message: message)
    }

    private static func loadCanvasFile(path: String, data: Data) throws -> ScriptCanvasImage {
        let parsed: ScriptCanvasImageFile.Parsed
        do { parsed = try ScriptCanvasImageFile.parse(data) }
        catch { throw bad("\(path): \(error)") }

        let pixels = Data(data[(data.startIndex + parsed.pixelRange.lowerBound)
                               ..< (data.startIndex + parsed.pixelRange.upperBound)])
        guard let provider = CGDataProvider(data: pixels as CFData) else {
            throw bad("\(path): cannot read the pixels")
        }
        switch parsed.kind {
        case .indexed(let v0, let v255, let paletteRange):
            let table = [UInt8](data[(data.startIndex + paletteRange.lowerBound)
                                     ..< (data.startIndex + paletteRange.upperBound)])
            let image: CGImage? = table.withUnsafeBufferPointer { buf in
                guard let base = buf.baseAddress,
                      let space = CGColorSpace(indexedBaseSpace: CGColorSpaceCreateDeviceRGB(),
                                               last: 255, colorTable: base) else { return nil }
                return CGImage(width: parsed.width, height: parsed.height,
                               bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: parsed.width,
                               space: space, bitmapInfo: CGBitmapInfo(rawValue: 0),
                               provider: provider, decode: nil, shouldInterpolate: false,
                               intent: .defaultIntent)
            }
            guard let image else { throw bad("\(path): cannot build the indexed image") }
            return ScriptCanvasImage(path: path, cgImage: image, width: parsed.width,
                                     height: parsed.height, indices: pixels, v0: v0, v255: v255)
        case .rgba:
            let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
            guard let image = CGImage(width: parsed.width, height: parsed.height,
                                      bitsPerComponent: 8, bitsPerPixel: 32,
                                      bytesPerRow: parsed.width * 4,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: info,
                                      provider: provider, decode: nil, shouldInterpolate: false,
                                      intent: .defaultIntent) else {
                throw bad("\(path): cannot build the image")
            }
            return ScriptCanvasImage(path: path, cgImage: image, width: parsed.width,
                                     height: parsed.height, indices: nil, v0: 0, v255: 0)
        }
    }

    private static func loadWithImageIO(path: String, url: URL) throws -> ScriptCanvasImage {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              CGImageSourceGetCount(source) > 0,
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw bad("\(path): not an OBJKCNV1 or OBJKRGB1 file, and not an image ImageIO can read")
        }
        let w = image.width, h = image.height
        guard w >= 1, h >= 1, w <= ScriptCanvasImageFile.maxWidth, h <= ScriptCanvasImageFile.maxHeight,
              w * h <= ScriptCanvasImageFile.maxPixels else {
            throw bad("\(path): image \(w)x\(h) is over the caps")
        }
        return ScriptCanvasImage(path: path, cgImage: image, width: w, height: h,
                                 indices: nil, v0: 0, v255: 0)
    }

    // MARK: The readout

    /// The value under a pixel of an indexed image — `v0 + index · (v255 − v0) / 255` — and whether
    /// it is the floor (index 0, shown as "≤ v0": the image cannot say how far below it the real
    /// value was). nil for an image with no values, or a pixel outside it.
    func value(column: Int, row: Int) -> (value: Double, isFloor: Bool)? {
        guard let indices, column >= 0, column < width, row >= 0, row < height else { return nil }
        let idx = Int(indices[indices.startIndex + row * width + column])
        let v = Double(v0) + Double(idx) * (Double(v255) - Double(v0)) / 255.0
        return (v, idx == 0)
    }
}
