//
//  StyleModel.swift
//  SliceCore
//
//  Created by rit3zh CX on 10/15/26.
//

import CoreGraphics
import Foundation

public struct RGBA: Codable, Equatable, Hashable, Sendable {
    public var r, g, b, a: Double
    public init(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) {
        self.r = r; self.g = g; self.b = b; self.a = a
    }
}

public struct FrameStyle: Codable, Equatable, Sendable {
    public var backgroundTop = RGBA(0.36, 0.30, 0.85)
    public var backgroundBottom = RGBA(0.92, 0.45, 0.62)
    public var backgroundImage: String?
    /// How much a background image is blurred, 0…1. Gradients are smooth already, so it only applies to images.
    public var backgroundBlur = 0.0
    public var padding = 0.06
    public var screenCornerRadius = 0.018
    public var shadow = 0.5
    public var motionBlur = true
    public var motionBlurAmount = 0.4
    public var zoomTransitionDuration = 1.0
    public var screenBorder = 0.0
    /// A recording whose shape is far from the frame's (a wide window in 9:16) is shown whole, with background around
    /// it, instead of cropped to fill the frame and following the pointer. Zooms then start from the whole recording.
    public var fitsScreen = false

    public init() {}

    public var effectivePadding: Double { max(padding, 0) }
    public var framing: Double {
        let f = min(max(padding / Self.framingPadding, 0), 1)
        return f * f * (3 - 2 * f)
    }

    static let framingPadding = 0.04
    public var effectiveScreenCornerRadius: Double { screenCornerRadius * framing }
    public var effectiveShadow: Double { shadow * framing }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = FrameStyle()
        backgroundTop = try c.decodeIfPresent(RGBA.self, forKey: .backgroundTop) ?? d.backgroundTop
        backgroundBottom = try c.decodeIfPresent(RGBA.self, forKey: .backgroundBottom) ?? d.backgroundBottom
        backgroundImage = try c.decodeIfPresent(String.self, forKey: .backgroundImage)
        backgroundBlur = try c.decodeIfPresent(Double.self, forKey: .backgroundBlur) ?? d.backgroundBlur
        padding = try c.decodeIfPresent(Double.self, forKey: .padding) ?? d.padding
        if try c.decodeIfPresent(Bool.self, forKey: .legacyFullScreen) == true { padding = 0 }
        screenCornerRadius = try c.decodeIfPresent(Double.self, forKey: .screenCornerRadius) ?? d.screenCornerRadius
        shadow = try c.decodeIfPresent(Double.self, forKey: .shadow) ?? d.shadow
        motionBlur = try c.decodeIfPresent(Bool.self, forKey: .motionBlur) ?? d.motionBlur
        motionBlurAmount = try c.decodeIfPresent(Double.self, forKey: .motionBlurAmount) ?? d.motionBlurAmount
        zoomTransitionDuration = try c.decodeIfPresent(Double.self, forKey: .zoomTransitionDuration) ?? d.zoomTransitionDuration
        screenBorder = try c.decodeIfPresent(Double.self, forKey: .screenBorder) ?? d.screenBorder
        fitsScreen = try c.decodeIfPresent(Bool.self, forKey: .fitsScreen) ?? d.fitsScreen
    }

    private enum CodingKeys: String, CodingKey {
        case backgroundTop, backgroundBottom, backgroundImage, backgroundBlur, padding, screenCornerRadius, shadow, motionBlur,
             motionBlurAmount, zoomTransitionDuration, screenBorder, fitsScreen
        case legacyFullScreen = "fullScreen"
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(backgroundTop, forKey: .backgroundTop)
        try c.encode(backgroundBottom, forKey: .backgroundBottom)
        try c.encodeIfPresent(backgroundImage, forKey: .backgroundImage)
        try c.encode(backgroundBlur, forKey: .backgroundBlur)
        try c.encode(padding, forKey: .padding)
        try c.encode(screenCornerRadius, forKey: .screenCornerRadius)
        try c.encode(shadow, forKey: .shadow)
        try c.encode(motionBlur, forKey: .motionBlur)
        try c.encode(motionBlurAmount, forKey: .motionBlurAmount)
        try c.encode(zoomTransitionDuration, forKey: .zoomTransitionDuration)
        try c.encode(screenBorder, forKey: .screenBorder)
        try c.encode(fitsScreen, forKey: .fitsScreen)
    }
}

public enum OutputAspect: String, Codable, CaseIterable, Sendable {
    case auto
    case landscape16x9 = "16:9"
    case portrait9x16 = "9:16"
    case square1x1 = "1:1"

    public func size(shortSide: Int, source: CGSize? = nil) -> CGSize {
        let ratio: Double
        switch self {
        case .auto:
            if let source, source.width > 0, source.height > 0 { ratio = Double(source.width / source.height) } else { ratio = 16.0 / 9 }
        case .landscape16x9: ratio = 16.0 / 9
        case .portrait9x16: ratio = 9.0 / 16
        case .square1x1: ratio = 1
        }
        func even(_ v: Double) -> CGFloat { CGFloat(max(Int((v / 2).rounded()) * 2, 2)) }
        let s = Double(shortSide)
        return ratio >= 1 ? CGSize(width: even(s * ratio), height: even(s)) : CGSize(width: even(s), height: even(s / ratio))
    }
}

public enum OutputResolution: Int, Codable, CaseIterable, Sendable {
    case p1080 = 1080, p1440 = 1440, p2160 = 2160

    public var label: String {
        switch self {
        case .p1080: "1080p"
        case .p1440: "1440p"
        case .p2160: "4K"
        }
    }
}

public enum ExportQuality: String, Codable, CaseIterable, Sendable {
    case standard, high, maximum

    public var label: String {
        switch self {
        case .standard: "Standard"
        case .high: "High"
        case .maximum: "Maximum"
        }
    }

    var bitsPerPixel: Double {
        switch self {
        case .standard: 0.05
        case .high: 0.09
        case .maximum: 0.16
        }
    }
}

public struct ExportSettings: Codable, Equatable, Sendable {
    public var aspect: OutputAspect = .auto
    public var resolution: OutputResolution = .p2160
    public var fps = 60
    public var hevc = true
    public var quality: ExportQuality = .high

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = ExportSettings()
        aspect = try c.decodeIfPresent(OutputAspect.self, forKey: .aspect) ?? d.aspect
        resolution = try c.decodeIfPresent(OutputResolution.self, forKey: .resolution) ?? d.resolution
        fps = try c.decodeIfPresent(Int.self, forKey: .fps) ?? d.fps
        hevc = try c.decodeIfPresent(Bool.self, forKey: .hevc) ?? d.hevc
        quality = (try? c.decodeIfPresent(ExportQuality.self, forKey: .quality)) ?? d.quality
    }

    public func bitRate(for size: CGSize) -> Int {
        let bpp = quality.bitsPerPixel * (hevc ? 1 : 1.5)
        return Int(Double(size.width * size.height) * Double(fps) * bpp)
    }
}

extension Project {
    public var sourceSize: CGSize? { clips.first?.screenPixelSize }

    public var renderSize: CGSize { outputSize(shortSide: export.resolution.rawValue) }

    public func outputSize(shortSide: Int) -> CGSize { export.aspect.size(shortSide: shortSide, source: sourceSize) }
}
