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
    public var zoomBlocks: [ZoomBlock]
    public var style: FrameStyle
    public var export: ExportSettings
    public var cuts: [Cut]
    public var splits: [Split]
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
        zoomBlocks = []
        style = FrameStyle()
        export = ExportSettings()
        cuts = []
        splits = []
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
        zoomBlocks = try c.decodeIfPresent([ZoomBlock].self, forKey: .zoomBlocks) ?? []
        style = try c.decodeIfPresent(FrameStyle.self, forKey: .style) ?? d.style
        export = try c.decodeIfPresent(ExportSettings.self, forKey: .export) ?? d.export
        cuts = try c.decodeIfPresent([Cut].self, forKey: .cuts) ?? []
        splits = try c.decodeIfPresent([Split].self, forKey: .splits) ?? []
        screenAudioVolume = try c.decodeIfPresent(Double.self, forKey: .screenAudioVolume) ?? 1
        cursor = try c.decodeIfPresent(CursorSettings.self, forKey: .cursor) ?? d.cursor
        keystrokes = try c.decodeIfPresent(KeystrokeSettings.self, forKey: .keystrokes) ?? d.keystrokes
        autoZoom = try c.decodeIfPresent(AutoZoomSettings.self, forKey: .autoZoom) ?? d.autoZoom
        speeds = try c.decodeIfPresent([SpeedRange].self, forKey: .speeds) ?? []
        redactions = try c.decodeIfPresent([RedactBlock].self, forKey: .redactions) ?? []
        annotations = try c.decodeIfPresent([AnnotationBlock].self, forKey: .annotations) ?? []
    }
}

public struct Clip: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var screenFile: String
    public var screenAudioFile: String?
    public var cursorFile: String?
    public var hoverMoments: [Double]?
    public var speech: [TimeSpan]?
    public var duration: Double
    public var screenPixelSize: CGSize
    public var captureRect: CGRect
    public var cursorInVideo: Bool
    public var frameRate: Int?
    /// Its log's annotations have been put on the timeline, so deleting them all doesn't bring them back.
    public var annotationsImported: Bool?

    public init(id: UUID = UUID(), screenFile: String, cursorFile: String? = nil, duration: Double, screenPixelSize: CGSize,
                captureRect: CGRect, cursorInVideo: Bool = true) {
        self.id = id
        self.screenFile = screenFile
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
        screenAudioFile = try c.decodeIfPresent(String.self, forKey: .screenAudioFile)
        cursorFile = try c.decodeIfPresent(String.self, forKey: .cursorFile)
        hoverMoments = try c.decodeIfPresent([Double].self, forKey: .hoverMoments)
        speech = try c.decodeIfPresent([TimeSpan].self, forKey: .speech)
        duration = try c.decode(Double.self, forKey: .duration)
        screenPixelSize = try c.decode(CGSize.self, forKey: .screenPixelSize)
        captureRect = try c.decode(CGRect.self, forKey: .captureRect)
        cursorInVideo = try c.decodeIfPresent(Bool.self, forKey: .cursorInVideo) ?? true
        frameRate = try c.decodeIfPresent(Int.self, forKey: .frameRate)
        annotationsImported = try c.decodeIfPresent(Bool.self, forKey: .annotationsImported)
    }

    public var hasEditableCursor: Bool { cursorFile != nil && !cursorInVideo && captureRect.width > 0 && captureRect.height > 0 }
}

public struct TimeSpan: Codable, Equatable, Sendable {
    public var start: Double
    public var end: Double

    public init(start: Double, end: Double) {
        self.start = start
        self.end = end
    }
}
