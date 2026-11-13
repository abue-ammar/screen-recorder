//
//  App.swift
//  Slice
//
//  Created by rit3zh CX on 10/3/26.
//

import SliceCore
import SwiftUI
import UniformTypeIdentifiers

@main
struct SliceApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel.shared

    var body: some Scene {
        Window("Record", id: AppModel.captureBarID) {
            CaptureBar()
                .environment(model)
                .modifier(WindowActions(model: model))
        }
        .windowStyle(.plain)
        .windowLevel(.floating)
        // Project files are opened by AppDelegate; without this SwiftUI would also bring up the bar for them.
        .handlesExternalEvents(matching: [])
        .windowResizability(.contentSize)
        .windowBackgroundDragBehavior(.enabled)
        .restorationBehavior(.disabled)
        .defaultLaunchBehavior(.presented)
        .defaultWindowPlacement { content, context in
            let display = context.defaultDisplay.visibleRect
            let size = content.sizeThatFits(.unspecified)
            return WindowPlacement(CGPoint(x: display.midX - size.width / 2, y: display.maxY - size.height - 60), size: size)
        }

        Window("Screen Recorder", id: AppModel.mainWindowID) {
            RootView()
                .environment(model)
                .modifier(WindowActions(model: model))
                .frame(minWidth: 980, minHeight: 640)
        }
        .defaultSize(width: 1280, height: 820)
        .windowToolbarStyle(.unified)
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(.disabled)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Recording…") { model.newRecording() }.keyboardShortcut("n")
                Button("Open…") { model.chooseProjectToOpen() }.keyboardShortcut("o")
                Button("Projects") { model.showProjects() }.keyboardShortcut("p", modifiers: [.command, .shift])
            }
            CommandGroup(replacing: .saveItem) {
                Button("Save") { model.openEditor?.saveNow() }.keyboardShortcut("s")
                    .disabled(model.openEditor == nil)
                Button("Show in Finder") {
                    if let url = model.openEditor?.bundle.url { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                }
                .disabled(model.openEditor == nil)
            }
        }

        Settings {
            SettingsView()
        }
    }
}

private struct WindowActions: ViewModifier {
    let model: AppModel
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow

    func body(content: Content) -> some View {
        content.onAppear {
            model.openWindow = openWindow
            model.dismissWindow = dismissWindow
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var launched = false

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func application(_ application: NSApplication, open urls: [URL]) {
        if !launched { AppModel.shared.launchedWithProject = true }
        AppModel.shared.openFiles(urls)
    }

    func applicationWillTerminate(_ notification: Notification) {
        AppModel.shared.openEditor?.close()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        launched = true
        AnnotationController.shared.install()
        // Once the bar is on screen, so opening Screen Recorder never waits on the network.
        Task {
            try? await Task.sleep(for: .seconds(2))
            Updater.shared.start()
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        guard !flag else { return true }
        if AppModel.shared.recording == nil { AppModel.shared.newRecording() }
        return false
    }
}

struct RootView: View {
    @Environment(AppModel.self) var model

    var body: some View {
        ZStack {
            switch model.screen {
            case .home:
                ProjectsView()
            case let .editor(editor):
                EditorView(editor: editor)
                    .id(ObjectIdentifier(editor))
            }
        }
        .alert("Recording recovered", isPresented: Binding(get: { model.recovered != nil }, set: { if !$0 { model.recovered = nil } })) {
            Button("Open") {
                if let bundle = model.recovered { model.open(bundle) }
                model.recovered = nil
            }
            Button("Not Now", role: .cancel) { model.recovered = nil }
        } message: {
            Text("Screen Recorder stopped while “\(model.recovered?.displayName ?? "")” was recording. The take is back in the project, "
                + "up to the last couple of seconds before it stopped.")
        }
        .overlay {
            Theme.window
                .opacity(model.covered ? 1 : 0)
                .allowsHitTesting(model.covered)
        }
        .background(Theme.window)
        .background(MainWindowProbe())
        .preferredColorScheme(.dark)
        .alert("Something went wrong", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button("OK") { model.error = nil }
        } message: {
            Text(model.error ?? "")
        }
    }
}

private struct MainWindowProbe: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { Probe() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class Probe: NSView {
        private var closeObservation: NotificationCenter.ObservationToken?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            AppModel.mainWindow = window
            if let closeObservation { NotificationCenter.default.removeObserver(closeObservation) }
            closeObservation = NotificationCenter.default.addObserver(of: window, for: .willClose) { [weak window] _ in
                if AppModel.mainWindow === window { AppModel.mainWindow = nil }
            }
        }

        deinit {
            if let closeObservation { NotificationCenter.default.removeObserver(closeObservation) }
        }
    }
}

extension UTType {
    static let sliceProject = UTType(filenameExtension: ProjectBundle.fileExtension, conformingTo: .package)!
}
