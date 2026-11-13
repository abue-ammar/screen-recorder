//
//  Exporter.swift
//  SliceCore
//
//  Created by rit3zh CX on 10/8/26.
//

import AVFoundation
import CoreImage

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
        let built = try await build(project: project, bundle: bundle, cursor: cursor, size: size, fps: settings.fps)
        let total = max(project.duration, 0.001)

        let reader = try AVAssetReader(asset: built.composition)
        let videoOut = AVAssetReaderVideoCompositionOutput(
            videoTracks: try await built.composition.loadTracks(withMediaType: .video),
            videoSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any]()])
        videoOut.videoComposition = built.videoComposition
        videoOut.alwaysCopiesSampleData = false
        reader.add(videoOut)
        let audioTracks = try await built.composition.loadTracks(withMediaType: .audio)
        var audioOut: AVAssetReaderAudioMixOutput?
        if !audioTracks.isEmpty {
            let out = AVAssetReaderAudioMixOutput(audioTracks: audioTracks, audioSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48000, AVNumberOfChannelsKey: 2,
                AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: false,
                AVLinearPCMIsBigEndianKey: false,
            ])
            out.audioMix = built.audioMix
            // The limiter works on the samples in place, so they must be the output's own copy.
            out.alwaysCopiesSampleData = true
            reader.add(out)
            audioOut = out
        }

        try? FileManager.default.removeItem(at: url)
        let writer = try AVAssetWriter(outputURL: url, fileType: url.pathExtension.lowercased() == "mov" ? .mov : .mp4)
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
        videoIn.expectsMediaDataInRealTime = false
        writer.add(videoIn)
        var audioIn: AVAssetWriterInput?
        if audioOut != nil {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48000, AVNumberOfChannelsKey: 2,
                AVEncoderBitRateKey: Self.audioBitRate,
            ])
            input.expectsMediaDataInRealTime = false
            writer.add(input)
            audioIn = input
        }

        guard reader.startReading() else { throw reader.error ?? Failure.failed("Couldn't read the project's media.") }
        guard writer.startWriting() else { throw writer.error ?? Failure.failed("Couldn't write the movie file.") }
        writer.startSession(atSourceTime: .zero)

        let cancel = ReaderBox(reader: reader)
        let video = SamplePump(output: videoOut, input: videoIn, label: "export.video")
        var limiter = PeakLimiter(sampleRate: 48000)
        let audio = audioOut.flatMap { out in
            audioIn.map { SamplePump(output: out, input: $0, label: "export.audio") { limiter.limit($0) } }
        }
        await withTaskCancellationHandler {
            async let videoDone: Void = video.run { t in progress(min(t / total, 0.999)) }
            await audio?.run { _ in }
            await videoDone
        } onCancel: {
            cancel.reader.cancelReading()
        }
        if Task.isCancelled || reader.status == .cancelled {
            writer.cancelWriting()
            throw CancellationError()
        }
        if reader.status == .failed {
            writer.cancelWriting()
            throw reader.error ?? Failure.failed("Reading the project failed.")
        }
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? Failure.failed("Writing the movie failed.") }
        progress(1)
    }

    static func build(project: Project, bundle: ProjectBundle, cursor: CursorTrack, size: CGSize,
                      fps: Int) async throws -> CompositionBuilder.Result {
        let state = RenderState(project: project, cursor: cursor)
        state.update(backgroundImage: bundle.backgroundImage(for: project))
        return try await CompositionBuilder.build(project: project, bundle: bundle, state: state, renderSize: size, fps: fps)
    }

    /// Lets the cancellation handler stop the reader; `cancelReading` may be called from any thread.
    struct ReaderBox: @unchecked Sendable {
        let reader: AVAssetReader
    }

}

/// Moves samples from a reader output into a writer input, as fast as the writer takes them. Everything it holds is
/// touched only on its own serial queue once `run` starts, which is what makes handing it to another task safe.
private final class SamplePump: @unchecked Sendable {
    private let output: AVAssetReaderOutput
    private let input: AVAssetWriterInput
    private let process: ((CMSampleBuffer) -> Void)?
    private let queue: DispatchQueue
    private var finished = false

    init(output: AVAssetReaderOutput, input: AVAssetWriterInput, label: String, process: ((CMSampleBuffer) -> Void)? = nil) {
        self.output = output
        self.input = input
        self.process = process
        queue = DispatchQueue(label: label)
    }

    func run(progress: @escaping @Sendable (Double) -> Void) async {
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            input.requestMediaDataWhenReady(on: queue) { [self] in
                guard !finished else { return }
                while input.isReadyForMoreMediaData {
                    guard let sample = output.copyNextSampleBuffer() else {
                        input.markAsFinished()
                        finish(done)
                        return
                    }
                    let t = CMSampleBufferGetPresentationTimeStamp(sample).seconds
                    process?(sample)
                    guard input.append(sample) else {
                        finish(done)
                        return
                    }
                    if t.isFinite { progress(t) }
                }
            }
        }
    }

    private func finish(_ done: CheckedContinuation<Void, Never>) {
        finished = true
        done.resume()
    }
}

extension PeakLimiter {
    mutating func limit(_ sample: CMSampleBuffer) {
        guard let block = CMSampleBufferGetDataBuffer(sample) else { return }
        var contiguous = 0, total = 0
        var data: UnsafeMutablePointer<CChar>?
        guard CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: &contiguous, totalLengthOut: &total,
                                          dataPointerOut: &data) == kCMBlockBufferNoErr,
              let data, contiguous == total else { return }
        let channels = 2
        data.withMemoryRebound(to: Float.self, capacity: total / 4) {
            process($0, frames: total / 4 / channels, channels: channels)
        }
    }
}
