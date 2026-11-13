//
//  FrameRenderer+Cursor.swift
//  SliceCore
//
//  Created by rit3zh CX on 10/13/26.
//

import CoreImage

extension FrameRenderer {
    func cursorLayer(_ pointer: CursorPointer, geometry g: ScreenGeometry, view: CGRect, settings: CursorSettings, press: CGFloat,
                     output: CGSize, canvas: CGRect) -> CIImage? {
        let content = viewed(g.contentRect, view: view, output: output)
        let size = settings.size * press
        let scale = content.width / pointer.screenPoints.width * size
        guard scale.isFinite, scale > 0.05 else { return nil }
        let steps = 8.0
        let raster = CGFloat(pow(2, (log2(Double(scale)) * steps).rounded(.up) / steps))
        func sprite(_ type: CursorType) -> CursorSprite? {
            let key = "\(settings.style.rawValue)|\(type.rawValue)|\(raster)" as NSString
            if let cached = cursorSprites.object(forKey: key) { return cached }
            guard let made = CursorSprite.render(style: settings.style, type: type, scale: raster) else { return nil }
            cursorSprites.setObject(made, forKey: key)
            return made
        }
        guard let current = sprite(pointer.type) else { return nil }
        let previous = pointer.fade < 1 ? pointer.previousType.flatMap(sprite) : nil
        let hot = CGPoint(x: content.minX + pointer.position.x * content.width,
                          y: output.height - (content.minY + pointer.position.y * content.height))
        let f = content.width / pointer.screenPoints.width * size / raster
        func placed(_ s: CursorSprite) -> CIImage {
            s.image.transformed(by: CGAffineTransform(translationX: -s.hotspot.x, y: -s.hotspot.y)
                .concatenating(CGAffineTransform(scaleX: f, y: f))
                .concatenating(CGAffineTransform(translationX: hot.x, y: hot.y)))
        }
        var layer = placed(current)
        if let previous {
            layer = scaleAlpha(layer, by: pointer.fade).applyingFilter("CIAdditionCompositing", parameters: [
                kCIInputBackgroundImageKey: scaleAlpha(placed(previous), by: 1 - pointer.fade),
            ])
        }
        if pointer.opacity < 1 { layer = scaleAlpha(layer, by: pointer.opacity) }
        let visible = flip(content, height: output.height).intersection(canvas)
        guard layer.extent.intersects(visible) else { return nil }
        return layer.cropped(to: visible)
    }

    // MARK: - 3D tilt

    static let tiltKernel = kernel("screenTilt", in: "ScreenTilt", label: "Screen tilt")

    func tilted(_ layer: CIImage, by warp: Homography, output: CGSize) -> CIImage {
        guard let kernel = Self.tiltKernel, let inverse = warp.inverse else { return layer }
        let m = inverse.m.map { CGFloat($0) }
        let source = layer.extent
        let args: [Any] = [layer, CIVector(x: m[0], y: m[1], z: m[2]), CIVector(x: m[3], y: m[4], z: m[5]),
                           CIVector(x: m[6], y: m[7], z: m[8])]
        return kernel.apply(extent: CGRect(origin: .zero, size: output), roiCallback: { _, r in
            guard let back = inverse.bounds(of: r) else { return source }
            return back.insetBy(dx: -3, dy: -3).intersection(source)
        }, arguments: args) ?? layer
    }
}
