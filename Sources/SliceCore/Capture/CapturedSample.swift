//
//  CapturedSample.swift
//  SliceCore
//
//  Created by abue-ammar on 11/14/26.
//

import CoreMedia

extension CMReadySampleBuffer<CMSampleBuffer.DynamicContent> {
    /// Captured buffers are never changed once they arrive, so a writer can share one with the code still reading it.
    public init(captured sample: CMSampleBuffer) {
        nonisolated(unsafe) let sample = sample
        self.init(unsafeBuffer: sample)
    }
}
