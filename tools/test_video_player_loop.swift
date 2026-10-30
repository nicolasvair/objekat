// The players behind the picture in looped playback (plan-video §4.4), with no window and no engine:
// the display link's own loop — resolver, then `VideoPlayerEngine.prepare` — run at 60 Hz on a thread
// of its own, over a simulated clock, against a real file of the corpus whose frames carry their
// number as a barcode.
//
// What it pins: the picture goes on renewing itself after EVERY loop turn (transport loop, a looping
// group, a whole-file group loop, a turn shorter than a second), and the frame on screen is the right
// one again soon after each turn. The trap it was written for: `preroll(atRate:)` never calls back on
// a running player, which froze the picture for good at the second turn.
//
// From the repository root, with a corpus built by `tools/video_scenario_common.make_fixtures`:
//
//     swiftc -O -parse-as-library -swift-version 5 \
//         objekat/Video/VideoPlayerEngine.swift objekat/Video/VideoComposer.swift \
//         objekat/Shared/VideoTimeMap.swift objekat/Shared/WaveformShaping.swift \
//         objekat/SoundObject/FadeCurve.swift tools/test_video_player_loop.swift \
//         -o /tmp/vpl && /tmp/vpl <corpus>/aac_mp4.mp4
//
// Exit: 0 if every assertion passes, 1 otherwise. The players need the main thread free for their
// status: the ticks never run on it.

import Foundation
import AVFoundation
import CoreImage
import QuartzCore

// What `VideoClock.swift` declares: that file needs the engine bridge, the reading does not.
nonisolated struct VideoClockReading: Equatable, Sendable {
    var position: Double
    var hostTime: Double
    var advancing: Bool
    var epoch: UInt64
    func position(atHost host: Double) -> Double { advancing ? position + (host - hostTime) : position }
}

private struct Case {
    var name: String
    var seconds: Double
    var transport: (start: Double, end: Double)?
    var groupLoop: VideoLoopRange?
    var from: Double
    /// Timeline seconds after which a turn is known to have happened twice.
    var afterSecondTurn: Double
}

nonisolated(unsafe) private var fps = 0.0
private var fails: [String] = []
private var total = 0

private func check(_ label: String, _ ok: Bool, _ detail: String = "") {
    total += 1
    print((ok ? "ok    " : "FAIL  ") + label + (detail.isEmpty ? "" : "  (\(detail))"))
    if !ok { fails.append(label) }
}

nonisolated(unsafe) private let readContext = CIContext(options: [.cacheIntermediates: false])

/// The frame number of the barcode: 16 bits, 8 px each, in the first 16 rows. Read through CoreImage
/// and not from the buffer's bytes: the output hands out a COMPRESSED format (`&8v0`).
private func barcode(_ pb: CVPixelBuffer) -> Int? {
    let image = CIImage(cvPixelBuffer: pb)
    guard let cg = readContext.createCGImage(image, from: image.extent) else { return nil }
    let w = cg.width, h = cg.height
    var px = [UInt8](repeating: 0, count: w * h * 4)
    guard let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                              space: CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
    ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
    var n = 0
    for bit in 0..<16 where px[(8 * w + bit * 8 + 4) * 4] > 128 { n |= 1 << bit }
    return n
}

private func run(_ c: Case, path: String, duration: Double) {
    let entry = VideoPictureEntry(
        id: UUID(), filePath: path, lane: 0, start: 0, duration: duration, fileDuration: duration, nominalFPS: fps,
        ancestors: [VideoGroupWindow(lane: 0, start: 0, duration: 1000, loop: c.groupLoop)])
    let index = VideoObjectIndex(entries: [entry])
    let engine = VideoPlayerEngine()
    let t0 = CACurrentMediaTime()
    var epoch: UInt64 = 1
    var anchorPos = c.from, anchorHost = t0
    var last: [UInt64] = []
    var lastChange = t0, longestAfterStart = 0.0
    var renewedLate = 0, offCount = 0, compared = 0
    var worst = 0.0
    var lastSource = c.from
    var sinceJump = 0.0
    while true {
        let now = CACurrentMediaTime()
        let elapsed = now - t0
        if elapsed > c.seconds { break }
        let target = now + 0.033
        if let tr = c.transport, anchorPos + (now - anchorHost) >= tr.end {
            anchorPos = tr.start + (anchorPos + (now - anchorHost) - tr.end)
            anchorHost = now
            epoch += 1
        }
        let reading = VideoClockReading(position: anchorPos, hostTime: anchorHost, advancing: true, epoch: epoch)
        var t = reading.position(atHost: target)
        if let tr = c.transport, t >= tr.end { t = tr.start + (t - tr.end) }
        let layers = VideoResolver.layers(at: t, in: index)
        let prepared = engine.prepare(layers: layers, reading: reading, target: target, now: now)
        if let s = layers.first?.sourceTime {
            if abs(s - lastSource) > 0.2 { sinceJump = now }
            lastSource = s
            // Half a second after a jump the player has had its time: the frame must be the right one.
            if now - sinceJump > 0.5, elapsed > 1, let b = prepared.inputs.first?.buffer, let shown = barcode(b) {
                compared += 1
                worst = max(worst, abs(Double(shown) / fps - s))
                if abs(Double(shown) / fps - s) > 0.1 { offCount += 1 }
            }
        }
        if prepared.signature != last {
            last = prepared.signature
            if elapsed > 1 { longestAfterStart = max(longestAfterStart, now - lastChange) }
            lastChange = now
            if elapsed > c.afterSecondTurn { renewedLate += 1 }
        }
        usleep(16_667)
    }
    longestAfterStart = max(longestAfterStart, CACurrentMediaTime() - lastChange)
    engine.flush()
    check("\(c.name): the picture still renews itself after the second turn", renewedLate > 10, "\(renewedLate) new frames")
    check("\(c.name): no hold longer than 300 ms", longestAfterStart < 0.3, String(format: "%.3f s", longestAfterStart))
    check("\(c.name): the frame shown is the right one", compared > 20 && Double(offCount) < 0.05 * Double(compared),
          "\(offCount) off of \(compared), worst \(String(format: "%.3f", worst)) s")
}

@main
struct VideoPlayerLoopTest {
    static func main() async throws {
        guard CommandLine.arguments.count > 1 else {
            print("usage: test_video_player_loop <corpus>/aac_mp4.mp4")
            exit(2)
        }
        let path = CommandLine.arguments[1]
        let asset = AVURLAsset(url: URL(fileURLWithPath: path))
        let duration = try await asset.load(.duration).seconds
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { exit(2) }
        fps = Double(try await track.load(.nominalFrameRate))
        let cases = [
            Case(name: "linear", seconds: 5, transport: nil, groupLoop: nil, from: 1, afterSecondTurn: 2),
            Case(name: "transport loop [2,5)", seconds: 10, transport: (2, 5), groupLoop: nil, from: 2, afterSecondTurn: 6.5),
            Case(name: "transport loop [2,3)", seconds: 6, transport: (2, 3), groupLoop: nil, from: 2, afterSecondTurn: 2.5),
            Case(name: "group loop [1,4)", seconds: 10, transport: nil, groupLoop: .init(start: 1, end: 4), from: 0, afterSecondTurn: 6.5),
            Case(name: "whole file group loop", seconds: duration * 2.5, transport: nil,
                 groupLoop: .init(start: 0, end: duration), from: 0, afterSecondTurn: duration * 2 + 0.5),
        ]
        let thread = Thread {
            for c in cases { run(c, path: path, duration: duration) }
            print(fails.isEmpty ? "ALL PASS (\(total))" : "\(fails.count) FAILED of \(total)")
            exit(fails.isEmpty ? 0 : 1)
        }
        thread.qualityOfService = .userInitiated
        thread.start()
        try await Task.sleep(nanoseconds: 3_600_000_000_000)
    }
}
