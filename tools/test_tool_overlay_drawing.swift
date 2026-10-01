// Smoke test of the Volume / Pan / Send / Stem overlays' Canvas drawing (ToolOverlayDrawing.swift).
//
// Renders every drawing function through `ImageRenderer` into PNGs (written to the current
// directory as out-*.png, for whoever wants to LOOK — nothing here judges the pixels) and asserts
// the one thing that can be asserted with no screen: the resolve cache stays BOUNDED however many
// distinct strings go through it, and the working set (every whole dB, every whole pan percent)
// fits under its capacity and stops growing.
//
//     swiftc -parse-as-library \
//         ../objekat/Timeline/ToolOverlayDrawing.swift ../objekat/Timeline/ToolOverlayGeometry.swift \
//         ../objekat/Timeline/SendColumns.swift test_tool_overlay_drawing.swift \
//         -o /tmp/tooldraw && (cd /tmp && ./tooldraw)
//
// `sendMinDb` / `sendMaxDb` are globals of SoundObject.swift, redefined here so the drawing file
// compiles alone. Exit: 0 if everything holds, 1 otherwise.

import SwiftUI
import AppKit

let sendMinDb: Float = -60
let sendMaxDb: Float = 12

@MainActor
func render(_ name: String, w: Double, h: Double, _ draw: @escaping (GraphicsContext, CGSize) -> Void) -> Bool {
    let view = Canvas { ctx, size in
        ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.gray))
        draw(ctx, size)
    }.frame(width: w, height: h)
    let r = ImageRenderer(content: view)
    r.scale = 2
    if let img = r.nsImage, let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
       let png = rep.representation(using: .png, properties: [:]) {
        try? png.write(to: URL(fileURLWithPath: "out-\(name).png"))
        print("ok    rendered \(name) (\(png.count) bytes)")
        return true
    }
    print("FAIL  could not render \(name)")
    return false
}

@main
struct DrawingSmoke {
    @MainActor static func main() {
        var failed = false
        func r(_ name: String, w: Double, h: Double, _ draw: @escaping (GraphicsContext, CGSize) -> Void) {
            if !render(name, w: w, h: h, draw) { failed = true }
        }

        let span: (x: Double, width: Double)? = (x: 20, width: 160)
        r("volfull", w: 200, h: 60) { c, s in drawVolumeVeilFull(c, size: s, volume: -3, isMuted: false, muteLabel: "M") }
        r("volfull-muted", w: 200, h: 60) { c, s in drawVolumeVeilFull(c, size: s, volume: -96, isMuted: true, muteLabel: "MUTE", span: span) }
        r("volmin", w: 120, h: 40) { c, s in drawVolumeVeilMinimal(c, size: s, volume: 6, isMuted: false) }
        r("volmin-narrow", w: 40, h: 40) { c, s in drawVolumeVeilMinimal(c, size: s, volume: -96, isMuted: true) }
        r("pan", w: 120, h: 80) { c, s in drawPanOverlay(c, size: s, pan: -0.4) }
        r("pan-span", w: 200, h: 80) { c, s in drawPanOverlay(c, size: s, pan: 1, span: span) }
        r("stem", w: 180, h: 40) { c, s in drawStemVeil(c, size: s, label: "Assign to 3 Drums", color: .orange) }
        r("stem-narrow", w: 70, h: 40) { c, s in drawStemVeil(c, size: s, label: "Assign to 3 Drums and a very long name", color: .orange) }
        r("send", w: 80, h: 40) { c, s in
            var a = c; a.translateBy(x: 4, y: 4)
            drawSendKnob(a, level: -10, enabled: true, focused: true, size: CGSize(width: 32, height: 32))
            var b = c; b.translateBy(x: 44, y: 4)
            drawSendKnob(b, level: -10, enabled: true, focused: false, automated: true, size: CGSize(width: 32, height: 32))
        }

        // The Send columns (the Canvas counterpart of ToolSendLayer) and the dispatcher the blocks'
        // Canvas calls: a focused column, an automated one, a faded (off) one; a narrow block.
        let cols = [
            ToolOverlaySendColumn(label: "Reverb", level: -6, enabled: true, focused: true, automated: false),
            ToolOverlaySendColumn(label: "Delay with a long name", level: -18, enabled: true, focused: false, automated: true),
            ToolOverlaySendColumn(label: "Room", level: -60, enabled: false, focused: false, automated: false),
        ]
        r("columns", w: 300, h: 110) { c, s in drawSendColumns(c, size: s, columns: cols, leadingInset: 0) }
        r("columns-inset-span", w: 300, h: 110) { c, s in
            drawSendColumns(c, size: s, columns: cols, leadingInset: 40, span: (x: 20, width: 250))
        }
        r("columns-short", w: 300, h: 50) { c, s in drawSendColumns(c, size: s, columns: cols, leadingInset: 0) }
        r("overlay-columns", w: 60, h: 90) { c, s in
            drawToolOverlay(c, CanvasToolOverlay(content: .sends(columns: Array(cols.prefix(2)), leadingInset: 0), span: nil), size: s)
        }
        r("overlay-volume", w: 120, h: 40) { c, s in
            drawToolOverlay(c, CanvasToolOverlay(content: .volumeMinimal(volume: -3, isMuted: true), span: (x: 10, width: 100)), size: s)
        }
        r("overlay-pan", w: 120, h: 80) { c, s in
            drawToolOverlay(c, CanvasToolOverlay(content: .pan(pan: 0.3), span: nil), size: s)
        }

        // The cache stays bounded however many distinct strings go through it.
        r("cache", w: 100, h: 20) { c, _ in
            for i in 0..<2000 {
                _ = ToolOverlayResolveCache.shared.text("s\(i)", style: .panLabel, in: c)
            }
        }
        let n = ToolOverlayResolveCache.shared.entryCount
        if n > ToolOverlayResolveCache.capacity { failed = true; print("FAIL  the cache outgrew its capacity: \(n)") }
        else { print("ok    the cache stays bounded (\(n) entries after 2000 distinct strings)") }

        // The working set — every whole dB and every whole pan percent, three rounds — fits with
        // room to spare and does not grow after the first round.
        ToolOverlayResolveCache.shared.removeAll()
        var afterFirst = 0
        r("working", w: 100, h: 20) { c, _ in
            for round in 0..<3 {
                for i in -96...40 {
                    _ = ToolOverlayResolveCache.shared.text(
                        ToolOverlayGeometry.volumeLabel(db: Float(i), compact: false), style: .volumeLevelFull, in: c)
                }
                for i in -100...100 {
                    _ = ToolOverlayResolveCache.shared.text(
                        ToolOverlayGeometry.panLabel(pan: Float(i) / 100), style: .panLabel, in: c)
                }
                if round == 0 { afterFirst = ToolOverlayResolveCache.shared.entryCount }
            }
        }
        let working = ToolOverlayResolveCache.shared.entryCount
        if working != afterFirst { failed = true; print("FAIL  the working set kept growing: \(afterFirst) → \(working)") }
        else { print("ok    the working set stops growing (\(working) entries)") }
        if working > ToolOverlayResolveCache.capacity / 2 {
            failed = true; print("FAIL  the working set is not comfortably under the capacity")
        } else { print("ok    the working set fits with room to spare (capacity \(ToolOverlayResolveCache.capacity))") }

        print(failed ? "FAILED" : "ALL PASS")
        exit(failed ? 1 : 0)
    }
}
