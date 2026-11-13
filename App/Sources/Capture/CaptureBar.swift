//
//  CaptureBar.swift
//  Slice
//
//  Created by rit3zh CX on 10/1/26.
//

import ScreenCaptureKit
import SwiftUI

struct CaptureBar: View {
    @Environment(AppModel.self) var model

    enum Kind: String, CaseIterable { case display = "Display", window = "Window", area = "Area" }

    enum Picker: Hashable { case source(Kind), options }

    @AppStorage("setup.kind") var kind: Kind = .display
    @AppStorage("setup.frameRate") var fps = Recorder.Settings.best
    @AppStorage("setup.screenAudio") var screenAudio = true
    @AppStorage("setup.keys") var keys = true
    @AppStorage("setup.typing") var typing = false
    let permissions = Permissions.shared
    @State var displayID: CGDirectDisplayID?
    @AppStorage("setup.display") var savedDisplay = 0
    @State var displays = DisplayInfo.all()
    @State var windowID: CGWindowID?
    let areaOverlay = AreaOverlay.shared
    let windowPicker = WindowPicker.shared
    @State var windows: [SCWindow] = []
    @State var loadError: String?
    @State var picker: Picker?
    @State var appeared = false
    @State var starting = false
    @State var glide = HoverGlide()
    @Namespace var hoverSpace
    @State var optionsGlide = HoverGlide()
    @Namespace var optionsSpace
    @Namespace var selection

    var body: some View {
        let compact = stage != .setup
        controls
            .opacity(compact ? 0 : 1)
            .scaleEffect(compact ? 0.97 : 1)
            .animation(.easeOut(duration: compact ? 0.16 : 0.3), value: compact)
            .disabled(compact)
            .background(MorphSurface(size: stage.surfaceSize))
            .overlay { stageContent }
            .animation(stage == .drawing || stage == .live(canDraw: true) ? LiveBar.expand : .spring(response: 0.5, dampingFraction: 0.68),
                       value: stage)
            .padding(Bar.inset)
            .environment(\.colorScheme, .dark)
            .scaleEffect(appeared ? 1 : 0.97, anchor: .bottom)
            .offset(y: appeared ? 0 : 10)
            .opacity(appeared ? 1 : 0)
            .background(BarWindowConfigurator())
            .onAppear {
                withAnimation(.spring(response: 0.45, dampingFraction: 0.72)) { appeared = true }
            }
            .onChange(of: compact) { if compact { picker = nil } }
            .onChange(of: stage, initial: true) { BarClickThrough.track(stage == .setup ? nil : stage.surfaceSize) }
            .onChange(of: areaMode, initial: true) { areaOverlay.present(areaMode) }
            .onChange(of: kind == .window && stage == .setup, initial: true) { windowPicker.present(kind == .window && stage == .setup) }
            .onChange(of: windows.map(\.windowID), initial: true) { windowPicker.recordable = Set(windows.map(\.windowID)) }
            .onChange(of: windowID, initial: true) { windowPicker.select(windowID) }
            .onChange(of: picker) { if picker != .source(.window) { windowPicker.clearPreview() } }
            .onAppear {
                windowPicker.onPick = { id in windowID = id }
                windowPicker.onRecord = { id in
                    windowID = id
                    record(.window(id))
                }
                windowPicker.onUnknown = { Task { await loadWindows() } }
            }
            .onDisappear {
                BarClickThrough.track(nil)
                areaOverlay.present(.hidden)
                windowPicker.present(false)
            }
            .onChange(of: model.recordingPhase == nil) { if model.recordingPhase == nil { starting = false } }
            .onAppear { if model.recordingPhase == nil { starting = false } }
    }

    var controls: some View {
        HStack(spacing: 0) {
            HStack(spacing: 2) {
                ForEach(Kind.allCases, id: \.self) { k in
                    SourceTile(kind: k, selected: kind == k, hasChoices: hasChoices(k), namespace: selection) { choose(k) }
                        .help(help(for: k))
                        .popover(isPresented: shown(.source(k)), arrowEdge: .top) { sourcePicker(k) }
                }
            }
            .padding(.leading, 14)
            .padding(.trailing, 8)
            BarDivider()
            optionsButton
                .padding(.horizontal, 8)
            BarDivider()
            RecordButton(title: recordTitle, ready: source != nil) {
                if source == nil { choose(kind) } else { record() }
            }
            .padding(.horizontal, 14)
            BarDivider()
            CloseButton { model.cancelSetup() }
                .padding(.leading, 14)
                .padding(.trailing, 4)
            BarGrip()
                .padding(.trailing, 6)
        }
        .frame(height: 72)
        .barDragBackground()
        .fixedSize()
        .environment(\.barGlide, BarGlide(tracker: glide, namespace: hoverSpace))
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)) { _ in
            refreshDisplays()
        }
        .task { await permissions.watch() }
        .task {
            refreshDisplays()
            if kind == .area, areaOverlay.area == nil { kind = .display }
            await loadWindows()
        }
    }

    // MARK: - Recording stages

    var stage: BarStage {
        model.recordingPhase == nil && starting ? .countdown(3) : BarStage(phase: model.recordingPhase, annotating: model.annotating)
    }

    @ViewBuilder var stageContent: some View {
        ZStack {
            switch stage {
            case .setup:
                EmptyView()
            case let .countdown(n):
                Text("\(n)")
                    .font(.system(size: 30, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.white)
                    .contentTransition(.numericText(countsDown: true))
                    .animation(.spring(response: 0.42, dampingFraction: 0.62), value: n)
                    .transition(.stageContent)
            case .live, .drawing:
                if let recording = model.recording {
                    LiveBar(recording: recording, drawing: stage == .drawing,
                            session: model.annotating == nil ? nil : AnnotationController.shared.session)
                        .transition(.stageContent)
                }
            case .saving:
                ProgressView()
                    .controlSize(.small)
                    .transition(.stageContent)
            }
        }
    }

    // MARK: - Recording

    func loadWindows() async {
        do {
            let content = try await SourceResolver.shareableContent()
            let myPID = ProcessInfo.processInfo.processIdentifier
            windows = content.windows
                .filter { w in
                    guard w.windowLayer == 0, w.frame.width > 120, w.frame.height > 80, let app = w.owningApplication,
                          app.processID != myPID,
                          NSRunningApplication(processIdentifier: app.processID)?.activationPolicy == .regular else { return false }
                    return w.isOnScreen || !(w.title ?? "").isEmpty
                }
                .sorted {
                    let a = $0.owningApplication?.applicationName ?? "", b = $1.owningApplication?.applicationName ?? ""
                    return a == b ? ($0.title ?? "") < ($1.title ?? "") : a.localizedStandardCompare(b) == .orderedAscending
                }
            loadError = nil
        } catch {
            loadError = error.localizedDescription
        }
    }

    func record(_ picked: CaptureSource? = nil) {
        guard let source = picked ?? source, !starting else { return }
        starting = true
        let settings = Recorder.Settings(source: source, fps: fps, screenAudio: screenAudio, keys: keys, typing: typing)
        model.startRecording(settings: settings, appendTo: model.setupAppendTo)
    }
}

private struct BarDivider: View {
    var body: some View {
        Rectangle()
            .fill(LinearGradient(colors: [.white.opacity(0), .white.opacity(0.14), .white.opacity(0)],
                                 startPoint: .top, endPoint: .bottom))
            .frame(width: 1, height: 44)
    }
}
