//
//  RenderTests.swift
//  SliceCoreTests
//
//  Created by rit3zh CX on 10/10/26.
//

import AppKit
import CoreImage
@testable import SliceCore
import XCTest

/// Renders sample frames. Set RENDER_OUT to a directory to also write PNGs for eyeballing.
final class RenderTests: XCTestCase {
    static func fakeScreen(size: CGSize) -> CIImage {
        let img = NSImage(size: size, flipped: true) { rect in
            NSColor(white: 0.97, alpha: 1).setFill()
            rect.fill()
            NSColor(calibratedRed: 0.15, green: 0.17, blue: 0.22, alpha: 1).setFill()
            NSRect(x: 0, y: 0, width: size.width, height: size.height * 0.05).fill()
            NSColor(calibratedRed: 0.9, green: 0.92, blue: 0.95, alpha: 1).setFill()
            NSRect(x: 0, y: size.height * 0.05, width: size.width * 0.18, height: size.height).fill()
            let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: size.height * 0.025),
                                                        .foregroundColor: NSColor.black]
            for i in 0 ..< 18 {
                let y = size.height * (0.1 + Double(i) * 0.048)
                ("Row \(i + 1) - the quick brown fox jumps over the lazy dog" as NSString)
                    .draw(at: NSPoint(x: size.width * 0.22, y: y), withAttributes: attrs)
            }
            NSColor.systemBlue.setFill()
            NSBezierPath(roundedRect: NSRect(x: size.width * 0.78, y: size.height * 0.1, width: size.width * 0.16,
                                             height: size.height * 0.07), xRadius: 12, yRadius: 12).fill()
            return true
        }
        let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil)!
        return CIImage(cgImage: cg)
    }

    func testRenderSampleFrames() throws {
        var p = Project(name: "Render")
        p.clips = [Clip(screenFile: "s.mov", duration: 30, screenPixelSize: CGSize(width: 3024, height: 1964),
                        captureRect: .zero)]
        p.zoomBlocks = [ZoomBlock(start: 4, end: 9, scale: 2.2, focus: CGPoint(x: 0.86, y: 0.13))]
        let screen = Self.fakeScreen(size: CGSize(width: 3024, height: 1964))
        let renderer = FrameRenderer()
        let outDir = ProcessInfo.processInfo.environment["RENDER_OUT"].map { URL(fileURLWithPath: $0) }

        let frames: [(String, OutputAspect, Double)] = [
            ("a_idle", .landscape16x9, 1), ("b_zooming", .landscape16x9, 4.25), ("c_zoomed", .landscape16x9, 6),
            ("d_portrait", .portrait9x16, 1), ("e_square", .square1x1, 6),
        ]
        for (name, aspect, t) in frames {
            let out = aspect.size(shortSide: 1080)
            let scene = RenderScene(project: p, output: out, cursor: CursorTrack(project: p, logs: [:]))
            let image = renderer.render(scene: scene, time: t, screen: screen)
            let start = Date()
            let cg = try XCTUnwrap(renderer.context.createCGImage(image, from: CGRect(origin: .zero, size: out)))
            print("render \(name): \(Int(Date().timeIntervalSince(start) * 1000))ms")
            XCTAssertEqual(cg.width, Int(out.width))
            if let outDir {
                let rep = NSBitmapImageRep(cgImage: cg)
                try rep.representation(using: .png, properties: [:])!.write(to: outDir.appendingPathComponent("\(name).png"))
            }
        }
    }

    func testOtherShapeFillsTheFrame() {
        var p = Project(name: "Fill")
        p.clips = [Clip(screenFile: "s.mov", duration: 10, screenPixelSize: CGSize(width: 3024, height: 1964), captureRect: .zero)]
        let out = OutputAspect.landscape16x9.size(shortSide: 1080)
        let scene = RenderScene(project: p, output: out, cursor: CursorTrack(project: p, logs: [:]))
        let screen = CIImage(color: .white).cropped(to: CGRect(x: 0, y: 0, width: 3024, height: 1964))
        let image = FrameRenderer().render(scene: scene, time: 1, screen: screen)
        for point in [CGPoint(x: 2, y: 2), CGPoint(x: out.width - 3, y: out.height / 2)] {
            var px = [UInt8](repeating: 0, count: 4)
            CIContext().render(image, toBitmap: &px, rowBytes: 4, bounds: CGRect(origin: point, size: CGSize(width: 1, height: 1)),
                               format: .RGBA8, colorSpace: nil)
            XCTAssertGreaterThan(Int(px[0]), 235, "The screen reaches \(point)")
        }
    }

    func testBlackBehindTheScreen() {
        let size = CGSize(width: 1600, height: 900)
        var p = Project(name: "P")
        p.clips = [Clip(screenFile: "a", duration: 5, screenPixelSize: size, captureRect: .zero)]
        p.export.aspect = .auto
        let scene = RenderScene(project: p, output: size, cursor: CursorTrack(project: p, logs: [:]))
        var screen = CIImage(color: .white).cropped(to: CGRect(origin: .zero, size: size))
        for corner in [CGPoint(x: 0, y: 0), CGPoint(x: size.width - 40, y: 0), CGPoint(x: 0, y: size.height - 40),
                       CGPoint(x: size.width - 40, y: size.height - 40)] {
            screen = screen.applyingFilter("CISourceOutCompositing", parameters: [
                kCIInputBackgroundImageKey: CIImage(color: .white).cropped(to: CGRect(origin: corner, size: CGSize(width: 40, height: 40))),
            ])
        }
        let image = FrameRenderer().render(scene: scene, time: 1, screen: screen)
        var px = [UInt8](repeating: 0, count: 4)
        CIContext().render(image, toBitmap: &px, rowBytes: 4, bounds: CGRect(x: 5, y: 5, width: 1, height: 1), format: .RGBA8, colorSpace: nil)
        XCTAssertLessThan(px[0 ..< 3].map(Int.init).max()!, 20)
    }
}
