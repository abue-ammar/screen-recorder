//
//  GainEnvelope.swift
//  SliceCore
//
//  Created by rit3zh CX on 10/1/26.
//

import Foundation

/// A volume over time, straight lines between points; before the first and after the last it holds.
struct GainEnvelope: Equatable {
    struct Point: Equatable {
        var t: Double
        var gain: Double
    }

    private(set) var points: [Point]

    init(_ points: [Point]) {
        self.points = points.enumerated().sorted { ($0.element.t, $0.offset) < ($1.element.t, $1.offset) }.map(\.element)
    }

    static func constant(_ gain: Double) -> GainEnvelope { GainEnvelope([Point(t: 0, gain: gain)]) }

    func value(at t: Double) -> Double {
        guard let first = points.first else { return 1 }
        if t <= first.t { return first.gain }
        var lo = 0, hi = points.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if points[mid].t <= t { lo = mid } else { hi = mid - 1 }
        }
        guard lo + 1 < points.count else { return points[lo].gain }
        let a = points[lo], b = points[lo + 1]
        guard b.t - a.t > 1e-12 else { return b.gain }
        return a.gain + (b.gain - a.gain) * (t - a.t) / (b.t - a.t)
    }

    /// `level` with a short dip to silence at each join, so cuts don't click.
    static func joins(_ joins: [Double], level: Double, fade: Double = 0.012) -> GainEnvelope {
        guard level > 0, !joins.isEmpty else { return .constant(level) }
        var points: [Point] = []
        for j in joins {
            points += [Point(t: j - fade, gain: level), Point(t: j, gain: 0), Point(t: j + fade, gain: level)]
        }
        return GainEnvelope(points)
    }
}
