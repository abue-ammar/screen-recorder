//
//  Repeating.swift
//  Screen Recorder
//
//  Created by abue-ammar on 11/14/26.
//

/// Calls `tick` on the main actor every `interval` until the returned task is cancelled. Ticks keep a steady beat, and
/// one that comes late is not made up, so a busy main thread never causes a burst of them.
@MainActor
func repeating(every interval: Duration, _ tick: @escaping @MainActor () -> Void) -> Task<Void, Never> {
    Task {
        let clock = ContinuousClock()
        var next = clock.now
        while true {
            next = max(next + interval, clock.now)
            do { try await clock.sleep(until: next) } catch { return }
            tick()
        }
    }
}
