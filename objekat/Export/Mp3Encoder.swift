import Foundation
import AVFoundation

// MP3 encoder — libmp3lame, called straight from Swift through the bridging header.
//
// WHY VENDORED CODE AND NOT THE OS: macOS cannot encode MP3. CoreAudio does declare the MPG3
// file type for writing, but only to copy already-encoded frames through: the list of ENCODABLE
// formats (kAudioFormatProperty_EncodeFormatIDs) does not hold '.mp3', and
// `afconvert -f MPG3 -d .mp3` fails with 'fmt?'. JUCE has no encoder either (its
// LAMEEncoderAudioFormat drives an external `lame` binary). Hence libmp3lame compiled into the
// app. @see lame-3.100/OBJEKAT-INTEGRATION.md
//
// The caller supplies a FLOATING-point wave rendered by the engine at the final sample rate: the
// encoder does not resample, it only converts. All of it happens off the main thread.

/// A cancellation flag shared between the main actor (which arms it) and the background queue
/// that encodes (which reads it on every packet). A plain Bool would not do: the two sides touch
/// it from different threads.
final class ExportCancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
}

enum Mp3Encoder {

    enum Failure: LocalizedError {
        case unreadableSource(String)
        case initFailed
        case encodeFailed(Int32)
        case writeFailed(String)
        case cancelled

        var errorDescription: String? {
            switch self {
            case .unreadableSource(let s): return L("export.error.unreadableSource", s)
            case .initFailed:              return L("export.error.mp3InitFailed")
            case .encodeFailed(let code):  return L("export.error.mp3EncodeFailed", code)
            case .writeFailed(let s):      return L("export.error.mp3WriteFailed", s)
            case .cancelled:               return L("export.error.cancelled")
            }
        }
    }

    /// How many frames are read (and encoded) per pass. 1152 is the MP3 granule; we handle one
    /// packet at a time so as not to call `progress` back every millisecond.
    private static let framesPerChunk: AVAudioFrameCount = 1152 * 32

    /// Encodes `source` (a PCM wave, mono or stereo) into CBR MP3 at `bitrateKbps` in `destination`.
    /// Blocking: to be called from a background queue. `progress` receives 0…1, and `isCancelled`
    /// is read on every packet.
    static func encode(source: URL,
                       destination: URL,
                       bitrateKbps: Int,
                       progress: (Double) -> Void,
                       isCancelled: () -> Bool) throws {

        let file: AVAudioFile
        do { file = try AVAudioFile(forReading: source) }
        catch { throw Failure.unreadableSource(error.localizedDescription) }

        let format = file.processingFormat          // 32-bit float, non-interleaved
        let channels = Int(format.channelCount)
        let totalFrames = file.length
        guard totalFrames > 0, channels >= 1 else { throw Failure.unreadableSource("empty file") }

        guard let gf = lame_init() else { throw Failure.initFailed }
        defer { lame_close(gf) }

        lame_set_in_samplerate(gf, Int32(format.sampleRate.rounded()))
        lame_set_out_samplerate(gf, Int32(format.sampleRate.rounded()))
        // Always two output channels: a mono mix is encoded as stereo (two identical channels cost
        // next to nothing in joint stereo), which keeps the file true to what the export panel
        // promises.
        lame_set_num_channels(gf, 2)
        lame_set_brate(gf, Int32(bitrateKbps))
        lame_set_VBR(gf, vbr_off)                   // constant bitrate
        lame_set_quality(gf, 2)                     // 2 = 'near-best', the reference setting
        // An Info/Xing frame at the head: exact length and gapless information known to players. It
        // is reserved by lame_init_params and rewritten at the end (@see below).
        lame_set_bWriteVbrTag(gf, 1)
        guard lame_init_params(gf) >= 0 else { throw Failure.initFailed }

        FileManager.default.createFile(atPath: destination.path, contents: nil)
        guard let out = FileHandle(forWritingAtPath: destination.path) else {
            throw Failure.writeFailed(destination.lastPathComponent)
        }
        defer { try? out.close() }

        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: framesPerChunk) else {
            throw Failure.unreadableSource("read buffer allocation")
        }
        // The margin LAME recommends: 1.25 × samples + 7200 bytes.
        var mp3Buffer = [UInt8](repeating: 0, count: Int(Double(framesPerChunk) * 1.25) + 7200)

        var framesDone: AVAudioFramePosition = 0
        while framesDone < totalFrames {
            if isCancelled() { throw Failure.cancelled }
            do { try file.read(into: buffer, frameCount: framesPerChunk) }
            catch { throw Failure.unreadableSource(error.localizedDescription) }
            let n = Int(buffer.frameLength)
            if n == 0 { break }
            guard let channelData = buffer.floatChannelData else {
                throw Failure.unreadableSource("not a floating-point format")
            }
            let left  = channelData[0]
            let right = channels > 1 ? channelData[1] : channelData[0]

            let written = lame_encode_buffer_ieee_float(gf, left, right, Int32(n),
                                                        &mp3Buffer, Int32(mp3Buffer.count))
            guard written >= 0 else { throw Failure.encodeFailed(written) }
            if written > 0 { try append(mp3Buffer, count: Int(written), to: out) }

            framesDone += AVAudioFramePosition(n)
            progress(min(1, Double(framesDone) / Double(totalFrames)))
        }

        let flushed = lame_encode_flush(gf, &mp3Buffer, Int32(mp3Buffer.count))
        if flushed > 0 { try append(mp3Buffer, count: Int(flushed), to: out) }

        // The final Info/Xing frame: LAME reserved its place at the head of the stream on the first
        // packet, and we replace it now that we know the real length. Without this, the frame stays
        // all zeroes and some players show a wrong duration.
        var tag = [UInt8](repeating: 0, count: 16 * 1024)
        let tagSize = lame_get_lametag_frame(gf, &tag, tag.count)
        if tagSize > 0 && tagSize <= tag.count {
            do {
                try out.seek(toOffset: 0)
                try out.write(contentsOf: Data(tag[0..<tagSize]))
            } catch {
                throw Failure.writeFailed(error.localizedDescription)
            }
        }
    }

    private static func append(_ bytes: [UInt8], count: Int, to handle: FileHandle) throws {
        do { try handle.write(contentsOf: Data(bytes[0..<count])) }
        catch { throw Failure.writeFailed(error.localizedDescription) }
    }
}
