#if DEBUG
import AppKit
import Foundation

/// `view.snapshot` — DEBUG ONLY. A picture of the timeline as the app itself renders it, written to
/// a PNG, so that a script (or an agent that can open an image) can compare the batched Canvas with
/// the rich SwiftUI views (`debug.force_rich_blocks` / `force_rich_tools` / `force_rich_previews`)
/// pixel against pixel without a screen capture tool (`screencapture` needs the Screen Recording
/// permission, which a test session has no business asking for).
///
/// Three ways to take the picture. Validated 2026-10-02 on a nested-groups scene: `cache` and
/// `layer` show the Canvas content (blocks, waveforms, bands, masks, crossfades); `window` came
/// back BLANK (one colour) — hence `cache` is the default:
///
///   • `window` — `CGWindowListCreateImage` on the app's OWN window, the window server's
///     composited pixels: exactly what is on screen, Canvas, layers and Metal included. Capturing
///     one's own windows needs no permission. The function is marked unavailable to Swift by the
///     macOS 15 SDK (ScreenCaptureKit replaces it), so it is resolved at run time with `dlsym`; it
///     still answers on macOS 15. The window must be ON SCREEN (not minimised, its Space visible).
///   • `cache` (default) — `NSView.cacheDisplay(in:to:)` on the window's content view: AppKit's own offscreen
///     render. Works with the window hidden, but may miss layer-only content.
///   • `layer` — `CALayer.render(in:)` on the content view's layer: the layer tree's contents.
///
/// The region is the VISIBLE TIMELINE by default (the hover tracker's visible rect: what
/// `input.*` calls "the viewport", origin top-left), or the whole window (`region: "window"`).
/// The answer carries a few numbers that let a script tell a blank picture from a real one without
/// opening it: `distinct_colors` (sampled), `dominant_fraction` (the share of the most common
/// colour) and an FNV-1a `hash` of the pixels.
///
/// Read-only: never touches the document (`undo: none`). Call `wait_idle` first — a redraw that has
/// not landed is not in the picture.
extension CommandRegistry {

    func registerSnapshotCommands() {
        register("view.snapshot",
                 summary: """
                 DEBUG. Writes a PNG of the timeline as rendered (the visible timeline by default, \
                 or the whole window): `method` cache (NSView.cacheDisplay — default) | window \
                 (CGWindowListCreateImage, came back blank in testing) | layer \
                 (CALayer.render). Answers the file, its pixel size, the scale, and \
                 `distinct_colors` / `dominant_fraction` / `hash` to tell a blank image from a real \
                 one. `wait_idle` first. UI mode only. Not present in Release builds.
                 """,
                 params: [ParamSpec("path", "string", "Where to write the PNG (absolute path)."),
                          ParamSpec("method", "string", required: false, "cache (default) | window | layer."),
                          ParamSpec("region", "string", required: false, "timeline (default) | window.")],
                 undo: .none) { p in
            let path = try p.string("path")
            let method = try p.string("method", or: "cache")
            let region = try p.string("region", or: "timeline")
            let host = try InputSynth.timelineHost()
            guard let window = host.window, let content = window.contentView else {
                throw CommandError(code: .invalid_state, message: "no window (headless?)")
            }
            // The region, in WINDOW coordinates (origin bottom-left).
            let rectInWindow: CGRect
            switch region {
            case "timeline": rectInWindow = host.convert(host.visibleRect, to: nil)
            case "window":   rectInWindow = content.convert(content.bounds, to: nil)
            default:
                throw CommandError(code: .bad_params, message: "region: timeline | window")
            }
            let image: CGImage?
            switch method {
            case "window": image = Self.snapshotWindow(window, rectInWindow: rectInWindow)
            case "cache":  image = Self.snapshotCache(content, rect: content.convert(rectInWindow, from: nil))
            case "layer":  image = Self.snapshotLayer(content, rect: content.convert(rectInWindow, from: nil))
            default:
                throw CommandError(code: .bad_params, message: "method: window | cache | layer")
            }
            guard let image else {
                throw CommandError(code: .internal_error,
                                   message: "no image from method '\(method)' (window off screen, or the API refused)")
            }
            let url = URL(fileURLWithPath: path)
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                     withIntermediateDirectories: true)
            guard let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else {
                throw CommandError(code: .internal_error, message: "cannot write \(path)")
            }
            CGImageDestinationAddImage(dest, image, nil)
            guard CGImageDestinationFinalize(dest) else {
                throw CommandError(code: .internal_error, message: "cannot write \(path)")
            }
            let stats = Self.snapshotStats(image)
            return .object([
                "path": .string(path),
                "method": .string(method),
                "region": .string(region),
                "width": .int(image.width),
                "height": .int(image.height),
                "points_w": .number(Double(rectInWindow.width)),
                "points_h": .number(Double(rectInWindow.height)),
                "scale": .number(rectInWindow.width > 0 ? Double(image.width) / Double(rectInWindow.width) : 0),
                "distinct_colors": .int(stats.distinct),
                "dominant_fraction": .number(stats.dominant),
                "hash": .string(stats.hash),
                "view": try Self.viewState(),
            ])
        }
    }

    // MARK: - The three ways

    /// The window server's own pixels for our window, cropped to the region. Resolved at run time:
    /// the macOS 15 SDK marks `CGWindowListCreateImage` unavailable to Swift.
    private static func snapshotWindow(_ window: NSWindow, rectInWindow: CGRect) -> CGImage? {
        typealias Fn = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
        guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage") else { return nil }
        let create = unsafeBitCast(sym, to: Fn.self)
        // Global display coordinates, origin at the TOP-left of the main screen.
        let onScreen = window.convertToScreen(rectInWindow)
        let mainHeight = NSScreen.screens.first?.frame.height ?? 0
        let global = CGRect(x: onScreen.minX, y: mainHeight - onScreen.maxY,
                            width: onScreen.width, height: onScreen.height)
        let includingWindow: UInt32 = 1 << 3          // kCGWindowListOptionIncludingWindow
        let options: UInt32 = (1 << 0) | (1 << 4)     // boundsIgnoreFraming | nominalResolution
        return create(global, includingWindow, UInt32(window.windowNumber), options)?.takeRetainedValue()
    }

    private static func snapshotCache(_ view: NSView, rect: CGRect) -> CGImage? {
        guard rect.width >= 1, rect.height >= 1,
              let rep = view.bitmapImageRepForCachingDisplay(in: rect) else { return nil }
        view.cacheDisplay(in: rect, to: rep)
        return rep.cgImage
    }

    private static func snapshotLayer(_ view: NSView, rect: CGRect) -> CGImage? {
        guard let layer = view.layer, rect.width >= 1, rect.height >= 1 else { return nil }
        let scale = view.window?.backingScaleFactor ?? 2
        let w = Int(rect.width * scale), h = Int(rect.height * scale)
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.scaleBy(x: scale, y: scale)
        if view.isFlipped {
            ctx.translateBy(x: 0, y: rect.height)
            ctx.scaleBy(x: 1, y: -1)
        }
        ctx.translateBy(x: -rect.minX, y: -rect.minY)
        layer.render(in: ctx)
        return ctx.makeImage()
    }

    // MARK: - Numbers that tell a blank picture from a real one

    private static func snapshotStats(_ image: CGImage) -> (distinct: Int, dominant: Double, hash: String) {
        let w = image.width, h = image.height
        guard w > 0, h > 0,
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let data = ctx.data else { return (0, 0, "") }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        let px = data.bindMemory(to: UInt32.self, capacity: w * h)
        var hash: UInt64 = 0xcbf29ce484222325
        var counts: [UInt32: Int] = [:]
        let stride = max(1, (w * h) / 200_000)   // a sample is enough for the colour census
        var sampled = 0
        for i in 0..<(w * h) {
            let v = px[i]
            hash = (hash ^ UInt64(v)) &* 0x100000001b3
            if i % stride == 0 { counts[v, default: 0] += 1; sampled += 1 }
        }
        let dominant = sampled > 0 ? Double(counts.values.max() ?? 0) / Double(sampled) : 0
        return (counts.count, (dominant * 10000).rounded() / 10000, String(hash, radix: 16))
    }
}
#endif
