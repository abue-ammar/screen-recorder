//
//  Recorder.swift
//  Slice
//
//  Created by rit3zh CX on 10/12/26.
//

import AppKit
import AVFoundation
import SliceCore
import ScreenCaptureKit
import Synchronization

/// One recording session's capture. Sample handling runs on `queue`, take changes on the main thread; the capture
/// objects it holds (stream, session, writers) aren't Sendable, so the split is kept by hand.
final class Recorder: NSObject, @unchecked Sendable {
    struct Settings {
        var source: CaptureSource
        var cameraID: String?
        var micID: String?
        var fps = Settings.best
        var screenAudio = true
        var keys = true
        /// Typed characters are recorded along with shortcuts, to show what was typed.
        var typing = false
        /// The camera shows on screen while recording (`CameraBubble`).
        var showCamera = true

        static let best = 0
    }

    let settings: Settings
    let bundle: ProjectBundle
    let queue = DispatchQueue(label: "recorder.samples", qos: .userInteractive)
    let hostClock = CMClockGetHostTimeClock()

    var resolved: ResolvedSource?
    var fps = 60
    var pacer: FramePacer?
    /// The newest complete screen frame, kept between takes: a still screen sends no new frames, so a take started
    /// (or resumed) while nothing moves begins with this one, at the moment Record was pressed.
    var latestScreen: CMSampleBuffer?
    var stream: SCStream?
    var session: AVCaptureSession?
    var take: TakeWriter?
    let micLevel = LevelBox()
    let cursor = CursorLogger()
    private(set) var captureSession: AVCaptureSession?
    var onInterrupted: ((String) -> Void)?
    /// Whether each take's mic heard only silence, measured while it recorded.
    var micSilence: [UUID: Bool] = [:]
    var cursorSaver: Task<Void, Never>?
    var savingCursor = false
    /// What's been drawn over the screen, for a capture rect; read on the main thread.
    var annotations: (@MainActor (CGRect) -> [Annotation])?
    let cursorQueue = DispatchQueue(label: "recorder.cursor", qos: .utility)

    init(settings: Settings, bundle: ProjectBundle) {
        self.settings = settings
        self.bundle = bundle
    }

    // MARK: - Lifecycle

    func prepare() async throws {
        try await prepareScreen()
        try prepareCameraAndMic()
    }

    func prepareScreen() async throws {
        let resolved = try await SourceResolver.resolve(settings.source)
        self.resolved = resolved

        fps = Self.frameRate(requested: settings.fps, source: resolved)
        let refresh = max(resolved.maxFrameRate, fps)
        pacer = FramePacer(fps: fps, refreshRate: refresh)

        let config = SCStreamConfiguration()
        config.captureResolution = .best
        config.width = Int(resolved.pixelSize.width)
        config.height = Int(resolved.pixelSize.height)
        if let r = resolved.sourceRect { config.sourceRect = r }
        // Every refresh comes through and each take keeps them at `fps`: the stream's own cap drops frames (`FramePacer`).
        config.minimumFrameInterval = FramePacer.streamInterval(refreshRate: refresh)
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.colorSpaceName = CGColorSpace.sRGB
        config.showsCursor = false
        config.queueDepth = 8
        config.capturesAudio = settings.screenAudio
        config.excludesCurrentProcessAudio = true
        config.sampleRate = 48000
        config.channelCount = 2
        let stream = SCStream(filter: resolved.filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        if settings.screenAudio { try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue) }
        try await stream.startCapture()
        self.stream = stream
    }

    func prepareCameraAndMic() throws {
        if settings.cameraID != nil || settings.micID != nil {
            let session = AVCaptureSession()
            session.beginConfiguration()
            if let id = settings.cameraID, let device = AVCaptureDevice(uniqueID: id) {
                let input = try AVCaptureDeviceInput(device: device)
                if session.canAddInput(input) { session.addInput(input) }
                let out = AVCaptureVideoDataOutput()
                out.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
                out.alwaysDiscardsLateVideoFrames = true
                out.setSampleBufferDelegate(self, queue: queue)
                if session.canAddOutput(out) { session.addOutput(out) }
            }
            if let id = settings.micID, let device = AVCaptureDevice(uniqueID: id) {
                let input = try AVCaptureDeviceInput(device: device)
                if session.canAddInput(input) { session.addInput(input) }
                let out = AVCaptureAudioDataOutput()
                out.setSampleBufferDelegate(self, queue: queue)
                if session.canAddOutput(out) { session.addOutput(out) }
            }
            session.commitConfiguration()
            session.startRunning()
            captureSession = session
        }
    }

    static func frameRate(requested: Int, source: ResolvedSource) -> Int {
        let display = max(source.maxFrameRate, 60)
        let pixels = source.pixelSize.width * source.pixelSize.height
        let best = display >= 120 && pixels <= 3840 * 2400 ? 120 : 60
        return requested == Settings.best ? best : min(requested, best)
    }

    var target: (size: CGSize, rect: CGRect)? { resolved.map { ($0.pixelSize, $0.globalRect) } }

    @MainActor
    func startTake() throws {
        guard let target else { return }
        let id = UUID()
        let (dir, rel) = try bundle.makeClipFolder(id: id)
        let writer = try TakeWriter(id: id, dir: dir, relative: rel, screenSize: target.size,
                                    fps: fps, pacer: pacer, hasCamera: hasCameraOutput, hasMic: hasMicOutput,
                                    hasScreenAudio: settings.screenAudio, pointSize: target.rect.size)
        let now = CMClockGetTime(hostClock)
        queue.sync {
            writer.begin(at: now, with: latestScreen)
            take = writer
        }
        cursor.start(globalRect: target.rect, keys: settings.keys, typing: settings.typing, analysis: writer.analysis)
        keepRecoverable(writer, captureRect: target.rect)
    }

    func endTake() async -> Clip? {
        let stopTime = CMClockGetTime(hostClock)
        let writer: TakeWriter? = queue.sync {
            let w = take
            take = nil
            return w
        }
        var log = await cursor.stop()
        if let rect = target?.rect, let annotations { log.annotations = await MainActor.run { annotations(rect) } }
        guard let writer, let target else { return nil }
        await stopSavingCursor()
        var clip = await writer.finish(at: stopTime, captureRect: target.rect, cursor: log)
        // A file that failed to finish still plays up to its last fragment.
        if clip == nil, writer.startTime != nil { clip = await bundle.recoverTake(writer.planned(captureRect: target.rect)) }
        if let clip, let silent = writer.micSilent { micSilence[clip.id] = silent }
        if clip == nil { bundle.clearRecordingNote(writer.id) }
        return clip
    }

    /// Ends the take without keeping it: nothing is finished or saved, and its folder goes.
    func discardTake() async {
        let writer: TakeWriter? = queue.sync {
            let w = take
            take = nil
            return w
        }
        _ = await cursor.stop()
        // A pointer save under way writes into the folder, so it's waited out before the folder goes.
        await stopSavingCursor()
        guard let writer else { return }
        queue.sync { writer.discard() }
        bundle.clearRecordingNote(writer.id)
    }

    func shutdown() async {
        onInterrupted = nil
        if let stream { try? await stream.stopCapture() }
        stream = nil
        captureSession?.stopRunning()
        captureSession = nil
    }

    var hasCameraOutput: Bool { captureSession?.outputs.contains { $0 is AVCaptureVideoDataOutput } ?? false }
    var hasMicOutput: Bool { captureSession?.outputs.contains { $0 is AVCaptureAudioDataOutput } ?? false }

    func hostTimed(_ sample: CMSampleBuffer) -> CMSampleBuffer? {
        guard let clock = captureSession?.synchronizationClock, !CFEqual(clock, hostClock) else { return sample }
        let pts = CMSyncConvertTime(CMSampleBufferGetPresentationTimeStamp(sample), from: clock, to: hostClock)
        var timing = CMSampleTimingInfo(duration: CMSampleBufferGetDuration(sample), presentationTimeStamp: pts,
                                        decodeTimeStamp: .invalid)
        var out: CMSampleBuffer?
        CMSampleBufferCreateCopyWithNewTiming(allocator: nil, sampleBuffer: sample, sampleTimingEntryCount: 1,
                                              sampleTimingArray: &timing, sampleBufferOut: &out)
        return out
    }
}

extension Recorder: SCStreamDelegate {
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        let reason: String
        switch (error as? SCStreamError)?.code {
        case .userDeclined?: reason = "Screen Recording permission was turned off."
        case .noDisplayList?, .noCaptureSource?: reason = "the display being recorded was disconnected."
        case .userStopped?: reason = "the recording was stopped from the menu bar."
        default: reason = error.localizedDescription
        }
        log.error("Screen capture stopped: \(error, privacy: .public)")
        let message = reason.prefix(1).uppercased() + reason.dropFirst()
        Task { @MainActor [weak self] in self?.onInterrupted?(message) }
    }
}

extension Recorder: SCStreamOutput {
    func stream(_ stream: SCStream, didOutputSampleBuffer sample: CMSampleBuffer, of type: SCStreamOutputType) {
        guard sample.isValid else { return }
        if type == .audio {
            take?.appendScreenAudio(sample)
            return
        }
        guard type == .screen else { return }
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let raw = attachments.first?[.status] as? Int, SCFrameStatus(rawValue: raw) == .complete else { return }
        latestScreen = sample
        take?.appendScreen(sample)
    }
}

extension Recorder: AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput, didOutput sample: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let take, let sample = hostTimed(sample) else { return }
        if output is AVCaptureVideoDataOutput {
            take.appendCamera(sample)
        } else {
            micLevel.store(MicLevel.rms(of: sample))
            take.appendMic(sample)
        }
    }
}

/// The latest audio level, written by the capture queue and read by the UI.
final class LevelBox: Sendable {
    private let value = Mutex<Float>(-160)
    func store(_ v: Float) { value.withLock { $0 = v } }
    func load() -> Float { value.withLock { $0 } }
}
