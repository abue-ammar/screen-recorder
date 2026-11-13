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

    public init(contentSize: CGSize, output: CGSize, style: FrameStyle) {
        self.output = output
        let base = min(output.width, output.height)
        let inset = base * style.effectivePadding
        let avail = CGSize(width: max(output.width - 2 * inset, 1), height: max(output.height - 2 * inset, 1))
        let c = contentSize.width > 0 && contentSize.height > 0 ? contentSize : output
        let scale = min(avail.width / c.width, avail.height / c.height)
        let size = CGSize(width: c.width * scale, height: c.height * scale)
        contentRect = CGRect(x: (output.width - size.width) / 2, y: (output.height - size.height) / 2,
                             width: size.width, height: size.height)
        let outAspect = output.width / output.height
        let contentAspect = size.width / size.height
        fullBleedSize = contentAspect > outAspect
            ? CGSize(width: size.height * outAspect, height: size.height)
            : CGSize(width: size.width, height: size.width / outAspect)
        let mismatch = max(contentAspect / outAspect, outAspect / contentAspect)
        isMismatched = mismatch > Self.mismatchLimit
        followsCursor = isMismatched
        // A screen fitted whole sits on the canvas uncropped, so zooms are measured from all of it.
        if isMismatched && style.fitsScreen {
            fullBleedSize = output
            followsCursor = false
        }
    }

    /// Past this, the recording is cropped to fill the frame unless it's fitted whole.
    public static let mismatchLimit: CGFloat = 1.4
    /// The recording's shape is far enough from the frame's that it's either cropped to fill or fitted whole.
    public private(set) var isMismatched = false

    public var fullView: CGRect { CGRect(origin: .zero, size: output) }

    public func zoomedView(scale: Double, focus: CGPoint) -> CGRect {
        let s = max(scale, 1)
        let w = fullBleedSize.width / s, h = fullBleedSize.height / s
        let cx = contentRect.minX + focus.x * contentRect.width
        let cy = contentRect.minY + focus.y * contentRect.height
        let c = contentRect
        return CGRect(x: Self.place(cx - w / 2, length: w, content: c.minX ... c.maxX, frame: output.width),
                      y: Self.place(cy - h / 2, length: h, content: c.minY ... c.maxY, frame: output.height),
                      width: w, height: h)
    }

    /// Keeps a view inside the content along one axis; one longer than the content (a fitted screen zoomed in only a
    /// little) keeps all of the content in view instead, without leaving the frame.
    static func place(_ origin: CGFloat, length: CGFloat, content: ClosedRange<CGFloat>, frame: CGFloat) -> CGFloat {
        let lo = content.lowerBound, hi = content.upperBound
        if length <= hi - lo + 0.001 { return min(max(origin, lo), hi - length) }
        return min(max(min(max(origin, hi - length), lo), 0), frame - length)
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
