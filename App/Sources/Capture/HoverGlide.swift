//
//  HoverGlide.swift
//  Slice
//
//  Created by rit3zh CX on 10/1/26.
//

import SwiftUI

@Observable @MainActor
final class HoverGlide {
    private(set) var id: AnyHashable?
    /// Leaving one item and entering the next arrive as two events; hold the highlight briefly so it slides across.
    @ObservationIgnored private var leaving: Task<Void, Never>?

    func enter(_ id: AnyHashable) {
        leaving?.cancel()
        leaving = nil
        guard self.id != id else { return }
        withAnimation(Bar.glide) { self.id = id }
    }

    func exit(_ id: AnyHashable) {
        guard self.id == id else { return }
        leaving?.cancel()
        leaving = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(70))
            guard !Task.isCancelled, let self, self.id == id else { return }
            withAnimation(Bar.hover) { self.id = nil }
        }
    }
}

struct BarGlide {
    let tracker: HoverGlide
    let namespace: Namespace.ID

    @MainActor func isHovering(_ id: AnyHashable) -> Bool { tracker.id == id }
}

extension EnvironmentValues {
    @Entry var barGlide: BarGlide?
}

struct GlideHover: ViewModifier {
    let id: AnyHashable
    var cornerRadius: CGFloat = 12
    var opacity: Double = 0.08
    @Environment(\.barGlide) private var glide

    func body(content: Content) -> some View {
        content
            .background {
                if let glide, glide.tracker.id == id {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(Color.white.opacity(opacity))
                        .matchedGeometryEffect(id: "hover", in: glide.namespace)
                        .transition(.opacity)
                }
            }
            .onHover { inside in
                guard let glide else { return }
                if inside { glide.tracker.enter(id) } else { glide.tracker.exit(id) }
            }
    }
}

extension View {
    func glideHover(_ id: AnyHashable, cornerRadius: CGFloat = 12, opacity: Double = 0.08) -> some View {
        modifier(GlideHover(id: id, cornerRadius: cornerRadius, opacity: opacity))
    }
}
