//
//  QualityRenderTests.swift
//  SliceCoreTests
//
//  Created by rit3zh CX on 10/14/26.
//

import AppKit
import CoreImage
@testable import SliceCore
import XCTest

/// Visual checks written to RENDER_OUT.
final class QualityRenderTests: XCTestCase {
    private func write(_ image: CIImage, size: CGSize, _ name: String, renderer: FrameRenderer) throws {
        let cg = try XCTUnwrap(renderer.context.createCGImage(image, from: CGRect(origin: .zero, size: size)))
        guard let dir = ProcessInfo.processInfo.environment["RENDER_OUT"] else { return }
        try NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])!
            .write(to: URL(fileURLWithPath: dir).appendingPathComponent(name))
    }

    func testZoomedLowResScreenAt4K() throws {
        var p = Project(name: "Q")
        let size = CGSize(width: 1554, height: 744)
        p.clips = [Clip(screenFile: "s", duration: 10, screenPixelSize: size, captureRect: .zero)]
        p.zoomBlocks = [ZoomBlock(start: 0, end: 10, scale: 2, focus: CGPoint(x: 0.35, y: 0.3))]
        let out = OutputAspect.landscape16x9.size(shortSide: 2160)
        let renderer = FrameRenderer()
        let scene = RenderScene(project: p, output: out, cursor: CursorTrack(project: p, logs: [:]))
        try write(renderer.render(scene: scene, time: 5, screen: RenderTests.fakeScreen(size: size)),
                  size: out, "q_zoom4k.png", renderer: renderer)
    }
}
