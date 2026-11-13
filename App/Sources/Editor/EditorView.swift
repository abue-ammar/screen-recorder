//
//  EditorView.swift
//  Slice
//
//  Created by rit3zh CX on 10/9/26.
//

import SliceCore
import SwiftUI
import UniformTypeIdentifiers

struct EditorView: View {
    @Environment(AppModel.self) var model
    let editor: EditorModel
    @State private var showExport = false
    @State private var timelineZoom = 1.0
    @AppStorage("sidePanel.tab") private var inspectorTab = InspectorTab.frame.rawValue

    var body: some View {
        VStack(spacing: 0) {
            EditorTitleBar(editor: editor, isExporting: isExporting, openExport: openExport)
            HStack(alignment: .top, spacing: 14) {
                VStack(spacing: 0) {
                    PreviewHeader(editor: editor)
                    PreviewArea(editor: editor)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .padding(.horizontal, 28)
                        .padding(.vertical, 14)
                    TransportBar(editor: editor, timelineZoom: $timelineZoom)
                }
                .frame(minWidth: 520)
                SidePanel(editor: editor)
                    .frame(width: 390)
            }
            .padding(.leading, 12)
            .padding(.trailing, 14)
            .padding(.top, 8)
            .padding(.bottom, 10)
            TimelineView(editor: editor, zoom: $timelineZoom)
                .frame(height: 242 + (editor.hasAnnotations ? 46 : 0))
                .animation(Theme.slide, value: editor.hasAnnotations)
        }
        .overlay {
            ExportLayer(job: editor.exportJob, stop: editor.stopExport, close: editor.dismissExport)
        }
        .ignoresSafeArea(.container, edges: .top)
        .background(Theme.window)
        .preferredColorScheme(.dark)
        .tint(Theme.accent)
        .toolbar(removing: .title)
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        .navigationTitle(editor.project.name)
        .dropDestination(for: URL.self) { urls, _ in
            if let other = urls.first(where: ProjectBundle.isProject) {
                model.openFiles([other])
                return true
            }
            let videos = urls.filter { UTType(filenameExtension: $0.pathExtension)?.conforms(to: .movie) ?? false }
            guard !videos.isEmpty else { return false }
            Task { await editor.importClips(videos) }
            return true
        }
        .sheet(isPresented: $showExport) { ExportSheet(editor: editor) }
        .background { shortcuts }
    }

    @ViewBuilder private var shortcuts: some View {
        Group {
            Button("") { editor.deleteSelection() }.keyboardShortcut(.delete, modifiers: []).hidden()
                .disabled(editor.isEditingText)
            Button("") { editor.togglePlay() }.keyboardShortcut(.space, modifiers: []).hidden()
                .disabled(editor.isEditingText)
            Button("") { editor.splitAtPlayhead() }.keyboardShortcut("b", modifiers: .command).hidden()
            Button("") { editor.isCutting = false }.keyboardShortcut(.escape, modifiers: []).hidden()
                .disabled(!editor.isCutting)
            Button("") { editor.undo() }.keyboardShortcut("z", modifiers: .command).hidden()
            Button("") { editor.redo() }.keyboardShortcut("z", modifiers: [.command, .shift]).hidden()
            Button("") { openExport() }.keyboardShortcut("e", modifiers: [.command, .shift]).hidden()
            Button("") { zoomTimeline(by: 1.5) }.keyboardShortcut("=", modifiers: .command).hidden()
            Button("") { zoomTimeline(by: 1 / 1.5) }.keyboardShortcut("-", modifiers: .command).hidden()
            Button("") { withAnimation(Theme.swap) { timelineZoom = 1 } }.keyboardShortcut("0", modifiers: .command).hidden()
            ForEach(Array(InspectorTab.allCases.enumerated()), id: \.offset) { i, tab in
                Button("") { show(tab) }.keyboardShortcut(KeyEquivalent(Character("\(i + 1)")), modifiers: .command).hidden()
            }
        }
        .disabled(isExporting)
    }

    private var isExporting: Bool { editor.exportJob != nil }

    private func openExport() {
        editor.pause()
        showExport = true
    }

    private func zoomTimeline(by factor: Double) {
        withAnimation(Theme.swap) { timelineZoom = min(max(timelineZoom * factor, 1), 10) }
    }

    private func show(_ tab: InspectorTab) {
        withAnimation(Theme.slide) {
            inspectorTab = tab.rawValue
            editor.selection = nil
        }
    }
}

@MainActor
func importInto(_ editor: EditorModel) {
    guard let urls = chooseVideos() else { return }
    Task { await editor.importClips(urls) }
}

@MainActor
func chooseVideos(message: String = "Choose videos to add. They're copied into the project.", multiple: Bool = true) -> [URL]? {
    let panel = NSOpenPanel()
    panel.allowedContentTypes = [.movie]
    panel.allowsMultipleSelection = multiple
    panel.message = message
    return panel.runModal() == .OK && !panel.urls.isEmpty ? panel.urls : nil
}
