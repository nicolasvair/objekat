import Foundation
import AudioToolbox

// MARK: - Reading a file the way the engine does
//
// `juce::CoreAudioReader` (the reader Tracktion plays every compressed file through) does NOT open
// a file with `ExtAudioFileOpenURL`: it hands CoreAudio a set of read callbacks
// (`AudioFileOpenWithCallbacks`), wraps the result with `ExtAudioFileWrapAudioFileID`, asks for a
// non-interleaved 32-bit float client format and reads with `ExtAudioFileRead`
// (`juce_CoreAudioFormat.cpp:410-640`). The two doors are not equivalent — an AAC read straight off
// a MOV is 44 ms late by the first one's measure — so the check that "an extracted stream is aligned"
// has to go through THIS door, not through a convenient one. This type reproduces it, in Swift, with
// nothing of JUCE: it is what `VideoAudioExtract` verifies a kept stream with, and what
// `tools/test_video_audio_align.swift` asserts the alignment with.
//
// It is a verification instrument, not a player: one file, read sequentially, in memory-light blocks.

nonisolated final class EngineLikeAudioReader {

    private var fd: Int32 = -1
    private var size: Int64 = 0
    private var fileID: AudioFileID?
    private var ext: ExtAudioFileRef?

    /// The file's own format, as `FileDataFormat` reports it.
    private(set) var channels = 0
    private(set) var sampleRate = 0.0
    /// `FileLengthFrames` — what the engine believes the file's length is.
    private(set) var lengthFrames: Int64 = 0

    /// nil if CoreAudio cannot open the file the way the engine would (the stream is then not
    /// keepable: the caller falls back on a WAV).
    init?(url: URL) {
        fd = open(url.path, O_RDONLY)
        guard fd >= 0 else { return nil }
        var st = stat()
        guard fstat(fd, &st) == 0 else { close(fd); return nil }
        size = Int64(st.st_size)

        let me = Unmanaged.passUnretained(self).toOpaque()
        let readProc: AudioFile_ReadProc = { client, position, requestCount, buffer, actualCount in
            let reader = Unmanaged<EngineLikeAudioReader>.fromOpaque(client).takeUnretainedValue()
            let n = pread(reader.fd, buffer, Int(requestCount), off_t(position))
            actualCount.pointee = UInt32(max(0, n))
            return n < 0 ? kAudioFilePermissionsError : noErr
        }
        let sizeProc: AudioFile_GetSizeProc = { client in
            Unmanaged<EngineLikeAudioReader>.fromOpaque(client).takeUnretainedValue().size
        }
        // typeHint 0, like `toAudioFileTypeID(StreamKind::kNone)`; no write, no setSize.
        guard AudioFileOpenWithCallbacks(me, readProc, nil, sizeProc, nil, 0, &fileID) == noErr,
              let fileID,
              ExtAudioFileWrapAudioFileID(fileID, false, &ext) == noErr,
              let ext else { cleanup(); return nil }

        var fmt = AudioStreamBasicDescription()
        var fmtSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        guard ExtAudioFileGetProperty(ext, kExtAudioFileProperty_FileDataFormat, &fmtSize, &fmt) == noErr,
              fmt.mChannelsPerFrame > 0, fmt.mSampleRate > 0 else { cleanup(); return nil }
        channels = Int(fmt.mChannelsPerFrame)
        sampleRate = fmt.mSampleRate

        var length: Int64 = 0
        var lengthSize = UInt32(MemoryLayout<Int64>.size)
        ExtAudioFileGetProperty(ext, kExtAudioFileProperty_FileLengthFrames, &lengthSize, &length)
        lengthFrames = length

        var client = AudioStreamBasicDescription(
            mSampleRate: sampleRate, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kLinearPCMFormatFlagIsFloat | kLinearPCMFormatFlagIsNonInterleaved | kAudioFormatFlagsNativeEndian,
            mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4,
            mChannelsPerFrame: UInt32(channels), mBitsPerChannel: 32, mReserved: 0)
        guard ExtAudioFileSetProperty(ext, kExtAudioFileProperty_ClientDataFormat,
                                      UInt32(MemoryLayout<AudioStreamBasicDescription>.size), &client) == noErr
        else { cleanup(); return nil }
    }

    deinit { cleanup() }

    private func cleanup() {
        if let ext { ExtAudioFileDispose(ext); self.ext = nil }
        if let fileID { AudioFileClose(fileID); self.fileID = nil }
        if fd >= 0 { close(fd); fd = -1 }
    }

    /// Reads up to `maxFrames` frames from the start, every channel kept (planar: `result[c][i]`),
    /// the way `readSamples` pulls them (blocks of 8192). Returns what could be read — fewer than
    /// asked at the end of the file.
    func read(maxFrames: Int) -> [[Float]] {
        guard let ext, channels > 0 else { return [] }
        var out = [[Float]](repeating: [], count: channels)
        for c in 0..<channels { out[c].reserveCapacity(min(maxFrames, 1 << 20)) }
        let block = 8192
        let planes = (0..<channels).map { _ in UnsafeMutablePointer<Float>.allocate(capacity: block) }
        defer { planes.forEach { $0.deallocate() } }
        let listSize = MemoryLayout<AudioBufferList>.size + max(0, channels - 1) * MemoryLayout<AudioBuffer>.size
        let raw = UnsafeMutableRawPointer.allocate(byteCount: listSize, alignment: 16)
        defer { raw.deallocate() }
        let list = raw.bindMemory(to: AudioBufferList.self, capacity: 1)
        var remaining = maxFrames
        while remaining > 0 {
            let want = min(block, remaining)
            list.pointee.mNumberBuffers = UInt32(channels)
            withUnsafeMutablePointer(to: &list.pointee.mBuffers) { first in
                let buffers = UnsafeMutableBufferPointer(start: first, count: channels)
                for c in 0..<channels {
                    buffers[c] = AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(want * 4), mData: planes[c])
                }
            }
            var frames = UInt32(want)
            guard ExtAudioFileRead(ext, &frames, list) == noErr, frames > 0 else { break }
            for c in 0..<channels { out[c].append(contentsOf: UnsafeBufferPointer(start: planes[c], count: Int(frames))) }
            remaining -= Int(frames)
        }
        return out
    }
}
