//
//  AudioSection.swift
//  Slice
//
//  Created by rit3zh CX on 10/9/26.
//

import SliceCore
import SwiftUI

struct AudioSection: View {
    @Bindable var editor: EditorModel

    var body: some View {
        PanelSection("Screen audio") {
            if editor.project.clips.contains(where: { $0.screenAudioFile != nil }) {
                volume
                PanelNote("Exports keep the sound's peaks under −1 dB, so it never clips.")
            } else {
                PanelNote("No audio was recorded for these takes.")
            }
        }
    }

    private var volume: some View {
        let value = $editor.project.screenAudioVolume
        return HStack(alignment: .bottom, spacing: 8) {
            Button {
                withAnimation(.snappy) { value.wrappedValue = value.wrappedValue > 0 ? 0 : 1 }
            } label: {
                Image(systemName: value.wrappedValue > 0 ? "speaker.wave.2" : "speaker.slash")
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(IconButtonStyle(selected: value.wrappedValue == 0, size: 30, iconSize: 13))
            .help(value.wrappedValue > 0 ? "Mute screen audio" : "Unmute")
            PanelSlider("Volume", value: value, in: 0 ... 1.5, default: 1) { $0 > 0 ? "\(Int(($0 * 100).rounded()))%" : "Muted" }
        }
    }
}
