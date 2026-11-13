//
//  ProjectCompositor.swift
//  SliceCore
//
//  Created by rit3zh CX on 10/8/26.
//

import AVFoundation
import CoreImage

final class ProjectInstruction: NSObject, AVVideoCompositionInstructionProtocol {
    let timeRange: CMTimeRange
    let enablePostProcessing = false
    let containsTweening = true
    /// Immutable NSNumbers, set once here: safe to read from any thread though NSValue isn't marked Sendable.
    nonisolated(unsafe) let requiredSourceTrackIDs: [NSValue]?
    let passthroughTrackID = kCMPersistentTrackID_Invalid
    let screenTrackID: CMPersistentTrackID
    let state: RenderState
    let packing: PreviewPacking?

    init(timeRange: CMTimeRange, screenTrackID: CMPersistentTrackID, state: RenderState, packing: PreviewPacking?) {
        self.timeRange = timeRange
        self.screenTrackID = screenTrackID
        self.state = state
        self.packing = packing
        requiredSourceTrackIDs = [NSNumber(value: screenTrackID)]
    }
}

/// AVFoundation's custom compositor. Requests are taken on `queue` and drawn on `renderQueue`; the held frames it keeps
/// are only touched on `queue`.
final class ProjectCompositor: NSObject, AVVideoCompositing, @unchecked Sendable {
    static let renderer = FrameRenderer()

    let sourcePixelBufferAttributes: [String: any Sendable]? = [
        kCVPixelBufferPixelFormatTypeKey as String: [kCVPixelFormatType_32BGRA],
        kCVPixelBufferIOSurfacePropertiesKey as String: [String: any Sendable](),
    ]
    let requiredPixelBufferAttributesForRenderContext: [String: any Sendable] = [
        kCVPixelBufferPixelFormatTypeKey as String: [kCVPixelFormatType_32BGRA],
        kCVPixelBufferIOSurfacePropertiesKey as String: [String: any Sendable](),
    ]

    private let queue = DispatchQueue(label: "compositor", qos: .userInitiated)
    private let renderQueue = DispatchQueue(label: "compositor.render", qos: .userInitiated, attributes: .concurrent)
    private let inFlight = DispatchSemaphore(value: 4)
    private var renderContext: AVVideoCompositionRenderContext?
    /// Screen captures only deliver frames when something changes; hold the last one across tiny gaps.
    private var lastScreen: (time: Double, image: CIImage)?

    func renderContextChanged(_ newRenderContext: AVVideoCompositionRenderContext) {
        queue.sync { renderContext = newRenderContext }
    }

    func startRequest(_ request: AVAsynchronousVideoCompositionRequest) {
        queue.async { [self] in
            guard let instruction = request.videoCompositionInstruction as? ProjectInstruction,
                  let out = renderContext?.newPixelBuffer() else {
                request.finish(with: NSError(domain: "Compositor", code: 1))
                return
            }
            let t = request.compositionTime.seconds
            var screen = request.sourceFrame(byTrackID: instruction.screenTrackID).map { CIImage(cvPixelBuffer: $0) }
            if let screen {
                lastScreen = (t, screen)
            } else if let last = lastScreen, abs(t - last.time) < 0.5 {
                screen = last.image
            }
            let size = CGSize(width: CVPixelBufferGetWidth(out), height: CVPixelBufferGetHeight(out))
            if let packing = instruction.packing {
                Self.renderer.context.render(packing.pack(screen: screen), to: out, bounds: CGRect(origin: .zero, size: size),
                                             colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
                request.finish(withComposedVideoFrame: out)
                return
            }
            let (scene, options) = instruction.state.snapshot(size: size)
            // Handed over: from here only the render below writes into the buffer.
            nonisolated(unsafe) let target = out
            inFlight.wait()
            renderQueue.async { [screen, inFlight] in
                defer { inFlight.signal() }
                let image = Self.renderer.render(scene: scene, time: t, screen: screen, options: options)
                Self.renderer.context.render(image, to: target, bounds: CGRect(origin: .zero, size: size),
                                             colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
                request.finish(withComposedVideoFrame: target)
            }
        }
    }

    func cancelAllPendingVideoCompositionRequests() {}
}
