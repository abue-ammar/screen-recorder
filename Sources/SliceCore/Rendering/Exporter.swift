//
//  Exporter.swift
//  SliceCore
//
//  Created by rit3zh CX on 10/8/26.
//

import AVFoundation

public enum Exporter {
    public enum Failure: LocalizedError, Sendable {
        case failed(String)
        public var errorDescription: String? { if case let .failed(m) = self { m } else { nil } }
    }

    public static let audioBitRate = 256_000

    public static func export(project: Project, bundle: ProjectBundle, cursor: CursorTrack, to url: URL,
                              progress: @escaping @Sendable (Double) -> Void) async throws {
        let settings = project.export
        let size = project.renderSize
        let built = try await CompositionBuilder.build(project: project, bundle: bundle,
                                                       state: RenderState(project: project, cursor: cursor),
                                                       renderSize: size, fps: settings.fps)
        let total = max(project.duration, 0.001)

        let reader = try AVAssetReader(asset: built.composition)
        let videoOut = AVAssetReaderVideoCompositionOutput(
            videoTracks: try await built.composition.loadTracks(withMediaType: .video),
            videoSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any]()])
        videoOut.videoComposition = built.videoComposition
        let videoSamples = reader.outputProvider(for: videoOut)
        let audioTracks = try await built.composition.loadTracks(withMediaType: .audio)
        var audioSamples: AVAssetReaderOutput.Provider<Sample>?
        if !audioTracks.isEmpty {
            let out = AVAssetReaderAudioMixOutput(audioTracks: audioTracks, audioSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48000, AVNumberOfChannelsKey: 2,
                AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: false,
                AVLinearPCMIsBigEndianKey: false,
            ])
            out.audioMix = built.audioMix
            audioSamples = reader.outputProvider(for: out)
        }

        try? FileManager.default.removeItem(at: url)
        let writer = try AVAssetWriter(outputURL: url, fileType: url.pathExtension.lowercased() == "mov" ? .mov : .mp4)
        writer.metadata = [fullFrameRatePlayback]
        var compression: [String: Any] = [
            AVVideoAverageBitRateKey: settings.bitRate(for: size),
            AVVideoExpectedSourceFrameRateKey: settings.fps,
            AVVideoMaxKeyFrameIntervalDurationKey: 2,
        ]
        if !settings.hevc { compression[AVVideoProfileLevelKey] = AVVideoProfileLevelH264HighAutoLevel }
        let videoIn = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: settings.hevc ? AVVideoCodecType.hevc : AVVideoCodecType.h264,
            AVVideoWidthKey: size.width, AVVideoHeightKey: size.height,
            AVVideoCompressionPropertiesKey: compression,
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
            ],
        ])
        let videoReceiver = writer.inputReceiver(for: videoIn)
        let audioReceiver = audioSamples == nil ? nil : writer.inputReceiver(for: AVAssetWriterInput(
            mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48000, AVNumberOfChannelsKey: 2,
                AVEncoderBitRateKey: Self.audioBitRate,
            ]))

        try reader.start()
        try writer.start()
        writer.startSession(atSourceTime: .zero)
        do {
            async let video: Void = pump(videoSamples, into: videoReceiver, progress: { progress(min($0 / total, 0.999)) })
            if let audioSamples, let audioReceiver {
                var limiter = PeakLimiter(sampleRate: 48000)
                try await pump(audioSamples, into: audioReceiver, process: { limiter.limited($0) })
            }
            try await video
        } catch {
            reader.cancelReading()
            writer.cancelWriting()
            throw error
        }
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? Failure.failed("Writing the movie failed.") }
        progress(1)
    }

    /// Marks the movie as meant to play at its own frame rate. Without it QuickTime Player and Photos take a 120 fps
    /// movie for slow motion and stretch most of it to a quarter speed. Only QuickTime movies keep it; MP4 drops it.
    private static var fullFrameRatePlayback: AVMetadataItem {
        let item = AVMutableMetadataItem()
        item.identifier = .quickTimeMetadataFullFrameRatePlaybackIntent
        item.dataType = kCMMetadataBaseDataType_UInt8 as String
        item.value = 1 as NSNumber
        return item
    }

    /// Moves samples from a reader output into a writer input, as fast as the writer takes them.
    private static func pump(_ samples: AVAssetReaderOutput.Provider<Sample>,
                             into receiver: AVAssetWriterInput.SampleBufferReceiver,
                             process: (Sample) -> Sample = { $0 }, progress: (Double) -> Void = { _ in }) async throws {
        while let sample = try await samples.next() {
            try Task.checkCancellation()
            try await receiver.append(process(sample))
            let t = sample.presentationTimeStamp.seconds
            if t.isFinite { progress(t) }
        }
        receiver.finish()
    }
}

private typealias Sample = CMReadySampleBuffer<CMSampleBuffer.DynamicContent>

extension PeakLimiter {
    /// A limited copy of interleaved stereo float samples: the reader's buffers are read-only.
    fileprivate mutating func limited(_ sample: Sample) -> Sample {
        guard case let .dataBuffer(source) = sample.content, !source.isEmpty else { return sample }
        let channels = 2
        var bytes = Data(count: source.count)
        bytes.withUnsafeMutableBytes { raw in
            source.copyBytes(to: raw)
            let floats = raw.bindMemory(to: Float.self)
            process(floats.baseAddress!, frames: floats.count / channels, channels: channels)
        }
        var limited = sample
        limited.content = .dataBuffer(CMReadOnlyDataBlockBuffer(bytes))
        return limited
    }
}
