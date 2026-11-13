//
//  PreviewPacking.swift
//  SliceCore
//
//  Created by rit3zh CX on 10/8/26.
//

import CoreImage

/// Takes of different sizes, played as one video for the preview: each frame holds its take's screen, unscaled, in
/// the bottom-left corner of a canvas big enough for the largest.
public struct PreviewPacking: Equatable, Sendable {
    public let screens: [CGSize]
    public let canvas: CGSize

    public init(screens: [CGSize]) {
        self.screens = screens
        let width = max(screens.map(\.width).max() ?? 16, 16)
        let height = max(screens.map(\.height).max() ?? 16, 16)
        canvas = CGSize(width: (Int(width + 1) / 2) * 2, height: (Int(height + 1) / 2) * 2)
    }

    func pack(screen: CIImage?) -> CIImage {
        let empty = CIImage(color: .clear).cropped(to: CGRect(origin: .zero, size: canvas))
        guard let screen else { return empty }
        return screen.transformed(by: CGAffineTransform(translationX: -screen.extent.minX, y: -screen.extent.minY))
            .composited(over: empty)
    }

    public func unpack(_ packed: CIImage, clip: Int) -> CIImage? {
        guard clip < screens.count else { return nil }
        return packed.cropped(to: CGRect(origin: .zero, size: screens[clip]))
    }
}
