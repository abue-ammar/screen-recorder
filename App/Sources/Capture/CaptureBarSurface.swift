//
//  CaptureBarSurface.swift
//  Slice
//
//  Created by rit3zh CX on 10/1/26.
//

import SwiftUI

enum BarStage: Equatable {
    case setup
    case countdown(Int)
    case live(canDraw: Bool)
    case drawing
    case saving

    /// `annotating` is nil when the recording can't be drawn on.
    init(phase: RecordingController.Phase?, annotating: Bool? = nil) {
        switch phase {
        case nil: self = .setup
        case .preparing: self = .countdown(3)
        case let .countdown(n): self = .countdown(n)
        case .recording, .paused: self = annotating == true ? .drawing : .live(canDraw: annotating != nil)
        case .finishing: self = .saving
        }
    }

    @MainActor var surfaceSize: CGSize? {
        switch self {
        case .setup: nil
        case .countdown: CGSize(width: 112, height: Bar.height)
        case let .live(canDraw): CGSize(width: canDraw ? LiveBar.liveWidth : LiveBar.plainWidth, height: Bar.height)
        case .drawing: CGSize(width: LiveBar.drawingWidth, height: Bar.height)
        case .saving: CGSize(width: Bar.height, height: Bar.height)
        }
    }
}

extension AnyTransition {
    static var stageContent: AnyTransition {
        .asymmetric(insertion: .opacity.combined(with: .scale(scale: 0.8))
                        .animation(.spring(response: 0.42, dampingFraction: 0.6).delay(0.12)),
                    removal: .opacity.combined(with: .scale(scale: 0.8))
                        .animation(.easeOut(duration: 0.14)))
    }
}

struct MorphSurface: View {
    let size: CGSize?

    var body: some View {
        GeometryReader { geo in
            let s = size ?? geo.size
            Color.clear
                .frame(width: s.width, height: s.height)
                .modifier(BarSurface())
                .position(x: geo.size.width / 2, y: geo.size.height / 2)
        }
    }
}

enum Bar {
    static let hover = Animation.spring(response: 0.26, dampingFraction: 0.82)
    static let press = Animation.spring(response: 0.2, dampingFraction: 0.55)
    static let height: CGFloat = 72
    static let radius: CGFloat = 22
    /// Between the bar's edge and the controls inside it, the same on every side.
    static let padding: CGFloat = 7
    /// Controls as tall as the bar allows, with corners concentric with the bar's.
    static let itemHeight = height - 2 * padding
    static let itemRadius = radius - padding
    /// Between controls in a group, such as the source tiles.
    static let gap: CGFloat = 4
    /// Between a divider and the controls on either side of it.
    static let sectionGap: CGFloat = 12
    /// Around the bar inside its window, so its shadow isn't clipped.
    static let inset: CGFloat = 28
    static let glide = Animation.spring(response: 0.32, dampingFraction: 0.76)
}

struct BarSurface: ViewModifier {
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: Bar.radius, style: .continuous)
        content
            .glassEffect(.regular, in: shape)
            .background(BarShadow(shape: shape))
    }
}

struct BarShadow: View {
    let shape: RoundedRectangle

    var body: some View {
        shape.fill(.black)
            // Kept inside `Bar.inset`: a wider shadow is cut off square at the bar window's edge.
            .shadow(color: .black.opacity(0.22), radius: 10, y: 4)
            .shadow(color: .black.opacity(0.12), radius: 1.5, y: 0.5)
            .mask {
                Rectangle().padding(-60)
                    .overlay(shape.blendMode(.destinationOut))
                    .compositingGroup()
            }
    }
}
