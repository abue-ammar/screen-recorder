//
//  Recorder+Recovery.swift
//  Slice
//
//  Created by rit3zh CX on 10/17/26.
//

import AppKit
import SliceCore

extension Recorder {
    /// Leaves a note of the take in its folder and saves its pointer every couple of seconds, so if the app stops before
    /// the take is saved (a crash, a quit, the Mac losing power) it comes back next launch with its pointer too.
    @MainActor
    func keepRecoverable(_ writer: TakeWriter, captureRect: CGRect) {
        try? bundle.noteRecording(writer.planned(captureRect: captureRect))
        cursorSaver?.cancel()
        cursorSaver = repeating(every: .seconds(ProjectBundle.fragmentInterval.seconds)) { [weak self] in self?.saveCursor() }
    }

    /// On the main thread, where the pointer is logged; the encoding and writing happen off it.
    @MainActor
    private func saveCursor() {
        guard !savingCursor, let writer = queue.sync(execute: { take }), let start = queue.sync(execute: { writer.startTime })
        else { return }
        savingCursor = true
        var snapshot = cursor.snapshot
        let url = writer.cursorURL
        if let rect = target?.rect, let annotations { snapshot.annotations = annotations(rect) }
        let log = snapshot.log(since: start.seconds)
        cursorQueue.async { [weak self] in
            if let data = try? JSONEncoder().encode(log) { try? data.write(to: url, options: .atomic) }
            Task { @MainActor in self?.savingCursor = false }
        }
    }

    /// Waits out a save under way, so it can't land on top of the finished take's log.
    func stopSavingCursor() async {
        await MainActor.run {
            cursorSaver?.cancel()
            cursorSaver = nil
        }
        await withCheckedContinuation { done in cursorQueue.async { done.resume() } }
    }
}
