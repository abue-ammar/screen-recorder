//
//  CompositionBuilder.swift
//  SliceCore
//
//  Created by rit3zh CX on 10/8/26.
//

import AVFoundation
import CoreImage

public enum CompositionBuilder {
    public struct Result {
        public let composition: AVComposition
        public let videoComposition: AVVideoComposition
        public let audioMix: AVAudioMix?
        public let audioLayout: AudioLayout
        public let packing: PreviewPacking?
    }

    public struct AudioLayout: Equatable, Sendable {
        public var screen: CMPersistentTrackID?
        public var joins: [Double]
        public var clicks: [CMPersistentTrackID] = []
        public var keys: [CMPersistentTrackID] = []

        public static let empty = AudioLayout(screen: nil, joins: [])

        public init(screen: CMPersistentTrackID?, joins: [Double]) {
            self.screen = screen
            self.joins = joins
        }
    }

    public static func audioMix(project: Project, layout: AudioLayout) -> AVAudioMix? {
        var params: [AVAudioMixInputParameters] = []
        if let id = layout.screen {
            params.append(parameters(id, .joins(layout.joins, level: max(project.screenAudioVolume, 0))))
        }
        let clickLevel = project.cursor.clickSound == .none ? 0 : min(max(project.cursor.clickSoundVolume, 0), 1)
        for id in layout.clicks { params.append(parameters(id, .constant(clickLevel))) }
        let keyLevel = project.keystrokes.sound == .none ? 0 : min(max(project.keystrokes.soundVolume, 0), 1)
        for id in layout.keys { params.append(parameters(id, .constant(keyLevel))) }
        guard !params.isEmpty else { return nil }
        let mix = AVMutableAudioMix()
        mix.inputParameters = params
        return mix
    }

    private static func parameters(_ trackID: CMPersistentTrackID, _ envelope: GainEnvelope) -> AVAudioMixInputParameters {
        let p = AVMutableAudioMixInputParameters()
        p.trackID = trackID
        let scale: CMTimeScale = 48000
        p.setVolume(Float(envelope.value(at: 0)), at: .zero)
        let points = envelope.points
        for (a, b) in zip(points, points.dropFirst()) where b.t > 0 && abs(a.gain - b.gain) > 1e-5 {
            let start = CMTime(seconds: max(a.t, 0), preferredTimescale: scale)
            let end = CMTime(seconds: b.t, preferredTimescale: scale)
            guard end > start else { continue }
            p.setVolumeRamp(fromStartVolume: Float(envelope.value(at: max(a.t, 0))), toEndVolume: Float(b.gain),
                            timeRange: CMTimeRange(start: start, end: end))
        }
        return p
    }

    public static func build(project: Project, bundle: ProjectBundle, state: RenderState,
                             renderSize: CGSize, fps: Int, preview: Bool = false) async throws -> Result {
        let comp = AVMutableComposition()
        guard let screenTrack = comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid),
              let screenAudioTrack = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
        else { throw NSError(domain: "Composition", code: 1) }

        // Load each clip's source tracks once. The assets must outlive the inserts (a track doesn't retain its asset).
        var assets: [AVURLAsset] = []
        func track(_ file: String?, _ type: AVMediaType) async throws -> AVAssetTrack? {
            guard let file else { return nil }
            let asset = AVURLAsset(url: bundle.file(file))
            assets.append(asset)
            return try await asset.loadTracks(withMediaType: type).first
        }
        typealias Sources = (screen: AVAssetTrack?, audio: AVAssetTrack?)
        var sources: [Int: Sources] = [:]
        for (i, clip) in project.clips.enumerated() {
            sources[i] = (try await track(clip.screenFile, .video), try await track(clip.screenAudioFile, .audio))
        }

        let scale: CMTimeScale = 600
        var cursor = CMTime.zero
        var joins: [CMTime] = []
        var previous: Segment?
        for seg in project.segments {
            let src = sources[seg.clipIndex]!
            let from = CMTime(seconds: seg.sourceStart, preferredTimescale: scale)
            let len = CMTime(seconds: seg.sourceDuration, preferredTimescale: scale)
            let played = seg.isRetimed ? CMTime(seconds: seg.duration, preferredTimescale: scale) : len
            try await insert(src.screen, from: from, duration: len, into: screenTrack, at: cursor)
            if seg.isRetimed {
                // Retimed stretches play without sound: at 2–8× speech is noise, slowed it drags.
                screenTrack.scaleTimeRange(CMTimeRange(start: cursor, duration: len), toDuration: played)
                screenAudioTrack.insertEmptyTimeRange(CMTimeRange(start: cursor, duration: played))
            } else {
                try await insert(src.audio, from: from, duration: len, into: screenAudioTrack, at: cursor)
            }
            if let p = previous, p.clipIndex != seg.clipIndex || abs(p.sourceEnd - seg.sourceStart) > 0.001
                || p.isRetimed != seg.isRetimed { joins.append(cursor) }
            previous = seg
            cursor = cursor + played
        }

        var layout = AudioLayout(screen: screenAudioTrack.trackID, joins: joins.map(\.seconds))
        // A track with no media at all (no sound in any take) would make the composition invalid.
        if screenAudioTrack.segments.allSatisfy(\.isEmpty) {
            comp.removeTrack(screenAudioTrack)
            layout.screen = nil
        }
        let timeline = state.current().cursor
        layout.clicks = await insertClicks(project.cursor.clickSound, at: timeline.clicks.map(\.t), into: comp, end: cursor)
        layout.keys = await insertKeys(project.keystrokes.sound, hits: timeline.keyHits, into: comp, end: cursor)
        let audioMix = Self.audioMix(project: project, layout: layout)

        var packing: PreviewPacking?
        if preview {
            func size(_ track: AVAssetTrack?) async -> CGSize? {
                guard let track, let s = try? await track.load(.naturalSize) else { return nil }
                return CGSize(width: abs(s.width), height: abs(s.height))
            }
            var screens: [CGSize] = []
            for (i, clip) in project.clips.enumerated() {
                screens.append(await size(sources[i]?.screen) ?? clip.screenPixelSize)
            }
            packing = PreviewPacking(screens: screens)
        }

        withExtendedLifetime(assets) {}
        let total = CMTimeRange(start: .zero, duration: cursor)
        let vc = AVVideoComposition(configuration: .init(
            customVideoCompositorClass: ProjectCompositor.self,
            frameDuration: CMTime(value: 1, timescale: CMTimeScale(fps)),
            instructions: [ProjectInstruction(timeRange: total, screenTrackID: screenTrack.trackID, state: state, packing: packing)],
            renderSize: packing?.canvas ?? renderSize))
        return Result(composition: comp, videoComposition: vc, audioMix: audioMix, audioLayout: layout, packing: packing)
    }

    private static func insertClicks(_ sound: ClickSound, at times: [Double], into comp: AVMutableComposition,
                                     end: CMTime) async -> [CMPersistentTrackID] {
        guard let url = sound.url else { return [] }
        return await insertSounds([url], at: times.map { ($0, 0) }, into: comp, end: end, maxTracks: 4)
    }

    private static func insertKeys(_ sound: KeyboardSound, hits: [KeyHit], into comp: AVMutableComposition,
                                   end: CMTime) async -> [CMPersistentTrackID] {
        let picks = sound.picks(for: hits.map(\.kind))
        guard !picks.isEmpty else { return [] }
        return await insertSounds(sound.files, at: zip(hits, picks).map { ($0.t, $1) }, into: comp, end: end, maxTracks: 6)
    }

    private static func insertSounds(_ urls: [URL], at shots: [(t: Double, sound: Int)], into comp: AVMutableComposition,
                                     end: CMTime, maxTracks: Int) async -> [CMPersistentTrackID] {
        guard !shots.isEmpty else { return [] }
        let assets = urls.map { AVURLAsset(url: $0, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true]) }
        defer { withExtendedLifetime(assets) {} }
        var sources: [(track: AVAssetTrack, range: CMTimeRange)?] = []
        for asset in assets {
            if let track = try? await asset.loadTracks(withMediaType: .audio).first, let range = try? await track.load(.timeRange) {
                sources.append((track, range))
            } else {
                sources.append(nil)
            }
        }
        // Each track's end is kept here: `timeRange` walks every segment, which made hours of typing take minutes.
        var tracks: [(track: AVMutableCompositionTrack, end: CMTime)] = []
        for shot in shots {
            guard sources.indices.contains(shot.sound), let source = sources[shot.sound] else { continue }
            let at = CMTime(seconds: shot.t, preferredTimescale: 48000)
            let len = CMTimeMinimum(source.range.duration, end - at)
            guard at >= .zero, len > .zero else { continue }
            let i: Int
            if let free = tracks.firstIndex(where: { $0.end <= at }) {
                i = free
            } else if tracks.count < maxTracks,
                      let t = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) {
                tracks.append((t, .zero))
                i = tracks.count - 1
            } else { continue }
            let track = tracks[i].track, trackEnd = tracks[i].end
            if at > trackEnd {
                track.insertEmptyTimeRange(CMTimeRange(start: trackEnd, end: at))
                tracks[i].end = at
            }
            if (try? track.insertTimeRange(CMTimeRange(start: source.range.start, duration: len), of: source.track, at: at)) != nil {
                tracks[i].end = at + len
            }
        }
        return tracks.map(\.track.trackID)
    }

    private static func insert(_ source: AVAssetTrack?, from: CMTime, duration: CMTime, into track: AVMutableCompositionTrack,
                               at start: CMTime) async throws {
        var used = CMTime.zero
        if let source {
            let range = try await source.load(.timeRange)
            let begin = range.start + from
            let len = CMTimeMinimum(range.end - begin, duration)
            if len > .zero {
                try track.insertTimeRange(CMTimeRange(start: begin, duration: len), of: source, at: start)
                used = len
            }
        }
        if used < duration {
            track.insertEmptyTimeRange(CMTimeRange(start: start + used, duration: duration - used))
        }
    }
}
