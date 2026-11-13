//
//  CaptureBar+Options.swift
//  Slice
//
//  Created by rit3zh CX on 10/1/26.
//

import SwiftUI

extension CaptureBar {
    var optionsButton: some View {
        BarPill(id: "options", open: picker == .options, action: { picker = .options }) {
            Text("Options").lineLimit(1)
            Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold)).opacity(0.6)
        }
        .overlay(alignment: .topTrailing) {
            if keys && !permissions.accessibility {
                Circle().fill(.orange).frame(width: 7, height: 7).offset(x: -4, y: 6)
            }
        }
        .popover(isPresented: shown(.options), arrowEdge: .top) { options }
    }

    var options: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                SectionTitle("Frame rate")
                SwiftUI.Picker("Frame rate", selection: $fps) {
                    Text(bestRateLabel).tag(Recorder.Settings.best)
                    Text("60 fps").tag(60)
                    Text("30 fps").tag(30)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .help("Best records at 120 fps on ProMotion displays when the encoder can keep up at that size, otherwise 60.")
            }
            VStack(alignment: .leading, spacing: 8) {
                SectionTitle("Audio & keys")
                OptionToggle("Record sound from apps", isOn: $screenAudio)
                OptionToggle("Record keyboard", isOn: $keys.animation(.snappy))
                    .help("For showing the shortcuts you press over the video, and for typing sounds. Shortcuts (⌘, ⌃ or ⌥ with a key) and keys like esc and the arrows are recorded; for typing, only when a key went down, never which one.")
                if keys {
                    OptionToggle("Include typed text", isOn: $typing)
                        .transition(.opacity)
                        .help("Also records the letters you type, so the video can show them as you type. Password fields are never recorded.")
                }
                if keys && !permissions.accessibility {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        Text("Needs Accessibility access").foregroundStyle(.secondary)
                        Spacer()
                        Button("Allow…") { permissions.request(.accessibility) }
                            .controlSize(.small)
                    }
                    .font(.system(size: 11))
                }
            }
            .toggleStyle(.switch)
            .controlSize(.small)
            Divider()
            PickerRow(title: "Open Projects", selected: false, symbol: "square.grid.2x2") {
                picker = nil
                model.openProjectsFromBar()
            }
            .padding(.horizontal, -8)
        }
        .font(.system(size: 12.5))
        .padding(14)
        .frame(width: 290)
        .environment(\.barGlide, BarGlide(tracker: optionsGlide, namespace: optionsSpace))
        .barPopoverAppearance()
    }

    var bestRateLabel: String {
        let rate: Int? = switch source {
        case let .display(id), let .area(id, _): displays.first { $0.id == id }?.refreshRate
        default: NSScreen.main?.maximumFramesPerSecond
        }
        return (rate ?? 60) >= 120 ? "Best (120)" : "Best (60)"
    }

    func shown(_ p: Picker) -> Binding<Bool> {
        Binding(get: { picker == p }, set: { if !$0, picker == p { picker = nil } })
    }
}

/// A setting in the options: its name on the left, the switch lined up with the others on the right.
private struct OptionToggle: View {
    let title: String
    @Binding var isOn: Bool

    init(_ title: String, isOn: Binding<Bool>) {
        self.title = title
        _isOn = isOn
    }

    var body: some View {
        HStack(spacing: 8) {
            Text(title)
            Spacer(minLength: 12)
            Toggle(title, isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
        }
    }
}
