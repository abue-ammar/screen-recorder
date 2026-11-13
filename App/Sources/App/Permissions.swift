//
//  Permissions.swift
//  Screen Recorder
//
//  Created by abue-ammar on 11/14/26.
//

import AppKit
import ApplicationServices
import CoreGraphics

/// The macOS permissions the app records with. macOS doesn't say when one changes in System Settings, so views that
/// show them read them again while they're on screen (`watch()`).
@MainActor
@Observable
final class Permissions {
    enum Kind {
        /// Needed for any recording.
        case screenRecording
        /// Lets the keyboard be recorded, for the keystroke overlay and typing sounds.
        case accessibility

        fileprivate var pane: URL {
            let anchor = self == .screenRecording ? "Privacy_ScreenCapture" : "Privacy_Accessibility"
            return URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)")!
        }

        fileprivate var askedKey: String { self == .screenRecording ? "permissions.askedScreen" : "permissions.askedKeys" }
    }

    static let shared = Permissions()

    private(set) var screenRecording = CGPreflightScreenCaptureAccess()
    private(set) var accessibility = AXIsProcessTrusted()

    private init() {}

    func isGranted(_ kind: Kind) -> Bool {
        kind == .screenRecording ? screenRecording : accessibility
    }

    /// Reads both again every second until the calling task is cancelled.
    func watch() async {
        while !Task.isCancelled {
            refresh()
            try? await Task.sleep(for: .seconds(1))
        }
    }

    /// The first time, shows macOS's own prompt, which also puts the app in System Settings' list; after that macOS
    /// won't ask again, so the setting is opened instead.
    func request(_ kind: Kind) {
        refresh()
        guard !isGranted(kind) else { return }
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: kind.askedKey) else { return openSettings(for: kind) }
        defaults.set(true, forKey: kind.askedKey)
        switch kind {
        case .screenRecording: CGRequestScreenCaptureAccess()
        case .accessibility: AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        }
    }

    func openSettings(for kind: Kind) {
        NSWorkspace.shared.open(kind.pane)
    }

    private func refresh() {
        let screen = CGPreflightScreenCaptureAccess(), keys = AXIsProcessTrusted()
        if screen != screenRecording { screenRecording = screen }
        if keys != accessibility { accessibility = keys }
    }
}
