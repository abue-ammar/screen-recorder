//
//  ProjectCard.swift
//  Slice
//
//  Created by rit3zh CX on 10/2/26.
//

import SliceCore
import SwiftUI

struct ProjectCard: View {
    let bundle: ProjectBundle
    let open: () -> Void
    let delete: () -> Void
    @State private var preview: ProjectPreview?
    @State private var loaded = false
    @State private var hovering = false
    @State private var deleting = false

    init(bundle: ProjectBundle, open: @escaping () -> Void, delete: @escaping () -> Void) {
        self.bundle = bundle
        self.open = open
        self.delete = delete
        // A picture already made shows straight away instead of fading in again.
        let cached = ProjectPreviews.shared.cached(bundle.url)
        _preview = State(initialValue: cached)
        _loaded = State(initialValue: cached != nil)
    }

    private static let radius: CGFloat = 12
    private static let hoverZoom: CGFloat = 1.025

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            face
            caption
        }
        .opacity(deleting ? 0 : 1)
        .scaleEffect(deleting ? 0.96 : 1)
        .contentShape(Rectangle())
        .onTapGesture(perform: open)
        .contextMenu {
            Button("Open") { open() }
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([bundle.url]) }
            Divider()
            Button("Move to Trash", role: .destructive) { remove() }
        }
        .onHover { hovering = $0 }
        .animation(Theme.hover, value: hovering)
        .task(id: bundle.url) {
            let made = await ProjectPreviews.shared.preview(for: bundle)
            withAnimation(preview == nil ? .easeOut(duration: 0.25) : nil) {
                preview = made
                loaded = true
            }
        }
    }

    private var face: some View {
        let shape = RoundedRectangle(cornerRadius: Self.radius, style: .continuous)
        return shape
            .fill(Theme.panel)
            .aspectRatio(16 / 10, contentMode: .fit)
            .overlay {
                if let image = preview?.image {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .aspectRatio(contentMode: (preview?.aspect ?? 1) >= 1.3 ? .fill : .fit)
                        .scaleEffect(hovering ? Self.hoverZoom : 1)
                        .transition(.opacity)
                } else if loaded {
                    Image(systemName: "video")
                        .font(.system(size: 18, weight: .regular))
                        .foregroundStyle(.quaternary)
                        .transition(.opacity)
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if let preview {
                    Text(Self.timecode(preview.duration))
                        .font(.rounded(11, .semibold))
                        .monospacedDigit()
                        .foregroundStyle(.white.opacity(0.92))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2.5)
                        .background(Capsule().fill(.black.opacity(0.5)))
                        .background(Capsule().fill(.ultraThinMaterial))
                        .padding(8)
                        .transition(.opacity)
                }
            }
            .clipShape(shape)
            .overlay(shape.strokeBorder(Color.white.opacity(hovering ? 0.13 : 0.05), lineWidth: 1))
    }

    private var caption: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(bundle.displayName)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(hovering ? Color.primary : Color.primary.opacity(0.88))
                .lineLimit(1)
                .truncationMode(.middle)
            Text(preview.map { Self.age($0.modified) } ?? " ")
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.horizontal, 2)
    }

    private func remove() {
        guard !deleting else { return }
        withAnimation(.easeIn(duration: 0.2)) { deleting = true } completion: { delete() }
    }

    static func timecode(_ seconds: Double) -> String {
        let s = Int(seconds.rounded())
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
    }

    static func age(_ date: Date) -> String {
        if Date().timeIntervalSince(date) < 60 { return "Just now" }
        if Date().timeIntervalSince(date) < 7 * 86400 {
            return date.formatted(.relative(presentation: .named))
        }
        let thisYear = Calendar.current.isDate(date, equalTo: Date(), toGranularity: .year)
        return thisYear ? date.formatted(.dateTime.month(.abbreviated).day()) : date.formatted(.dateTime.month(.abbreviated).day().year())
    }
}
