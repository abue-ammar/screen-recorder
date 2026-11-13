//
//  TakeWriter.swift
//  Slice
//
//  Created by rit3zh CX on 10/12/26.
//

import AppKit
import AVFoundation
import SliceCore

final class TakeWriter {
    let id: UUID
    let relative: String
    let screenSize: CGSize
    private let screen: AVAssetWriter
    private let screenInput: AVAssetWriterInput
    private let screenAudio: AudioTrackWriter?
    private let fps: Int
    private var pacer: FramePacer?
    private(set) var startTime: CMTime?
    private var lastScreen: CMSampleBuffer?
    private var heldScreen: CMSampleBuffer?
    private var refusedFrames = 0
    let analysis: LiveTakeAnalyzer
    private let screenAudioLevels = LiveAudioLevels()

    init(id: UUID, dir: URL, relative: String, screenSize: CGSize, fps: Int, pacer: FramePacer?, hasScreenAudio: Bool,
         pointSize: CGSize) throws {
        self.id = id
        self.relative = relative
        self.screenSize = screenSize
        self.fps = fps
        self.pacer = pacer
        screen = try AVAssetWriter(outputURL: dir.appendingPathComponent("screen.mov"), fileType: .mov)
        screen.movieFragmentInterval = ProjectBundle.fragmentInterval
        let compression: [String: Any] = [
            AVVideoQualityKey: 0.9,
            AVVideoExpectedSourceFrameRateKey: fps,
            AVVideoAllowFrameReorderingKey: false,
            AVVideoMaxKeyFrameIntervalDurationKey: 1,
        ]
        screenInput = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: screenSize.width, AVVideoHeightKey: screenSize.height,
            AVVideoCompressionPropertiesKey: compression,
        ])
        screenInput.expectsMediaDataInRealTime = true
        screen.add(screenInput)
        screenAudio = hasScreenAudio ? try AudioTrackWriter(url: dir.appendingPathComponent("screen-audio.m4a")) : nil
        analysis = LiveTakeAnalyzer(folder: dir, pointSize: pointSize)
        screenAudio?.onWrite = { [screenAudioLevels] in screenAudioLevels.add($0) }
    }

    func begin(at time: CMTime, with frame: CMSampleBuffer?) {
        guard let frame, let copy = Self.retimed(frame, to: time) else { return }
        guard screen.startWriting() else { return }
        screen.startSession(atSourceTime: time)
        startTime = time
        analysis.start(at: time.seconds)
        if screenInput.isReadyForMoreMediaData, screenInput.append(copy), let buffer = CMSampleBufferGetImageBuffer(copy) {
            analysis.screenFrame(buffer, at: time.seconds)
        }
        lastScreen = copy
    }

    func appendScreen(_ sample: CMSampleBuffer) {
        let pts = CMSampleBufferGetPresentationTimeStamp(sample)
        if let start = startTime {
            guard pts > start else { return }
        } else {
            guard screen.startWriting() else { return }
            screen.startSession(atSourceTime: pts)
            startTime = pts
            analysis.start(at: pts.seconds)
        }
        lastScreen = sample
        switch pacer?.offer(pts.seconds) ?? .keep {
        case .hold:
            heldScreen = sample
            return
        case .keepHeldAndThis:
            if let heldScreen { writeScreen(heldScreen) }
        case .keep:
            break
        }
        heldScreen = nil
        writeScreen(sample)
    }

    private func writeScreen(_ sample: CMSampleBuffer) {
        if screenInput.isReadyForMoreMediaData, screenInput.append(sample) {
            if let buffer = CMSampleBufferGetImageBuffer(sample) {
                analysis.screenFrame(buffer, at: CMSampleBufferGetPresentationTimeStamp(sample).seconds)
            }
            return
        }
        refusedFrames += 1
    }

    private static func retimed(_ sample: CMSampleBuffer, to time: CMTime) -> CMSampleBuffer? {
        guard let buffer = CMSampleBufferGetImageBuffer(sample) else { return nil }
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: time, decodeTimeStamp: .invalid)
        var fmt: CMVideoFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: buffer, formatDescriptionOut: &fmt)
        guard let fmt else { return nil }
        var copy: CMSampleBuffer?
        CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: buffer, formatDescription: fmt,
                                                 sampleTiming: &timing, sampleBufferOut: &copy)
        return copy
    }

    func appendScreenAudio(_ sample: CMSampleBuffer) {
        guard let start = startTime else { return }
        screenAudio?.append(sample, start: start)
    }

    var cursorURL: URL { screen.outputURL.deletingLastPathComponent().appendingPathComponent("cursor.json") }

    /// The clip this take becomes if every file is written: what a take cut off is put back as.
    func planned(captureRect: CGRect) -> Clip {
        Clip(id: id, screenFile: "\(relative)/screen.mov", cursorFile: "\(relative)/cursor.json", duration: 0,
             screenPixelSize: screenSize, captureRect: captureRect, cursorInVideo: false)
            .withScreenAudio(screenAudio == nil ? nil : "\(relative)/screen-audio.m4a")
            .withFrameRate(fps)
    }

    /// Stops every file without finishing it and removes the take's folder.
    func discard() {
        screen.cancelWriting()
        screenAudio?.cancel()
        try? FileManager.default.removeItem(at: screen.outputURL.deletingLastPathComponent())
    }

    func finish(at stop: CMTime, captureRect: CGRect, cursor: CursorLogger.Result) async -> Clip? {
        guard let start = startTime, stop > start else {
            screen.cancelWriting()
            screenAudio?.cancel()
            return nil
        }
        if let heldScreen { writeScreen(heldScreen) }
        if refusedFrames > 0 { log.warning("The encoder fell behind: \(self.refusedFrames) screen frames dropped") }
        // The screen only sends frames on change; repeat the last one at the end so the track spans the take.
        if let last = lastScreen, let buffer = CMSampleBufferGetImageBuffer(last) {
            let endPTS = CMTimeSubtract(stop, CMTime(value: 1, timescale: CMTimeScale(fps)))
            if endPTS > CMSampleBufferGetPresentationTimeStamp(last) {
                var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: endPTS, decodeTimeStamp: .invalid)
                var fmt: CMVideoFormatDescription?
                CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: buffer, formatDescriptionOut: &fmt)
                var copy: CMSampleBuffer?
                if let fmt {
                    CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: buffer, formatDescription: fmt,
                                                             sampleTiming: &timing, sampleBufferOut: &copy)
                }
                if let copy, screenInput.isReadyForMoreMediaData { screenInput.append(copy) }
            }
        }
        let screenAudioDone = await screenAudio?.finish(at: stop) ?? false
        if screen.status == .writing {
            screenInput.markAsFinished()
            screen.endSession(atSourceTime: stop)
            await screen.finishWriting()
        } else {
            screen.cancelWriting()
        }
        try? JSONEncoder().encode(cursor.log(since: start.seconds)).write(to: cursorURL)
        guard screen.status == .completed else { return nil }

        var clip = planned(captureRect: captureRect)
        clip.duration = (stop - start).seconds
        if !screenAudioDone { clip.screenAudioFile = nil }
        // Measured while recording, so the editor needn't scan the files again.
        let live = await analysis.finish(duration: (stop - start).seconds)
        if clip.hasEditableCursor { clip.hoverMoments = live.hoverMoments }
        if screenAudioDone { clip.speech = screenAudioLevels.speech }
        return clip
    }
}
