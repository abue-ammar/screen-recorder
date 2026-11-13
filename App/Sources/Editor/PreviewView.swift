//
//  PreviewView.swift
//  Slice
//
//  Created by rit3zh CX on 10/8/26.
//

import AVFoundation
import CoreImage
import Metal
import QuartzCore
import SliceCore
import SwiftUI
import Synchronization

struct PreviewSurface: NSViewRepresentable {
    let driver: PreviewDriver
    var quality: Double = 1

    func makeNSView(context: Context) -> PreviewNSView { PreviewNSView(driver: driver) }

    func updateNSView(_ view: PreviewNSView, context: Context) { view.quality = quality }
}

enum PreviewQuality: Double, CaseIterable {
    case full = 1, balanced = 0.75, fast = 0.5

    var label: String {
        switch self {
        case .full: "Full (Retina)"
        case .balanced: "Balanced"
        case .fast: "Fast"
        }
    }
}

struct PreviewSourceFrame {
    let time: Double
    let screen: CIImage?
}

/// Hands the player's frames to the render thread. Everything it holds is behind `lock`; AVPlayerItemVideoOutput,
/// which isn't Sendable, is safe to read from there.
final class PreviewDriver: @unchecked Sendable {
    let renderState: RenderState
    private let lock = NSLock()
    private var output: AVPlayerItemVideoOutput?
    private var packing: PreviewPacking?
    private var playing = false
    private var pausedTime = 0.0
    private var duration = 0.0
    private var version = 0
    /// Just after playback starts: the player's clock runs before its first new frame is decoded, so the pointer and
    /// zooms would set off ahead of a frozen picture. The preview stays on the paused moment until that frame arrives.
    private var holding = false
    /// A seek during playback: the output still hands out frames from before the jump, so they're skipped until it lands.
    private var seeking = false
    private var shown = 0.0

    var shownTime: Double { lock.withLock { shown } }

    var isPlaying: Bool { lock.withLock { playing } }

    init(renderState: RenderState) { self.renderState = renderState }

    func setSource(_ output: AVPlayerItemVideoOutput, packing: PreviewPacking?) {
        lock.withLock {
            self.output = output
            self.packing = packing
            version &+= 1
        }
    }

    func setPlayback(playing: Bool, seeking: Bool = false, time: Double, duration: Double) {
        lock.withLock {
            if playing, !self.playing || seeking || self.seeking { holding = true }
            self.seeking = playing && seeking
            if !playing { holding = false }
            self.playing = playing
            pausedTime = time
            self.duration = duration
            version &+= 1
        }
    }

    func invalidate() { lock.withLock { version &+= 1 } }

    func moment(atHostTime hostTime: CFTimeInterval) -> (time: Double, version: Int, frame: PreviewSourceFrame?) {
        let (output, packing, playing, paused, duration, version, holding, seeking) = lock.withLock {
            (self.output, self.packing, self.playing, pausedTime, self.duration, self.version, self.holding, self.seeking)
        }
        var time = paused
        var frame: PreviewSourceFrame?
        if let output, !seeking {
            let item = output.itemTime(forHostTime: hostTime)
            if item.isValid, let packing, output.hasNewPixelBuffer(forItemTime: item),
               case let (buffer?, shown) = output.pixelBufferAndDisplayTime(forItemTime: item) {
                let at = shown.isValid ? shown.seconds : item.seconds
                let clip = renderState.current().project.clipStarts.lastIndex { $0 <= at + 1e-6 } ?? 0
                let screen = buffer.withUnsafeBuffer { CIImage(cvPixelBuffer: $0) }
                frame = PreviewSourceFrame(time: at, screen: packing.unpack(screen, clip: clip))
            }
            if playing, item.isValid, item.seconds.isFinite, !holding || frame != nil {
                time = min(max(item.seconds, 0), duration)
            }
        }
        lock.withLock {
            if frame != nil, self.playing { self.holding = false }
            self.shown = time
        }
        return (time, version, frame)
    }
}

final class PreviewNSView: NSView {
    var quality = 1.0 {
        didSet { if quality != oldValue { updateDrawableSize() } }
    }

    let driver: PreviewDriver
    private let metalLayer = CAMetalLayer()
    private let frames: PreviewFrames
    private var link: CAMetalDisplayLink?

    /// The editor's preview in the main window, whose last frame becomes the project card's picture on close.
    static weak var current: PreviewNSView?

    init(driver: PreviewDriver) {
        self.driver = driver
        let device = MTLCreateSystemDefaultDevice()
        frames = PreviewFrames(driver: driver, device: device)
        super.init(frame: .zero)
        metalLayer.device = device
        metalLayer.pixelFormat = .bgra8Unorm
        metalLayer.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
        metalLayer.framebufferOnly = false
        metalLayer.maximumDrawableCount = 3
        metalLayer.isOpaque = true
        metalLayer.backgroundColor = NSColor.black.cgColor
        layer = metalLayer
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    isolated deinit { link?.invalidate() }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // Invalidating the link removes the render thread's only run loop source, which ends the thread.
        link?.invalidate()
        link = nil
        guard window != nil else {
            if Self.current === self { Self.current = nil }
            return
        }
        Self.current = self
        updateDrawableSize()
        let l = CAMetalDisplayLink(metalLayer: metalLayer)
        l.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 120, preferred: 120)
        l.preferredFrameLatency = 1
        l.delegate = frames
        link = l
        // Handed to the render thread, which only adds it to its run loop; the link then calls `frames` there.
        nonisolated(unsafe) let handoff = l
        let thread = Thread {
            handoff.add(to: .current, forMode: .default)
            while !Thread.current.isCancelled, RunLoop.current.run(mode: .default, before: .distantFuture) {}
        }
        thread.name = "Preview render"
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateDrawableSize()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateDrawableSize()
    }

    /// The last frame shown, at most `width` pixels wide.
    func snapshot(width: CGFloat = 1600) -> CGImage? { frames.snapshot(width: width) }

    private func updateDrawableSize() {
        let scale = window?.backingScaleFactor ?? 2
        metalLayer.contentsScale = scale
        let pixels = scale * CGFloat(min(max(quality, 0.25), 1))
        var w = bounds.width * pixels, h = bounds.height * pixels
        let cap = 3840 / max(w, h, 1)
        if cap < 1 { w *= cap; h *= cap }
        let size = CGSize(width: max(w.rounded(), 2), height: max(h.rounded(), 2))
        if metalLayer.drawableSize != size { metalLayer.drawableSize = size }
    }
}

/// Draws the preview on the display link's own thread, so playback never waits on the main thread. Its frame state is
/// only touched there; the last frame drawn is shared behind a lock for snapshots.
private final class PreviewFrames: NSObject, CAMetalDisplayLinkDelegate, @unchecked Sendable {
    private let driver: PreviewDriver
    private let commandQueue: MTLCommandQueue?
    private let context: CIContext
    private let renderer: FrameRenderer
    private let shot = Mutex<(image: CIImage, size: CGSize)?>(nil)

    private var lastDrawn: DrawKey?
    private var source: PreviewSourceFrame?
    private var sourceCount = 0

    private struct DrawKey: Equatable {
        var time: Double
        var version: Int
        var frames: Int
        var size: CGSize
    }

    init(driver: PreviewDriver, device: MTLDevice?) {
        self.driver = driver
        let queue = device?.makeCommandQueue()
        commandQueue = queue
        // Cached intermediates let the parts that don't change between frames be reused, which takes a frame from
        // ~10 ms to ~2 ms of GPU time at Retina size.
        context = queue.map { CIContext(mtlCommandQueue: $0, options: [.cacheIntermediates: true]) } ?? CIContext()
        renderer = FrameRenderer(context: context)
    }

    func snapshot(width: CGFloat) -> CGImage? {
        guard let (image, size) = shot.withLock({ $0 }), size.width > 0 else { return nil }
        let k = min(1, width / size.width)
        let out = CGRect(x: 0, y: 0, width: (size.width * k).rounded(), height: (size.height * k).rounded())
        return context.createCGImage(image.cropped(to: CGRect(origin: .zero, size: size))
            .transformed(by: CGAffineTransform(scaleX: k, y: k)), from: out,
                                     format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
    }

    func metalDisplayLink(_ link: CAMetalDisplayLink, needsUpdate update: CAMetalDisplayLink.Update) {
        let host = update.targetPresentationTimestamp
        let moment = driver.moment(atHostTime: host)
        if let frame = moment.frame {
            source = frame
            sourceCount &+= 1
        }
        let drawable = update.drawable
        let size = CGSize(width: drawable.texture.width, height: drawable.texture.height)
        let key = DrawKey(time: moment.time, version: moment.version, frames: sourceCount, size: size)
        guard key != lastDrawn else { return }
        let (scene, options) = driver.renderState.snapshot(size: size)
        guard source != nil || scene.project.clips.isEmpty else { return }
        lastDrawn = key
        autoreleasepool {
            let image = renderer.render(scene: scene, time: moment.time, screen: source?.screen, options: options)
            guard let commands = commandQueue?.makeCommandBuffer() else { return }
            let destination = CIRenderDestination(mtlTexture: drawable.texture, commandBuffer: commands)
            // Metal textures are top-down; Core Image is bottom-up.
            destination.isFlipped = true
            destination.colorSpace = CGColorSpace(name: CGColorSpace.sRGB)
            _ = try? context.startTask(toRender: image, to: destination)
            commands.present(drawable)
            commands.commit()
            shot.withLock { $0 = (image, size) }
        }
    }
}
