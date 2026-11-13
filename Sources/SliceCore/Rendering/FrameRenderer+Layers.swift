//
//  FrameRenderer+Layers.swift
//  SliceCore
//
//  Created by rit3zh CX on 10/13/26.
//

import CoreImage
import CoreImage.CIFilterBuiltins

extension FrameRenderer {
    func screenStack(_ screen: CIImage, over backdrop: CIImage, scene: RenderScene, time t: Double, geometry g: ScreenGeometry,
                             views: [CGRect], pointer: CursorPointer?, canvas: CGRect) -> CIImage {
        let out = scene.output
        let layer = views.count > 1 ? blurredScreenLayer(screen, geometry: g, views: views, output: out, canvas: canvas) : nil
        var image = (layer ?? average(views.map {
            screenLayer(screen, geometry: g, view: $0, output: out, sharp: views.count == 1)
        })).composited(over: backdrop)
        let cursor = scene.project.cursor
        let press = cursor.clickPress ? cursor.pressScale(ages: scene.clicks(at: t, lasting: cursor.clickPressDuration).map(\.age)) : 1
        if let pointer, let layer = cursorLayer(pointer, geometry: g, view: views[0], settings: cursor, press: CGFloat(press),
                                                output: out, canvas: canvas) {
            image = layer.composited(over: image)
        }
        return clickEffects(on: image, scene: scene, time: t, geometry: g, view: views[0], output: out, canvas: canvas)
    }

    func magnifiedView(_ view: CGRect, lens: LensState, geometry g: ScreenGeometry) -> (view: CGRect, center: CGPoint) {
        let c = g.contentRect
        let p = CGPoint(x: c.minX + lens.center.x * c.width, y: c.minY + lens.center.y * c.height)
        let m = CGFloat(max(lens.magnification, 1))
        let zoomed = CGRect(x: p.x - (p.x - view.minX) / m, y: p.y - (p.y - view.minY) / m,
                            width: view.width / m, height: view.height / m)
        let k = g.output.width / view.width
        return (zoomed, CGPoint(x: (p.x - view.minX) * k, y: g.output.height - (p.y - view.minY) * k))
    }

    func lensViews(scene: RenderScene, time t: Double, lens: LensState, view: CGRect,
                   geometry g: ScreenGeometry) -> (views: [CGRect], center: CGPoint) {
        let now = magnifiedView(view, lens: lens, geometry: g)
        let shutter = scene.project.style.motionBlurAmount / 60
        guard scene.project.style.motionBlur, shutter > 0 else { return ([now.view], now.center) }
        func sample(_ dt: Double) -> CGRect {
            var earlier = scene.lens(at: t - dt) ?? lens
            if scene.lens(at: t - dt) == nil { earlier.magnification = 1 }
            return magnifiedView(view, lens: earlier, geometry: g).view
        }
        let before = sample(shutter)
        let k = g.output.width / now.view.width
        let spread = [abs(now.view.minX - before.minX), abs(now.view.maxX - before.maxX),
                      abs(now.view.minY - before.minY), abs(now.view.maxY - before.maxY)].max()! * k
        guard spread > 1.5 else { return ([now.view], now.center) }
        let count = min(max(Int((spread / 2.5).rounded(.up)), 3), 24)
        return ((0 ..< count).map { sample(shutter * Double($0) / Double(count - 1)) }, now.center)
    }

    func screenLayer(_ screen: CIImage, geometry g: ScreenGeometry, view: CGRect, output: CGSize, sharp: Bool) -> CIImage {
        let rect = flip(viewed(g.contentRect, view: view, output: output), height: output.height)
        let src = screen.extent
        return place(screen.transformed(by: CGAffineTransform(translationX: -src.minX, y: -src.minY)),
                     sourceSize: src.size, into: rect, sharp: sharp).cropped(to: rect)
    }

    static let zoomBlurKernel = kernel("zoomMotionBlur", in: "ZoomBlur", label: "Zoom blur")

    func blurredScreenLayer(_ screen: CIImage, geometry g: ScreenGeometry, views: [CGRect], output: CGSize,
                            canvas: CGRect) -> CIImage? {
        guard let kernel = Self.zoomBlurKernel, let now = views.first, let then = views.last else { return nil }
        var source = screen.transformed(by: CGAffineTransform(translationX: -screen.extent.minX, y: -screen.extent.minY))
        let shrink = viewed(g.contentRect, view: now, output: output).width / source.extent.width
        if shrink < 0.97 {
            let f = CIFilter.lanczosScaleTransform()
            f.inputImage = source.clampedToExtent().cropped(to: source.extent)
            f.scale = Float(shrink)
            f.aspectRatio = 1
            source = f.outputImage!.cropped(to: CGRect(origin: .zero, size: CGSize(
                width: (source.extent.width * shrink).rounded(.down), height: (source.extent.height * shrink).rounded(.down))))
        }
        let size = source.extent.size
        let sampled = source.clampedToExtent()
        func rect(_ r: CGRect) -> CIVector { CIVector(x: r.minX, y: r.minY, z: r.width, w: r.height) }
        let args: [Any] = [sampled, rect(now), rect(then), rect(g.contentRect), CIVector(x: output.width, y: output.height),
                           CIVector(x: size.width, y: size.height), Float(views.count)]
        let covered = views.map { flip(viewed(g.contentRect, view: $0, output: output), height: output.height) }
            .reduce(CGRect.null) { $0.union($1) }.insetBy(dx: -1, dy: -1)
            .intersection(canvas)
        guard !covered.isEmpty else { return nil }
        return kernel.apply(extent: covered, roiCallback: { _, _ in sampled.extent.isInfinite ? CGRect(origin: .zero, size: size) : sampled.extent },
                            arguments: args)
    }
}
