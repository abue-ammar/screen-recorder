//
//  ExportTests.swift
//  SliceCoreTests
//
//  Created by rit3zh CX on 10/2/26.
//

import AVFoundation
import CoreImage
@testable import SliceCore
import XCTest

final class ExportTests: XCTestCase {
    static func makeMovie(url: URL, image: CIImage, duration: Double, fps: Int = 30) async throws {
        let size = image.extent.size
        let frames = Int(duration * Double(fps))
        try await TestMovie.write(to: url, size: size, frames: frames, fps: fps) { i in
            let x = size.width * CGFloat(i) / CGFloat(frames)
            let bar = CIImage(color: .red).cropped(to: CGRect(x: x, y: 0, width: size.width * 0.02, height: size.height * 0.03))
            return bar.composited(over: image)
        }
    }

    func testTwoClipExport() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("export-test-\(UUID().uuidString)")
        let (bundle, empty) = try ProjectBundle.create(name: "Export", in: dir)
        var project = empty
        let screen = RenderTests.fakeScreen(size: CGSize(width: 1512, height: 982))

        let a = UUID(), b = UUID()
        let (dirA, relA) = try bundle.makeClipFolder(id: a)
        let (dirB, relB) = try bundle.makeClipFolder(id: b)
        try await Self.makeMovie(url: dirA.appendingPathComponent("screen.mov"), image: screen, duration: 3)
        try await Self.makeMovie(url: dirB.appendingPathComponent("screen.mov"), image: screen, duration: 2)
        project.clips = [
            Clip(id: a, screenFile: "\(relA)/screen.mov", duration: 3,
                 screenPixelSize: CGSize(width: 1512, height: 982), captureRect: .zero),
            Clip(id: b, screenFile: "\(relB)/screen.mov", duration: 2,
                 screenPixelSize: CGSize(width: 1512, height: 982), captureRect: .zero),
        ]
        project.zoomBlocks = [ZoomBlock(start: 1, end: 4, scale: 2, focus: CGPoint(x: 0.8, y: 0.15))]
        project.export.aspect = .landscape16x9
        project.export.resolution = .p1080
        project.export.fps = 30
        try bundle.save(project)
        XCTAssertEqual(try bundle.load(), project)

        let out = dir.appendingPathComponent("out.mp4")
        try await Exporter.export(project: project, bundle: bundle, cursor: CursorTrack(project: project, logs: [:]),
                                  to: out, progress: { _ in })
        let asset = AVURLAsset(url: out)
        let duration = try await asset.load(.duration).seconds
        XCTAssertEqual(duration, 5, accuracy: 0.1)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        let track = try XCTUnwrap(tracks.first)
        let size = try await track.load(.naturalSize)
        XCTAssertEqual(size, CGSize(width: 1920, height: 1080))
        let rate = try await track.load(.estimatedDataRate)
        XCTAssertGreaterThan(Double(rate), Double(project.export.bitRate(for: size)) * 0.2)

        project.export.aspect = .auto
        project.export.fps = 60
        project.export.hevc = false
        let auto = dir.appendingPathComponent("auto.mp4")
        try await Exporter.export(project: project, bundle: bundle, cursor: CursorTrack(project: project, logs: [:]),
                                  to: auto, progress: { _ in })
        let autoTracks = try await AVURLAsset(url: auto).loadTracks(withMediaType: .video)
        let autoTrack = try XCTUnwrap(autoTracks.first)
        let autoSize = try await autoTrack.load(.naturalSize)
        XCTAssertEqual(autoSize.height, 1080)
        XCTAssertEqual(autoSize.width / autoSize.height, 1512 / 982, accuracy: 0.01)
        let autoRate = try await autoTrack.load(.nominalFrameRate)
        XCTAssertEqual(Double(autoRate), 60, accuracy: 1)

        if let outDir = ProcessInfo.processInfo.environment["RENDER_OUT"] {
            let gen = AVAssetImageGenerator(asset: asset)
            gen.requestedTimeToleranceBefore = .zero
            gen.requestedTimeToleranceAfter = .zero
            for t in [0.5, 2.5, 4.5] {
                let (cg, _) = try await gen.image(at: CMTime(seconds: t, preferredTimescale: 600))
                let rep = NSBitmapImageRep(cgImage: cg)
                try rep.representation(using: .png, properties: [:])!
                    .write(to: URL(fileURLWithPath: outDir).appendingPathComponent("export_\(t).png"))
            }
        }
        try? FileManager.default.removeItem(at: dir)
    }

    /// QuickTime Player and Photos show an untagged 120 fps movie as slow motion, about three times its length.
    func testHighFrameRateExportIsTaggedForFullSpeed() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("export-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let (bundle, empty) = try ProjectBundle.create(name: "Export", in: dir)
        var project = empty
        let id = UUID()
        let (clipDir, rel) = try bundle.makeClipFolder(id: id)
        try await Self.makeMovie(url: clipDir.appendingPathComponent("screen.mov"),
                                 image: RenderTests.fakeScreen(size: CGSize(width: 640, height: 400)), duration: 1, fps: 120)
        project.clips = [Clip(id: id, screenFile: "\(rel)/screen.mov", duration: 1,
                              screenPixelSize: CGSize(width: 640, height: 400), captureRect: .zero)]
        project.export.resolution = .p1080
        project.export.fps = 120
        XCTAssertEqual(project.export.fileExtension, "mov")

        let out = dir.appendingPathComponent("out").appendingPathExtension(project.export.fileExtension)
        try await Exporter.export(project: project, bundle: bundle, cursor: CursorTrack(project: project, logs: [:]),
                                  to: out, progress: { _ in })
        let asset = AVURLAsset(url: out)
        let intent = AVMetadataItem.metadataItems(from: try await asset.load(.metadata),
                                                  filteredByIdentifier: .quickTimeMetadataFullFrameRatePlaybackIntent).first
        let value = try await intent?.load(.numberValue)
        XCTAssertEqual(value?.intValue, 1)
        let duration = try await asset.load(.duration).seconds
        XCTAssertEqual(duration, 1, accuracy: 0.05)
    }

    /// The loudest sample in each `window` seconds of the asset's first audio track.
    static func peaks(of asset: AVAsset, every window: Double) async throws -> [Float] {
        let track = try await asset.loadTracks(withMediaType: .audio).first!
        let reader = try AVAssetReader(asset: asset)
        let samples = reader.outputProvider(for: AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false, AVSampleRateKey: 48000, AVNumberOfChannelsKey: 2,
        ]))
        try reader.start()
        var peaks: [Float] = []
        var frame = 0
        let per = Int(window * 48000)
        while let sample = try await samples.next() {
            guard case let .dataBuffer(block) = sample.content else { continue }
            var data = [Float](repeating: 0, count: block.count / 4)
            _ = data.withUnsafeMutableBytes { block.copyBytes(to: $0) }
            for i in stride(from: 0, to: data.count, by: 2) {
                let w = frame / per
                if w >= peaks.count { peaks.append(0) }
                peaks[w] = max(peaks[w], abs(data[i]), abs(data[i + 1]))
                frame += 1
            }
        }
        return peaks
    }
}
