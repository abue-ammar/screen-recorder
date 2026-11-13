//
//  FrameRenderer.swift
//  SliceCore
//
//  Created by rit3zh CX on 10/13/26.
//

import CoreImage

/// Draws frames. Called from several render threads at once: its CIContext is thread-safe and its caches are
/// NSCaches, which lock themselves.
public final class FrameRenderer: @unchecked Sendable {
    public let context: CIContext

    public init(context: CIContext = CIContext(options: [.cacheIntermediates: false])) {
        self.context = context
    }

    public struct Options: Sendable {
        public var ignoreZoom = false
        public var hideCamera = false
        public var backgroundImage: CIImage?

        public init(ignoreZoom: Bool = false, hideCamera: Bool = false, backgroundImage: CIImage? = nil) {
            self.ignoreZoom = ignoreZoom
            self.hideCamera = hideCamera
            self.backgroundImage = backgroundImage
        }
    }

    public func render(scene: RenderScene, time t: Double, screen: CIImage?, camera: CIImage?, options: Options = Options()) -> CIImage {
        let out = scene.output
        let extent = CGRect(origin: .zero, size: out)
        let style = scene.project.style
        let screen = screen.map { annotated(redacted($0, blocks: scene.project.redactions(at: t)), scene: scene, time: t) }
        let backdrop = backdrop(scene: scene, time: t, options: options)
        var image = backdrop

        var cameraRect: CGRect?
        var cameraImage: CIImage?
        var split: CameraState?
        if let camera, !options.hideCamera {
            let samples = scene.cameraSamples(at: t, followingZoom: !options.ignoreZoom)
            let state = samples[0]
            if state.screenSlot != ScreenSlot.full { split = state }
            if !state.isHidden {
                var layer = cameraLayer(camera, state: state, style: style, output: out)
                if samples.count > 1, let then = samples.last {
                    layer = smeared(layer, from: flip(state.rect, height: out.height),
                                    to: flip(then.rect, height: out.height), count: samples.count)
                }
                cameraImage = layer
                if state.rect.width * state.rect.height < out.width * out.height * 0.6 { cameraRect = state.rect }
            }
        }

        if let screen {
            let g = scene.geometry(at: t)
            var views = options.ignoreZoom ? [g.fullView] : scene.viewSamples(at: t)
            if let split { views = views.map { splitView($0, slot: split.screenSlot, geometry: g, output: out) } }
            let pointer = scene.pointer(at: t)
            let tilt = options.ignoreZoom ? .flat : scene.tilt(at: t)
            let warp = tilt.isFlat ? nil : tilt.homography(output: out)
            let canvas = warp.flatMap { $0.inverse?.bounds(of: extent) }.map { $0.union(extent) }
                ?? extent.insetBy(dx: -out.width / 2, dy: -out.height / 2)
            let placement = split.flatMap { slotPlacement($0, geometry: g, view: views[0], style: style, output: out) }
            func stack(_ views: [CGRect]) -> CIImage {
                let base = placement == nil ? backdrop : CIImage(color: .clear).cropped(to: extent)
                var layer: CIImage
                if let warp {
                    let flat = screenStack(screen, over: CIImage(color: .clear).cropped(to: canvas), scene: scene, time: t,
                                           geometry: g, views: views, pointer: pointer, canvas: canvas)
                    layer = tilted(flat, by: warp, output: out).composited(over: base)
                } else {
                    layer = screenStack(screen, over: base, scene: scene, time: t, geometry: g, views: views,
                                        pointer: pointer, canvas: extent)
                }
                guard let placement else { return layer }
                layer = layer.transformed(by: placement.transform).applyingFilter("CIBlendWithAlphaMask", parameters: [
                    kCIInputBackgroundImageKey: CIImage.empty(), kCIInputMaskImageKey: placement.mask,
                ])
                return layer.composited(over: placement.shadow).composited(over: backdrop)
            }
            image = stack(views)
            if let cameraImage { image = cameraImage.composited(over: image) }
            if let lens = scene.lens(at: t) {
                let magnified = lensViews(scene: scene, time: t, lens: lens, view: views[0], geometry: g)
                var inside = stack(magnified.views)
                if let cameraImage { inside = cameraImage.composited(over: inside) }
                var screenRect = flip(viewed(g.contentRect, view: views[0], output: out), height: out.height)
                    .intersection(extent)
                var screenRadius = contentRadius(style: style, output: out) * out.width / views[0].width
                var center = magnified.center
                if let placement {
                    screenRect = placement.rect
                    screenRadius = placement.radius
                    center = center.applying(placement.transform)
                }
                image = lensLayer(lens, on: image, magnified: inside, at: center,
                                  from: (screenRect, screenRadius), output: out)
            }
        } else if let cameraImage {
            image = cameraImage.composited(over: image)
        }
        if let layer = keystrokeLayer(scene: scene, time: t, avoiding: cameraRect, output: out) {
            image = layer.composited(over: image)
        }
        return image.cropped(to: extent)
    }

    // MARK: - Caches

    let screenShadows = NSCache<NSString, CIImage>()
    let cursorSprites = NSCache<NSString, CursorSprite>()
    let ringSprite: CIImage? = FrameRenderer.makeRingSprite()
    let lensShadows = NSCache<NSString, CIImage>()
    let keycapCache = NSCache<NSString, CIImage>()
    let annotationMarks = AnnotationMarkCache()
    let backgroundBlurs: NSCache<NSString, CIImage> = {
        let cache = NSCache<NSString, CIImage>()
        cache.countLimit = 4
        return cache
    }()
}
