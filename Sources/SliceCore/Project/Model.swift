//
//  Model.swift
//  SliceCore
//
//  Created by rit3zh CX on 10/15/26.
//

import CoreGraphics
import Foundation

public struct Project: Codable, Equatable, Sendable {
    public var version = 1
    public var name: String
    public var createdAt: Date
    public var clips: [Clip]
    public var cameraBlocks: [CameraBlock]
    public var zoomBlocks: [ZoomBlock]
    public var defaultCamera: CameraLayout
    public var style: FrameStyle
    public var export: ExportSettings
    public var cuts: [Cut]
    public var splits: [Split]
    public var micVolume: Double
    public var screenAudioVolume: Double
    public var cursor: CursorSettings
    public var keystrokes: KeystrokeSettings
    public var autoZoom: AutoZoomSettings
    public var speeds: [SpeedRange]
    public var redactions: [RedactBlock]
    public var annotations: [AnnotationBlock]

    public init(name: String, createdAt: Date = Date()) {
        self.name = name
        self.createdAt = createdAt
        clips = []
        cameraBlocks = []
        zoomBlocks = []
        defaultCamera = .corner(.bottomRight, .square, .small)
        style = FrameStyle()
        export = ExportSettings()
        cuts = []
        splits = []
        micVolume = 1
        screenAudioVolume = 1
        cursor = CursorSettings()
        keystrokes = KeystrokeSettings()
        autoZoom = AutoZoomSettings()
        speeds = []
        redactions = []
        annotations = []
    }

    /// Missing keys fall back to defaults, so older projects still open.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Project(name: "")
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        name = try c.decode(String.self, forKey: .name)
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        clips = try c.decodeIfPresent([Clip].self, forKey: .clips) ?? []
        cameraBlocks = try c.decodeIfPresent([CameraBlock].self, forKey: .cameraBlocks) ?? []
        zoomBlocks = try c.decodeIfPresent([ZoomBlock].self, forKey: .zoomBlocks) ?? []
        defaultCamera = try c.decodeIfPresent(CameraLayout.self, forKey: .defaultCamera) ?? d.defaultCamera
        style = try c.decodeIfPresent(FrameStyle.self, forKey: .style) ?? d.style
        export = try c.decodeIfPresent(ExportSettings.self, forKey: .export) ?? d.export
        cuts = try c.decodeIfPresent([Cut].self, forKey: .cuts) ?? []
        splits = try c.decodeIfPresent([Split].self, forKey: .splits) ?? []
        micVolume = try c.decodeIfPresent(Double.self, forKey: .micVolume) ?? 1
        screenAudioVolume = try c.decodeIfPresent(Double.self, forKey: .screenAudioVolume) ?? 1
        cursor = try c.decodeIfPresent(CursorSettings.self, forKey: .cursor) ?? d.cursor
        keystrokes = try c.decodeIfPresent(KeystrokeSettings.self, forKey: .keystrokes) ?? d.keystrokes
        autoZoom = try c.decodeIfPresent(AutoZoomSettings.self, forKey: .autoZoom) ?? d.autoZoom
        speeds = try c.decodeIfPresent([SpeedRange].self, forKey: .speeds) ?? []
        redactions = try c.decodeIfPresent([RedactBlock].self, forKey: .redactions) ?? []
        annotations = try c.decodeIfPresent([AnnotationBlock].self, forKey: .annotations) ?? []
    }

    public var hasCamera: Bool { clips.contains { $0.cameraFile != nil } }
}

public struct Clip: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var screenFile: String
    public var cameraFile: String?
    /// Where a camera recorded later over the take stops, when it was stopped before the take ends.
    public var cameraEnd: Double?
    public var micFile: String?
    public var screenAudioFile: String?
    public var cursorFile: String?
    public var cameraGlitches: [TimeSpan]?
    public var hoverMoments: [Double]?
    public var speech: [TimeSpan]?
    public var duration: Double
    public var screenPixelSize: CGSize
    public var captureRect: CGRect
    public var cursorInVideo: Bool
    public var frameRate: Int?
    /// Its log's annotations have been put on the timeline, so deleting them all doesn't bring them back.
    public var annotationsImported: Bool?

    public init(id: UUID = UUID(), screenFile: String, cameraFile: String? = nil, micFile: String? = nil,
                cursorFile: String? = nil, duration: Double, screenPixelSize: CGSize, captureRect: CGRect,
                cursorInVideo: Bool = true) {
        self.id = id
        self.screenFile = screenFile
        self.cameraFile = cameraFile
        self.micFile = micFile
        self.cursorFile = cursorFile
        self.duration = duration
        self.screenPixelSize = screenPixelSize
        self.captureRect = captureRect
        self.cursorInVideo = cursorInVideo
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        screenFile = try c.decode(String.self, forKey: .screenFile)
        cameraFile = try c.decodeIfPresent(String.self, forKey: .cameraFile)
        cameraEnd = try c.decodeIfPresent(Double.self, forKey: .cameraEnd)
        micFile = try c.decodeIfPresent(String.self, forKey: .micFile)
        screenAudioFile = try c.decodeIfPresent(String.self, forKey: .screenAudioFile)
        cursorFile = try c.decodeIfPresent(String.self, forKey: .cursorFile)
        cameraGlitches = try c.decodeIfPresent([TimeSpan].self, forKey: .cameraGlitches)
        hoverMoments = try c.decodeIfPresent([Double].self, forKey: .hoverMoments)
        speech = try c.decodeIfPresent([TimeSpan].self, forKey: .speech)
        duration = try c.decode(Double.self, forKey: .duration)
        screenPixelSize = try c.decode(CGSize.self, forKey: .screenPixelSize)
        captureRect = try c.decode(CGRect.self, forKey: .captureRect)
        cursorInVideo = try c.decodeIfPresent(Bool.self, forKey: .cursorInVideo) ?? true
        frameRate = try c.decodeIfPresent(Int.self, forKey: .frameRate)
        annotationsImported = try c.decodeIfPresent(Bool.self, forKey: .annotationsImported)
    }

    /// Whether the camera filmed this moment of the take. Past the end of a camera file AVFoundation keeps handing
    /// back its last frame, so this decides.
    public func hasCamera(at local: Double) -> Bool { cameraFile != nil && local < (cameraEnd ?? .infinity) }

    public var hasEditableCursor: Bool { cursorFile != nil && !cursorInVideo && captureRect.width > 0 && captureRect.height > 0 }
}
