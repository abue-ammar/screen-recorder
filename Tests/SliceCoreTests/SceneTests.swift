//
//  SceneTests.swift
//  SliceCoreTests
//
//  Created by rit3zh CX on 10/13/26.
//

import CoreGraphics
import Foundation
@testable import SliceCore
import XCTest

final class SceneTests: XCTestCase {
    let out = CGSize(width: 1920, height: 1080)

    func project(duration: Double = 20, content: CGSize = CGSize(width: 3840, height: 2160)) -> Project {
        var p = Project(name: "Test")
        p.clips = [Clip(screenFile: "s.mov", duration: duration, screenPixelSize: content,
                        captureRect: CGRect(x: 0, y: 0, width: 1920, height: 1080))]
        return p
    }

    func testZoomViewStaysInsideContentAndHasOutputAspect() {
        var p = project()
        p.zoomBlocks = [ZoomBlock(start: 2, end: 6, scale: 2.5, focus: CGPoint(x: 0.98, y: 0.02))]
        let scene = RenderScene(project: p, output: out, cursor: CursorTrack(project: p, logs: [:]))
        XCTAssertEqual(scene.view(at: 1), CGRect(origin: .zero, size: out))
        let v = scene.view(at: 4)
        let g = scene.geometry(at: 4)
        XCTAssertTrue(g.contentRect.insetBy(dx: -0.01, dy: -0.01).contains(v))
        XCTAssertEqual(v.width / v.height, 16.0 / 9.0, accuracy: 0.001)
        XCTAssertEqual(v.width, g.fullBleedSize.width / 2.5, accuracy: 0.01)
        XCTAssertEqual(scene.view(at: 8), CGRect(origin: .zero, size: out))
        XCTAssertNotEqual(scene.view(at: 6.5), CGRect(origin: .zero, size: out))
    }

    func testMotionBlurOnlyWhileMoving() {
        var p = project()
        p.zoomBlocks = [ZoomBlock(start: 2, end: 6, scale: 2)]
        let scene = RenderScene(project: p, output: out, cursor: CursorTrack(project: p, logs: [:]))
        XCTAssertEqual(scene.viewSamples(at: 1).count, 1)
        XCTAssertGreaterThan(scene.viewSamples(at: 2.4).count, 2)
        XCTAssertEqual(scene.viewSamples(at: 4).count, 1)
    }

    func testPortraitFollowsCursor() {
        let p = project()
        let log = CursorLog(samples: (0 ... 200).map { i in
            CursorLog.Sample(t: Double(i) * 0.1, x: i < 100 ? 0.1 : 0.9, y: 0.5)
        })
        let track = CursorTrack(project: p, logs: [p.clips[0].id: log])
        let portrait = OutputAspect.portrait9x16.size(shortSide: 1080)
        let scene = RenderScene(project: p, output: portrait, cursor: track)
        XCTAssertTrue(scene.geometry(at: 0).followsCursor)
        let left = scene.view(at: 3).midX, right = scene.view(at: 17).midX
        XCTAssertLessThan(left, right)
        XCTAssertLessThan(abs(scene.view(at: 10.0).midX - scene.view(at: 10.034).midX), 60)
    }

    func testPortraitFitsWholeRecording() {
        var p = project()
        p.style.fitsScreen = true
        let portrait = OutputAspect.portrait9x16.size(shortSide: 1080)
        let scene = RenderScene(project: p, output: portrait, cursor: CursorTrack(project: p, logs: [:]))
        let g = scene.geometry(at: 0)
        XCTAssertTrue(g.isMismatched)
        XCTAssertFalse(g.followsCursor)
        XCTAssertEqual(scene.view(at: 3), g.fullView)
        // Zooms are measured from the whole frame and keep all of the screen in view until they're closer than it.
        let near = g.zoomedView(scale: 1.5, focus: CGPoint(x: 0.1, y: 0.1))
        XCTAssertEqual(near.width, portrait.width / 1.5, accuracy: 0.01)
        XCTAssertLessThanOrEqual(near.minY, g.contentRect.minY)
        XCTAssertGreaterThanOrEqual(near.maxY, g.contentRect.maxY)
        let close = g.zoomedView(scale: 4, focus: CGPoint(x: 0.1, y: 0.1))
        XCTAssertGreaterThanOrEqual(close.minX, g.contentRect.minX - 0.01)
        XCTAssertGreaterThanOrEqual(close.minY, g.contentRect.minY - 0.01)
    }

    func testUltrawideFitsInLandscape() {
        let g = ScreenGeometry(contentSize: CGSize(width: 3440, height: 1440), output: out, style: FrameStyle())
        XCTAssertFalse(g.followsCursor)
    }

    func testProjectRoundTrips() throws {
        var p = project()
        p.zoomBlocks = [ZoomBlock(start: 1, end: 3)]
        let data = try JSONEncoder().encode(p)
        XCTAssertEqual(try JSONDecoder().decode(Project.self, from: data), p)
    }

    func testStyleDecodesWithMissingKeys() throws {
        let style = try JSONDecoder().decode(FrameStyle.self, from: Data(#"{"padding": 0.1}"#.utf8))
        XCTAssertEqual(style.padding, 0.1)
        XCTAssertEqual(style.zoomTransitionDuration, FrameStyle().zoomTransitionDuration)
    }

    // MARK: - Framing

    func testNoPaddingFillsTheFrameExactlyWithAutoAspect() {
        let content = CGSize(width: 3456, height: 2234)
        let output = OutputAspect.auto.size(shortSide: 1080, source: content)
        XCTAssertEqual(output.height, 1080)
        XCTAssertEqual(Int(output.width) % 2, 0)
        XCTAssertEqual(output.width / output.height, content.width / content.height, accuracy: 0.002)
        var style = FrameStyle()
        style.padding = 0
        let g = ScreenGeometry(contentSize: content, output: output, style: style)
        XCTAssertEqual(g.contentRect.minX, 0, accuracy: 1)
        XCTAssertEqual(g.contentRect.minY, 0, accuracy: 1)
        XCTAssertEqual(g.contentRect.width, output.width, accuracy: 1)
        XCTAssertEqual(g.contentRect.height, output.height, accuracy: 1)
        XCTAssertEqual(style.effectiveScreenCornerRadius, 0)
        XCTAssertEqual(style.effectiveShadow, 0)
    }

    func testNoPaddingInAnotherAspectFitsWithoutCropping() {
        var style = FrameStyle()
        style.padding = 0
        let g = ScreenGeometry(contentSize: CGSize(width: 3456, height: 2234), output: out, style: style)
        XCTAssertTrue(CGRect(origin: .zero, size: out).insetBy(dx: -0.5, dy: -0.5).contains(g.contentRect))
        XCTAssertEqual(g.contentRect.height, out.height, accuracy: 0.5)
    }

    func testPaddingChangesMoveTheFrameContinuously() {
        var style = FrameStyle()
        var last: CGRect?
        for i in 0 ... 300 {
            style.padding = 0.15 * Double(i) / 300
            let r = ScreenGeometry(contentSize: CGSize(width: 3456, height: 2234), output: out, style: style).contentRect
            if let last {
                XCTAssertLessThan(abs(r.width - last.width), 8, "padding \(style.padding)")
                XCTAssertLessThan(abs(r.minY - last.minY), 8, "padding \(style.padding)")
            }
            last = r
        }
    }

    func testOldFullScreenProjectsOpenWithNoPadding() throws {
        let style = try JSONDecoder().decode(FrameStyle.self, from: Data(#"{"padding": 0.1, "fullScreen": true}"#.utf8))
        XCTAssertEqual(style.padding, 0)
        let saved = try JSONSerialization.jsonObject(with: JSONEncoder().encode(style)) as! [String: Any]
        XCTAssertNil(saved["fullScreen"])
    }
}
