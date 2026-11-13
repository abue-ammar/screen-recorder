//
//  TestMovie.swift
//  SliceCoreTests
//

import AVFoundation
import CoreImage

enum TestMovie {
    static func write(to url: URL, size: CGSize, codec: AVVideoCodecType = .h264, frames count: Int, fps: Int,
                      frame: (Int) throws -> CIImage) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let receiver = writer.inputPixelBufferReceiver(for: AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: codec, AVVideoWidthKey: size.width, AVVideoHeightKey: size.height,
        ]), pixelBufferAttributes: attributes(size))
        try writer.start()
        writer.startSession(atSourceTime: .zero)
        let context = CIContext()
        for i in 0 ..< count {
            let image = try frame(i)
            let buffer = try CVMutablePixelBuffer(attributes(size))
            buffer.withUnsafeBuffer { context.render(image, to: $0) }
            try await receiver.append(CVReadOnlyPixelBuffer(buffer), with: CMTime(value: CMTimeValue(i), timescale: CMTimeScale(fps)))
        }
        receiver.finish()
        await writer.finishWriting()
        if let error = writer.error { throw error }
    }

    static func attributes(_ size: CGSize) -> CVPixelBufferCreationAttributes {
        CVPixelBufferCreationAttributes(pixelFormatType: CVPixelFormatType(rawValue: kCVPixelFormatType_32BGRA),
                                        size: CVImageSize(width: Int(size.width), height: Int(size.height)))
    }

    static func image(_ buffer: CVReadOnlyPixelBuffer) -> CIImage {
        buffer.withUnsafeBuffer { CIImage(cvPixelBuffer: $0) }
    }
}
