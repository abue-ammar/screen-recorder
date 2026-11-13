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
        public var backgroundImage: CIImage?

        public init(ignoreZoom: Bool = false, backgroundImage: CIImage? = nil) {
            self.ignoreZoom = ignoreZoom
            self.backgroundImage = backgroundImage
        }
    }

    public func render(scene: RenderScene, time t: Double, screen: CIImage?, options: Options = Options()) -> CIImage {
        let out = scene.output
        let extent = CGRect(origin: .zero, size: out)
        let style = scene.project.style
        let screen = screen.map { annotated(redacted($0, blocks: scene.project.redactions(at: t)), scene: scene, time: t) }
        let backdrop = backdrop(scene: scene, time: t, options: options)
        var image = backdrop

        if let screen {
            let g = scene.geometry(at: t)
            let views = options.ignoreZoom ? [g.fullView] : scene.viewSamples(at: t)
            let pointer = scene.pointer(at: t)
            let tilt = options.ignoreZoom ? .flat : scene.tilt(at: t)
            let warp = tilt.isFlat ? nil : tilt.homography(output: out)
            let canvas = warp.flatMap { $0.inverse?.bounds(of: extent) }.map { $0.union(extent) }
                ?? extent.insetBy(dx: -out.width / 2, dy: -out.height / 2)
            func stack(_ views: [CGRect]) -> CIImage {
                guard let warp else {
                    return screenStack(screen, over: backdrop, scene: scene, time: t, geometry: g, views: views,
                                       pointer: pointer, canvas: extent)
                }
                let flat = screenStack(screen, over: CIImage(color: .clear).cropped(to: canvas), scene: scene, time: t,
                                       geometry: g, views: views, pointer: pointer, canvas: canvas)
                return tilted(flat, by: warp, output: out).composited(over: backdrop)
            }
            image = stack(views)
            if let lens = scene.lens(at: t) {
                let magnified = lensViews(scene: scene, time: t, lens: lens, view: views[0], geometry: g)
                let screenRect = flip(viewed(g.contentRect, view: views[0], output: out), height: out.height)
                    .intersection(extent)
                let screenRadius = contentRadius(style: style, output: out) * out.width / views[0].width
                image = lensLayer(lens, on: image, magnified: stack(magnified.views), at: magnified.center,
                                  from: (screenRect, screenRadius), output: out)
            }
        }
        if let layer = keystrokeLayer(scene: scene, time: t, output: out) {
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
