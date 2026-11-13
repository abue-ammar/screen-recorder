//
//  PermissionsSection.swift
//  Screen Recorder
//
//  Created by abue-ammar on 11/14/26.
//

import SwiftUI

struct PermissionsSection: View {
    private let permissions = Permissions.shared

    var body: some View {
        Section {
            row(.screenRecording, title: "Screen Recording", detail: "Needed to record your screen and the sound from apps.")
            row(.accessibility, title: "Accessibility", detail: "Records the keys you press, for the keystroke overlay and typing sounds.")
        } header: {
            Text("Permissions")
        } footer: {
            Text("Change these in System Settings › Privacy & Security. macOS may ask you to reopen Screen Recorder after allowing Screen Recording.")
                .foregroundStyle(.secondary)
        }
        .task { await permissions.watch() }
    }

    private func row(_ kind: Permissions.Kind, title: String, detail: String) -> some View {
        let granted = permissions.isGranted(kind)
        return HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                Text(detail).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer()
            Label(granted ? "Allowed" : "Not allowed", systemImage: granted ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(granted ? .green : .orange)
            Button(granted ? "Open…" : "Allow…") {
                if granted { permissions.openSettings(for: kind) } else { permissions.request(kind) }
            }
            .help(granted ? "Opens this setting in System Settings" : "Asks macOS for this permission")
        }
        .animation(.smooth(duration: 0.25), value: granted)
    }
}
