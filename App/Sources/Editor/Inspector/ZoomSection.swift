//
//  ZoomSection.swift
//  Slice
//
//  Created by rit3zh CX on 10/9/26.
//

import SliceCore
import SwiftUI

struct ZoomSection: View {
    @Bindable var editor: EditorModel

    var body: some View {
        Group {
            PanelSection("Zoom") {
                PanelSlider("Zoom speed", value: $editor.project.style.zoomTransitionDuration, in: 0.3 ... 2,
                            default: FrameStyle().zoomTransitionDuration) { String(format: "%.1fs", $0) }
                PanelToggle("Motion blur", isOn: $editor.project.style.motionBlur)
                    .help("Blurs the screen while it zooms, like a camera exposure")
                if editor.project.style.motionBlur {
                    PanelSlider("Amount", value: $editor.project.style.motionBlurAmount, in: 0.1 ... 1,
                                default: FrameStyle().motionBlurAmount) { "\(Int(($0 * 100).rounded()))%" }
                }
            }

            PanelDivider()

            SmartZoomSection(editor: editor)

            PanelDivider()

            SpeedUpSection(editor: editor)
        }
        .animation(.snappy, value: editor.project.style.motionBlur)
    }
}
