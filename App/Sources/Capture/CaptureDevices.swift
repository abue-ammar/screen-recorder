//
//  CaptureDevices.swift
//  Slice
//
//  Created by rit3zh CX on 10/15/26.
//

import AVFoundation

/// The cameras and microphones the bar offers. Discovery sessions are slow, so the lists are kept and refreshed when
/// devices come and go instead of on every redraw.
@MainActor
@Observable
final class CaptureDevices {
    static let shared = CaptureDevices()

    private(set) var cameras: [AVCaptureDevice] = []
    private(set) var mics: [AVCaptureDevice] = []
    private var observers: [NSObjectProtocol] = []

    private init() {
        refresh()
        for name in [AVCaptureDevice.wasConnectedNotification, AVCaptureDevice.wasDisconnectedNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            })
        }
    }

    func refresh() {
        let c = AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera],
                                                 mediaType: .video, position: .unspecified).devices
        let m = AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone, .external], mediaType: .audio,
                                                 position: .unspecified).devices
        if c.map(\.uniqueID) != cameras.map(\.uniqueID) { cameras = c }
        if m.map(\.uniqueID) != mics.map(\.uniqueID) { mics = m }
    }
}
