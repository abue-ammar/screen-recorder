//
//  InspectorView.swift
//  Slice
//
//  Created by rit3zh CX on 10/9/26.
//

import SliceCore
import SwiftUI

struct InspectorView: View {
    let editor: EditorModel
    let tab: InspectorTab

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                switch tab {
                case .zoom: ZoomSection(editor: editor)
                case .export: OutputSection(editor: editor)
                case .keyboard: KeystrokesSection(editor: editor)
                case .cursor: MouseSection(editor: editor)
                case .audio: AudioSection(editor: editor)
                }
            }
            .padding(18)
        }
        .scrollIndicators(.never)
    }
}

// MARK: - Selection

struct SelectionInspector: View {
    let editor: EditorModel
    @State private var confirmDeleteTake = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(spacing: 10) {
                    Image(systemName: symbol)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(tint)
                        .frame(width: 28, height: 28)
                        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(tint.opacity(0.16)))
                    Text(title).font(.rounded(16, .semibold))
                    Spacer()
                    Button { withAnimation(Theme.swap) { editor.selection = nil } } label: { Image(systemName: "xmark") }
                        .buttonStyle(IconButtonStyle(size: 26, iconSize: 11))
                        .help("Done")
                }
                content
            }
            .padding(18)
        }
        .scrollIndicators(.never)
    }

    private var title: String {
        switch editor.selection {
        case .zoom: "Zoom"
        case .section: editor.selectedSection.map { "Take \($0.clipIndex + 1)" } ?? "Section"
        case .redact: "Blur"
        case .annotation: "Drawing"
        case nil: ""
        }
    }

    private var symbol: String {
        switch editor.selection {
        case let .zoom(id):
            editor.project.zoomBlocks.first { $0.id == id }?.kind == .liquidGlass ? "drop" : "plus.magnifyingglass"
        case .redact: "eye.slash"
        case .annotation: AnnotationLane.symbol
        case .section, nil: "film"
        }
    }

    private var tint: Color {
        switch editor.selection {
        case .zoom: Theme.zoom
        case .redact: Theme.privacy
        case .annotation: Theme.annotation
        case .section, nil: Theme.clip
        }
    }

    @ViewBuilder private var content: some View {
        switch editor.selection {
        case let .zoom(id):
            if let block = editor.project.zoomBlocks.first(where: { $0.id == id }) {
                ZoomInspector(editor: editor, block: block)
            }
        case .section:
            if let seg = editor.selectedSection {
                let clip = editor.project.clips[seg.clipIndex]
                PanelSection("Section") {
                    InfoRow(title: "From", value: format(seg.sourceStart))
                    InfoRow(title: "To", value: format(seg.sourceEnd))
                    InfoRow(title: "Length", value: format(seg.duration))
                    PanelNote("Drag the section's edges on the timeline to trim it. Split with ✂︎ at the playhead.")
                }
                SectionSpeedPicker(editor: editor, segment: seg)
                if editor.canDeleteSection {
                    Button("Delete this section") { editor.deleteSelectedSection() }
                        .buttonStyle(DestructiveButtonStyle())
                        .help("Removes just this part of the take (Delete key). ⌘Z undoes.")
                }
                PanelDivider()
                PanelSection("Take \(seg.clipIndex + 1)") {
                    InfoRow(title: "Recorded length", value: format(clip.duration))
                    InfoRow(title: "Screen", value: "\(Int(clip.screenPixelSize.width)) × \(Int(clip.screenPixelSize.height))")
                    InfoRow(title: "Screen audio", value: clip.screenAudioFile == nil ? "None" : "Yes")
                }
                if editor.canDeleteClip {
                    Button("Delete whole take…") { confirmDeleteTake = true }
                        .buttonStyle(DestructiveButtonStyle())
                        .confirmationDialog("Delete take \(seg.clipIndex + 1)? It's removed when you close the project (⌘Z undoes until then).",
                                            isPresented: $confirmDeleteTake) {
                            Button("Delete take", role: .destructive) { editor.deleteClip(clip.id) }
                        }
                }
            }
        case .redact:
            if let block = editor.selectedRedaction { RedactInspector(editor: editor, block: block) }
        case .annotation:
            if let block = editor.selectedAnnotation { AnnotationInspector(editor: editor, block: block) }
        case nil:
            EmptyView()
        }
    }
}
