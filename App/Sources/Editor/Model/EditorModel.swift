//
//  EditorModel.swift
//  Slice
//
//  Created by rit3zh CX on 10/15/26.
//

import AVFoundation
import SliceCore
import SwiftUI
import Synchronization

@MainActor
@Observable
final class PlaybackClock {
    var time: Double = 0
    var isPlaying = false
}

/// Passes on progress from a background job only when it reaches a new whole percent. Progress is published on the
/// editor, so every report redraws the timeline and panels; jobs that report per frame would otherwise do that
/// hundreds of times a second.
final class ProgressThrottle: Sendable {
    private let last = Mutex(-1)

    func shouldReport(_ p: Double) -> Bool {
        let percent = Int((min(max(p, 0), 1) * 100).rounded(.down))
        return last.withLock {
            guard percent != $0 else { return false }
            $0 = percent
            return true
        }
    }
}

@MainActor
@Observable
final class EditorModel {
    enum Selection: Equatable {
        case camera(UUID)
        case zoom(UUID)
        case section(clipID: UUID, start: Double)
        case redact(UUID)
        case annotation(UUID)
    }

    let bundle: ProjectBundle
    var project: Project {
        // Picking what's already picked mustn't add an undo step, save, or rebuild anything.
        didSet { if project != oldValue { projectChanged(from: oldValue) } }
    }

    var selection: Selection? {
        didSet {
            updateRenderOptions()
            if selection != oldValue {
                revealSelectedLens()
                revealSelectedRedaction()
                revealSelectedAnnotation()
            }
        }
    }

    let clock = PlaybackClock()
    var time: Double { clock.time }
    var isPlaying: Bool { clock.isPlaying }
    /// Preview speed, kept for next time.
    var playbackRate: Float = UserDefaults.standard.object(forKey: "playback.rate") as? Float ?? 1 {
        didSet {
            UserDefaults.standard.set(playbackRate, forKey: "playback.rate")
            if isPlaying, player.rate != 0 { player.rate = playbackRate }
        }
    }
    var exportJob: ExportJob?
    @ObservationIgnored var exportTask: Task<Void, Never>?
    /// Why the last clips couldn't be added.
    var importError: String?
    var smartZoomProgress: Double?
    var smartZoomNote: String?
    var noteSymbol = "sparkle.magnifyingglass"
    var privacyScanProgress: Double?
    @ObservationIgnored var privacyScanTask: Task<Void, Never>?
    var quietScanRunning = false
    @ObservationIgnored var smartZoomTask: Task<Void, Never>?
    @ObservationIgnored var buildTask: Task<Void, Never>?
    @ObservationIgnored var buildGeneration = 0
    @ObservationIgnored var smartDetections: [UUID: SmartZoom.Detection] = [:]
    @ObservationIgnored var smartReplan: Task<Void, Never>?
    var silentMicTakes: [Int] = []
    var isEditingText = false
    var canUndo = false
    var canRedo = false
    var aimsOnCanvas = false
    var isCutting = false
    var cutFlash: CutFlash?
    @ObservationIgnored var undoStack: [Project] = []
    @ObservationIgnored var redoStack: [Project] = []
    @ObservationIgnored var isRestoringHistory = false
    @ObservationIgnored var lastChangeAt = Date.distantPast
    @ObservationIgnored var glitchScan: Task<Void, Never>?
    @ObservationIgnored var hoverScan: Task<Void, Never>?
    @ObservationIgnored var speechScan: Task<Void, Never>?
    @ObservationIgnored var audioLayout = CompositionBuilder.AudioLayout.empty
    @ObservationIgnored var soundRebuild: Task<Void, Never>?

    let player = AVPlayer()
    let renderState: RenderState
    @ObservationIgnored var videoOutput = AVPlayerItemVideoOutput(pixelBufferAttributes: EditorModel.outputAttributes)
    @ObservationIgnored var packing: PreviewPacking?
    static let outputAttributes: [String: any Sendable] = [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        kCVPixelBufferIOSurfacePropertiesKey as String: [String: any Sendable](),
        kCVPixelBufferMetalCompatibilityKey as String: true,
    ]
    /// Scrubbing: one seek runs at a time, heading for the latest target, so seeks never queue up behind the mouse.
    @ObservationIgnored var seekTarget: Double?
    @ObservationIgnored var isSeeking = false
    /// Exact seeks under a running player stall the decoder, so a drag pauses playback and resumes it on release.
    @ObservationIgnored var isScrubbing = false
    @ObservationIgnored var resumeAfterScrub = false
    @ObservationIgnored var volumeFade: Task<Void, Never>?
    let previewDriver: PreviewDriver
    @ObservationIgnored var cursorLogs: [UUID: CursorLog] = [:]
    var cursorTrack: CursorTrack
    @ObservationIgnored var resmoothTask: Task<Void, Never>?
    @ObservationIgnored var timeObserver: Any?
    @ObservationIgnored var saveTask: Task<Void, Never>?
    @ObservationIgnored var endObserver: NSObjectProtocol?

    static let minBlock = 0.3

    init(bundle: ProjectBundle, project: Project, openAt: Double = 0) {
        self.bundle = bundle
        let logs = bundle.loadCursorLogs(for: project)
        let opened = Self.withImportedAnnotations(project, logs: logs)
        self.project = opened
        if opened != project { try? bundle.save(opened) }
        let project = opened
        cursorLogs = logs
        let track = CursorTrack(project: project, logs: logs)
        cursorTrack = track
        renderState = RenderState(project: project, cursor: track)
        previewDriver = PreviewDriver(renderState: renderState)
        Task.detached(priority: .utility) { FrameRenderer.warmUp() }
        renderState.update(backgroundImage: bundle.backgroundImage(for: project))
        scanCameraGlitches()
        scanHoverMoments()
        scanSpeech()
        player.automaticallyWaitsToMinimizeStalling = false
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 30), queue: .main) { [weak self] t in
            MainActor.assumeIsolated {
                guard let self, self.player.rate != 0, !self.seekPending else { return }
                self.clock.time = t.seconds
            }
        }
        clock.time = min(max(openAt, 0), duration)
        buildTask = Task { await rebuild() }
    }

    var duration: Double { project.duration }
    var previewSize: CGSize { project.outputSize(shortSide: 720) }
}

struct ExportJob: Equatable {
    let id = UUID()

    enum Phase: Equatable {
        case preparing, rendering, finishing
        case done(bytes: Int64?)
        case failed(String)
    }

    let url: URL
    let size: CGSize
    let fps: Int
    let hevc: Bool
    let bitRate: Int
    let duration: Double
    var phase = Phase.preparing
    var note: String?
    var progress = 0.0
    let started = Date()
    var renderStarted: Date?

    var isRunning: Bool {
        switch phase {
        case .preparing, .rendering, .finishing: true
        case .done, .failed: false
        }
    }

    var remaining: Double? {
        guard phase == .rendering, let renderStarted, progress >= 0.03 else { return nil }
        let elapsed = Date().timeIntervalSince(renderStarted)
        guard elapsed > 1.5 else { return nil }
        return elapsed / progress * (1 - progress)
    }
}
