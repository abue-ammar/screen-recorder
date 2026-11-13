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
        let style = scene.project.style
        let layer = views.count > 1
            ? blurredScreenLayer(screen, geometry: g, views: views, style: style, output: out, canvas: canvas)
            : nil
        var image = (layer ?? average(views.map {
            screenLayer(screen, geometry: g, view: $0, style: style, output: out, sharp: views.count == 1)
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

    func backdrop(scene: RenderScene, time t: Double, options: Options) -> CIImage {
        let style = scene.project.style
        // A screen filling the frame edge to edge has black behind it.
        if style.padding < 0.0005 {
            return CIImage(color: .black).cropped(to: CGRect(origin: .zero, size: scene.output))
        }
        return background(style: style, image: options.backgroundImage, size: scene.output)
    }

    func background(style: FrameStyle, image: CIImage?, size: CGSize) -> CIImage {
        let rect = CGRect(origin: .zero, size: size)
        if let name = style.backgroundImage, let image, image.extent.width > 0 {
            let e = image.extent
            let s = max(size.width / e.width, size.height / e.height)
            let placed = image.transformed(by: CGAffineTransform(translationX: -e.minX, y: -e.minY)
                .concatenating(CGAffineTransform(scaleX: s, y: s))
                .concatenating(CGAffineTransform(translationX: (size.width - e.width * s) / 2, y: (size.height - e.height * s) / 2)))
                .clampedToExtent()
            guard style.backgroundBlur > 0.005 else { return placed.cropped(to: rect) }
            return blurredBackground(placed, key: "\(name)|\(e)", amount: style.backgroundBlur, size: size)
        }
        let f = CIFilter.linearGradient()
        f.point0 = CGPoint(x: 0, y: size.height)
        f.point1 = CGPoint(x: size.width * 0.3, y: 0)
        f.color0 = ciColor(style.backgroundTop)
        f.color1 = ciColor(style.backgroundBottom)
        return f.outputImage!.cropped(to: CGRect(origin: .zero, size: size))
    }

    /// The background image blurred by `amount`. It's a wide, still blur, so it's made once at a quarter of the size,
    /// kept, and scaled up: blurring the full frame again every frame would cost more than the rest of it.
    func blurredBackground(_ placed: CIImage, key: String, amount: Double, size: CGSize) -> CIImage {
        let rect = CGRect(origin: .zero, size: size)
        let q: CGFloat = 0.25
        let cacheKey = "\(key)|\(size)|\(amount)" as NSString
        if let cached = backgroundBlurs.object(forKey: cacheKey) { return cached }
        let sigma = min(size.width, size.height) * 0.05 * min(max(amount, 0), 1) * q
        let small = CGRect(x: 0, y: 0, width: (size.width * q).rounded(.up), height: (size.height * q).rounded(.up))
        let blurred = placed.transformed(by: CGAffineTransform(scaleX: q, y: q), highQualityDownsample: true)
            .clampedToExtent().applyingGaussianBlur(sigma: Double(sigma)).cropped(to: small)
        guard let cg = context.createCGImage(blurred, from: small) else { return placed.cropped(to: rect) }
        let image = CIImage(cgImage: cg).transformed(by: CGAffineTransform(scaleX: 1 / q, y: 1 / q))
            .clampedToExtent().cropped(to: rect)
        backgroundBlurs.setObject(image, forKey: cacheKey)
        return image
    }

    func screenLayer(_ screen: CIImage, geometry g: ScreenGeometry, view: CGRect, style: FrameStyle, output: CGSize,
                     sharp: Bool) -> CIImage {
        let k = output.width / view.width
        let ciRect = flip(viewed(g.contentRect, view: view, output: output), height: output.height)
        let src = screen.extent
        let placed = place(screen.transformed(by: CGAffineTransform(translationX: -src.minX, y: -src.minY)),
                           sourceSize: src.size, into: ciRect, sharp: sharp)

        let base = min(output.width, output.height)
        let mask = roundedRect(ciRect, radius: style.effectiveScreenCornerRadius * base * k)
        let layer = placed.applyingFilter("CIBlendWithAlphaMask", parameters: [
            kCIInputBackgroundImageKey: CIImage.empty(), kCIInputMaskImageKey: mask,
        ])
        return decorated(layer, geometry: g, view: view, style: style, output: output)
    }

    /// The recording's corner radius, unzoomed.
    func contentRadius(style: FrameStyle, output: CGSize) -> CGFloat {
        style.effectiveScreenCornerRadius * min(output.width, output.height)
    }

    func decorated(_ layer: CIImage, geometry g: ScreenGeometry, view: CGRect, style: FrameStyle,
                   output: CGSize) -> CIImage {
        var layer = layer
        let k = output.width / view.width
        let base = min(output.width, output.height)
        if style.screenBorder > 0.001, style.framing > 0.001 {
            let ciRect = flip(viewed(g.contentRect, view: view, output: output), height: output.height)
            let radius = style.effectiveScreenCornerRadius * base * k
            let w = max(base * 0.0014 * k, 1)
            let inner = roundedRect(ciRect.insetBy(dx: w, dy: w), radius: max(radius - w, 0))
            let ring = roundedRect(ciRect, radius: radius)
                .applyingFilter("CISourceOutCompositing", parameters: [kCIInputBackgroundImageKey: inner])
            layer = scaleAlpha(ring, by: 0.45 * style.screenBorder * style.framing).composited(over: layer)
        }
        if style.effectiveShadow > 0 {
            layer = layer.composited(over: screenShadow(geometry: g, view: view, style: style, output: output))
        }
        return layer
    }

    /// The screen's drop shadow for `view`. Everything about it (rect, corners, blur, offset) scales with the zoom, so
    /// it's rendered once as seen unzoomed, at a quarter of the resolution (it's a wide blur, so that can't show), kept,
    /// and only moved and scaled to the view: re-blurring it every frame of a zoom, at a radius growing with it, was
    /// most of what a zooming frame cost.
    func screenShadow(geometry g: ScreenGeometry, view: CGRect, style: FrameStyle, output: CGSize) -> CIImage {
        let full = g.fullView
        let k0 = output.width / full.width, k = output.width / view.width
        let base = min(output.width, output.height)
        let q: CGFloat = 0.25
        let rect = flip(viewed(g.contentRect, view: full, output: output), height: output.height)
        let radius = style.effectiveScreenCornerRadius * base * k0
        let key = "\(rect)|\(radius)|\(style.effectiveShadow)|\(base * k0)" as NSString
        var unzoomed = screenShadows.object(forKey: key)
        if unzoomed == nil {
            let small = CGRect(x: rect.minX * q, y: rect.minY * q, width: rect.width * q, height: rect.height * q)
            let image = shadow(for: roundedRect(small, radius: radius * q), strength: style.effectiveShadow,
                               blur: base * 0.02 * k0 * q, offset: base * 0.008 * k0 * q)
            let bounds = image.extent.integral
            if let cg = context.createCGImage(image, from: bounds) {
                unzoomed = CIImage(cgImage: cg).transformed(by: CGAffineTransform(translationX: bounds.minX, y: bounds.minY))
                unzoomed.map { screenShadows.setObject($0, forKey: key) }
            }
        }
        guard let unzoomed else { return .empty() }
        let s = k / k0
        let move = CGAffineTransform(a: s / q, b: 0, c: 0, d: s / q, tx: (full.minX - view.minX) * k,
                                     ty: output.height * (1 - s) - (full.minY - view.minY) * k)
        return unzoomed.transformed(by: move)
    }

    static let zoomBlurKernel = kernel("zoomMotionBlur", in: "ZoomBlur", label: "Zoom blur")

    func blurredScreenLayer(_ screen: CIImage, geometry g: ScreenGeometry, views: [CGRect], style: FrameStyle,
                            output: CGSize, canvas: CGRect) -> CIImage? {
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
        let radius = contentRadius(style: style, output: output)
        let args: [Any] = [sampled, rect(now), rect(then), rect(g.contentRect), CIVector(x: output.width, y: output.height),
                           CIVector(x: size.width, y: size.height), Float(radius), Float(views.count)]
        let covered = views.map { flip(viewed(g.contentRect, view: $0, output: output), height: output.height) }
            .reduce(CGRect.null) { $0.union($1) }.insetBy(dx: -1, dy: -1)
            .intersection(canvas)
        guard !covered.isEmpty,
              let layer = kernel.apply(extent: covered, roiCallback: { _, _ in sampled.extent.isInfinite ? CGRect(origin: .zero, size: size) : sampled.extent },
                                       arguments: args) else { return nil }
        return decorated(layer, geometry: g, view: now, style: style, output: output)
    }
}
