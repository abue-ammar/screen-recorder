//
//  Layout.swift
//  SliceCore
//
//  Created by rit3zh CX on 10/5/26.
//

import CoreGraphics
import Foundation

public struct ScreenGeometry: Equatable, Sendable {
    public var output: CGSize
    public var contentRect: CGRect
    public var fullBleedSize: CGSize
    public var followsCursor: Bool

    public init(contentSize: CGSize, output: CGSize) {
        self.output = output
        let c = contentSize.width > 0 && contentSize.height > 0 ? contentSize : output
        let scale = min(output.width / c.width, output.height / c.height)
        let size = CGSize(width: c.width * scale, height: c.height * scale)
        contentRect = CGRect(x: (output.width - size.width) / 2, y: (output.height - size.height) / 2,
                             width: size.width, height: size.height)
        let outAspect = output.width / output.height
        let contentAspect = size.width / size.height
        fullBleedSize = contentAspect > outAspect
            ? CGSize(width: size.height * outAspect, height: size.height)
            : CGSize(width: size.width, height: size.width / outAspect)
        followsCursor = max(contentAspect / outAspect, outAspect / contentAspect) > Self.shapeTolerance
    }

    /// Closer than this the shapes differ only by rounding, so the recording isn't cropped.
    static let shapeTolerance: CGFloat = 1.01

    public var fullView: CGRect { CGRect(origin: .zero, size: output) }

    public func zoomedView(scale: Double, focus: CGPoint) -> CGRect {
        let s = max(scale, 1)
        let w = fullBleedSize.width / s, h = fullBleedSize.height / s
        let cx = contentRect.minX + focus.x * contentRect.width
        let cy = contentRect.minY + focus.y * contentRect.height
        let c = contentRect
        return CGRect(x: min(max(cx - w / 2, c.minX), c.maxX - w), y: min(max(cy - h / 2, c.minY), c.maxY - h),
                      width: w, height: h)
    }
}

public struct ViewRect: Interpolatable, Equatable, Sendable {
    public var rect: CGRect

    public init(_ rect: CGRect) { self.rect = rect }

    public static func interpolate(_ a: ViewRect, _ b: ViewRect, _ t: Double) -> ViewRect {
        // Width in log space keeps zoom speed perceptually even. The centre moves in step with the width rather than
        // with time, so the point the two views share (where one is the other scaled) stays put on screen: a zoom
        // pushes straight in to its spot instead of drifting sideways first and catching up at the end. With no
        // change in size it's a plain pan.
        let w = exp(lerp(log(a.rect.width), log(b.rect.width), t))
        let h = w * a.rect.height / a.rect.width
        let dw = b.rect.width - a.rect.width
        let f = abs(dw) > a.rect.width * 1e-4 ? Double((w - a.rect.width) / dw) : t
        let cx = lerp(a.rect.midX, b.rect.midX, f)
        let cy = lerp(a.rect.midY, b.rect.midY, f)
        return ViewRect(CGRect(x: cx - w / 2, y: cy - h / 2, width: w, height: h))
    }
}

func lerp(_ a: CGFloat, _ b: CGFloat, _ t: Double) -> CGFloat { a + (b - a) * CGFloat(t) }
func lerp(_ a: Double, _ b: Double, _ t: Double) -> Double { a + (b - a) * t }
