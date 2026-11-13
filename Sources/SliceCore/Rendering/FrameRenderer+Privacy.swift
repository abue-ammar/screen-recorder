//
//  FrameRenderer+Privacy.swift
//  SliceCore
//
//  Created by rit3zh CX on 10/17/26.
//

import CoreImage
import CoreImage.CIFilterBuiltins

extension FrameRenderer {
    /// The screen with each of `blocks` blurred or pixelated, before it's framed, so they ride along with zooms.
    func redacted(_ screen: CIImage, blocks: [RedactBlock]) -> CIImage {
        guard !blocks.isEmpty else { return screen }
        let e = screen.extent
        let unit = min(e.width, e.height)
        var image = screen
        for block in blocks {
            let r = RedactBlock.clamped(block.rect)
            let rect = CGRect(x: e.minX + r.minX * e.width, y: e.minY + (1 - r.maxY) * e.height,
                              width: r.width * e.width, height: r.height * e.height).integral.intersection(e)
            guard rect.width >= 1, rect.height >= 1 else { continue }
            let strength = min(max(block.strength, 0), 1)
            let hidden: CIImage
            switch block.style {
            case .blur:
                // Strong enough at the lowest setting that small text can't be read back out.
                let sigma = unit * (0.006 + 0.024 * strength)
                hidden = screen.clampedToExtent().applyingGaussianBlur(sigma: Double(sigma))
            case .pixelate:
                let f = CIFilter.pixellate()
                f.inputImage = screen.clampedToExtent()
                f.scale = Float(max(unit * (0.012 + 0.04 * strength), 4))
                f.center = CGPoint(x: rect.minX, y: rect.minY)
                hidden = f.outputImage!
            }
            let mask = roundedRect(rect, radius: min(rect.width, rect.height) * 0.18)
            image = hidden.cropped(to: rect).applyingFilter("CIBlendWithMask", parameters: [
                kCIInputBackgroundImageKey: image, kCIInputMaskImageKey: mask,
            ]).cropped(to: e)
        }
        return image
    }
}
