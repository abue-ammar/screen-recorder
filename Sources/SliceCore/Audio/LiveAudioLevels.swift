//
//  LiveAudioLevels.swift
//  SliceCore
//
//  Created by rit3zh CX on 10/15/26.
//

import Accelerate
import AVFoundation
import Synchronization

/// A take's audio measured as it's written: its peak, to spot a silent mic, and its loudness every 20 ms, to find
/// speech. The same numbers `AudioCheck` and `AudioAnalysis.speech(in:)` get by decoding the file afterwards.
public final class LiveAudioLevels: Sendable {
    private struct State {
        var peak: Float = 0
        var levels: [Double] = []
        var energy = 0.0
        var fill = 0
        var size = 0
        var measured = false
    }

    private let state = Mutex(State())

    static let frameDuration = 0.02

    public init() {}

    public func add(_ sample: CMSampleBuffer) {
        guard let read = Self.read(sample) else { return }
        state.withLock { s in
            s.measured = true
            if s.size == 0 { s.size = max(Int(read.rate * Self.frameDuration), 1) }
            s.peak = max(s.peak, read.peak)
            read.mono.withUnsafeBufferPointer { mono in
                guard let base = mono.baseAddress else { return }
                var i = 0
                while i < mono.count {
                    let n = min(s.size - s.fill, mono.count - i)
                    var sum: Float = 0
                    vDSP_svesq(base + i, 1, &sum, vDSP_Length(n))
                    s.energy += Double(sum)
                    s.fill += n
                    i += n
                    if s.fill == s.size {
                        s.levels.append(10 * log10(max(s.energy / Double(s.size), 1e-12)))
                        s.energy = 0
                        s.fill = 0
                    }
                }
            }
        }
    }

    /// Nil until some audio has been written.
    public var isSilent: Bool? { state.withLock { $0.measured ? $0.peak < 0.001 : nil } }

    public var speech: [TimeSpan] {
        let levels = state.withLock { $0.levels }
        return AudioAnalysis.speech(levels: levels, frameDuration: Self.frameDuration)
    }

    static func read(_ sample: CMSampleBuffer) -> (mono: [Float], peak: Float, rate: Double)? {
        guard let desc = CMSampleBufferGetFormatDescription(sample),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(desc),
              asbd.pointee.mFormatID == kAudioFormatLinearPCM else { return nil }
        let format = AVAudioFormat(cmAudioFormatDescription: desc)
        let frames = Int(CMSampleBufferGetNumSamples(sample))
        let channels = Int(format.channelCount)
        guard frames > 0, channels > 0, let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))
        else { return nil }
        buf.frameLength = AVAudioFrameCount(frames)
        guard CMSampleBufferCopyPCMDataIntoAudioBufferList(sample, at: 0, frameCount: Int32(frames),
                                                           into: buf.mutableAudioBufferList) == noErr else { return nil }
        let interleaved = format.isInterleaved
        let value: (Int, Int) -> Float
        if let f = buf.floatChannelData {
            value = { c, i in interleaved ? f[0][i * channels + c] : f[c][i] }
        } else if let s = buf.int16ChannelData {
            value = { c, i in Float(interleaved ? s[0][i * channels + c] : s[c][i]) / 32768 }
        } else if let s = buf.int32ChannelData {
            value = { c, i in Float(interleaved ? s[0][i * channels + c] : s[c][i]) / 2_147_483_648 }
        } else {
            return nil
        }
        var mono = [Float](repeating: 0, count: frames)
        var peak: Float = 0
        let scale = 1 / Float(channels)
        for i in 0 ..< frames {
            var sum: Float = 0
            for c in 0 ..< channels {
                let v = value(c, i)
                sum += v
                peak = max(peak, abs(v))
            }
            mono[i] = channels == 1 ? sum : sum * scale
        }
        return (mono, peak, format.sampleRate)
    }
}
