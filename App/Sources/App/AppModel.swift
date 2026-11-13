//
//  AppModel.swift
//  Slice
//
//  Created by rit3zh CX on 10/3/26.
//

import SliceCore
import SwiftUI
import UniformTypeIdentifiers

@MainActor
@Observable
final class AppModel {
    static let shared = AppModel()

    enum Screen {
        case home
        case editor(EditorModel)
    }

    static let mainWindowID = "main"
    static let captureBarID = "capture"
    static weak var captureBarWindow: NSWindow?
    static weak var mainWindow: NSWindow?

    private(set) var screen: Screen = .home
    private(set) var covered = false
    private(set) var setupAppendTo: EditorModel?
    private(set) var recordingPhase: RecordingController.Phase?
    /// Whether the recording is being drawn on; nil when it can't be.
    private(set) var annotating: Bool?
    private var phaseWatch: Task<Void, Never>?
    private var annotateWatch: Task<Void, Never>?
    var openWindow: OpenWindowAction? {
        didSet {
            openPendingFiles()
            if recovered != nil { showRecovered() }
        }
    }
    var dismissWindow: DismissWindowAction?
    var recording: RecordingController?
    var projects: [ProjectBundle] = []
    var error: String?
    var launchedWithProject = false
    private var pendingFiles: [URL] = []
    /// A recording cut off last time, now back in this project.
    var recovered: ProjectBundle?
    var recovery: Task<Void, Never>?

    var openEditor: EditorModel? {
        if case let .editor(editor) = screen { editor } else { nil }
    }

    private init() {
        reloadProjects()
        recovery = Task { await recoverInterruptedTakes() }
    }

    func reloadProjects() { projects = ProjectBundle.list(adding: NSDocumentController.shared.recentDocumentURLs) }

    /// Drops the card straight away and moves the bundle to the Trash off the main thread; a big bundle froze the grid.
    func trash(_ bundle: ProjectBundle) {
        projects.removeAll { $0.url == bundle.url }
        let url = bundle.url
        Task.detached(priority: .userInitiated) {
            do {
                try FileManager.default.trashItem(at: url, resultingItemURL: nil)
            } catch {
                await MainActor.run { [weak self] in self?.reloadProjects() }
            }
        }
    }

    func newRecording(appendTo editor: EditorModel? = nil) {
        setupAppendTo = editor
        recordingPhase = nil
        openWindow?(id: Self.captureBarID)
        NSApp.activate()
    }

    func cancelSetup() {
        dismissWindow?(id: Self.captureBarID)
        setupAppendTo = nil
    }

    func showProjects() {
        openWindow?(id: Self.mainWindowID)
        NSApp.activate()
    }

    func openProjectsFromBar() {
        presentMainWindow()
        cancelSetup()
    }

    func show(_ screen: Screen, animated: Bool = true) {
        guard animated else {
            withTransaction(\.disablesAnimations, true) { self.screen = screen }
            return
        }
        switchScreen { screen }
    }

    /// Dips the window to its background, makes and swaps in the next screen while nothing is visible (the editor's
    /// first layout and frame are heavy, and would stutter any animation running over them), then lifts. `make`
    /// returning nil leaves things as they were.
    private func switchScreen(_ make: @escaping () -> Screen?) {
        withAnimation(.easeIn(duration: 0.14)) { covered = true } completion: { [weak self] in
            guard let self else { return }
            if let next = make() {
                withTransaction(\.disablesAnimations, true) { self.screen = next }
            }
            Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(80))
                withAnimation(.easeOut(duration: 0.26)) { self?.covered = false }
            }
        }
    }

    func importNewProject(_ urls: [URL]) {
        Task {
            do {
                let name = urls.first?.deletingPathExtension().lastPathComponent ?? "Imported"
                let (bundle, project) = try ExportDefaults.newProject(name: name)
                let editor = EditorModel(bundle: bundle, project: project)
                await editor.importClips(urls)
                guard !editor.project.clips.isEmpty else {
                    try? FileManager.default.removeItem(at: bundle.url)
                    self.error = editor.importError ?? "Nothing could be imported."
                    return
                }
                show(.editor(editor))
                reloadProjects()
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    func open(_ bundle: ProjectBundle) {
        guard !waitForRecovery({ self.open(bundle) }) else { return }
        switchScreen { [weak self] in self?.editorScreen(for: bundle) }
    }

    func editorScreen(for bundle: ProjectBundle) -> Screen? {
        do {
            let project = try bundle.load()
            openEditor?.close()
            NSDocumentController.shared.noteNewRecentDocumentURL(bundle.url)
            return .editor(EditorModel(bundle: bundle, project: project,
                                       openAt: ProjectPreviews.openingTime(for: bundle, project: project)))
        } catch {
            self.error = "Couldn't open “\(bundle.displayName)”: \(error.localizedDescription)"
            return nil
        }
    }

    // MARK: - Project files

    func openFiles(_ urls: [URL]) {
        guard let url = urls.first, !waitForRecovery({ self.openFiles(urls) }) else { return }
        guard openWindow != nil else {
            pendingFiles = urls
            return
        }
        guard recording == nil else {
            NSSound.beep()
            return
        }
        if launchedWithProject {
            launchedWithProject = false
            cancelSetup()
        }
        if let current = openEditor {
            if current.bundle.url.resolvingSymlinksInPath() == url.resolvingSymlinksInPath() {
                presentMainWindow()
                return
            }
            if current.exportJob?.isRunning == true {
                presentMainWindow()
                error = "Wait for the export to finish (or stop it) before opening another project."
                return
            }
        }
        let bundle: ProjectBundle
        do {
            let found = try ProjectBundle(opening: url)
            bundle = found.isWritable ? found : try found.copy()
        } catch {
            presentMainWindow()
            self.error = error.localizedDescription
            return
        }
        if let window = Self.mainWindow, window.isVisible, !window.isMiniaturized {
            open(bundle)
            window.makeKeyAndOrderFront(nil)
            NSApp.activate()
        } else if let next = editorScreen(for: bundle) {
            show(next, animated: false)
            presentMainWindow()
        } else {
            presentMainWindow()
        }
        reloadProjects()
    }

    private func openPendingFiles() {
        guard !pendingFiles.isEmpty, openWindow != nil else { return }
        let urls = pendingFiles
        pendingFiles = []
        Task { [weak self] in self?.openFiles(urls) }
    }

    func chooseProjectToOpen() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.sliceProject]
        panel.directoryURL = ProjectBundle.defaultDirectory
        panel.message = "Choose a Screen Recorder project to open."
        panel.prompt = "Open"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        openFiles([url])
    }

    func presentMainWindow() {
        NSApp.activate()
        guard let window = Self.mainWindow else {
            openWindow?(id: Self.mainWindowID)
            return
        }
        if window.isMiniaturized {
            window.deminiaturize(nil)
        } else {
            window.makeKeyAndOrderFront(nil)
        }
    }

    func startRecording(settings: Recorder.Settings, appendTo editor: EditorModel?) {
        let controller = RecordingController(settings: settings, editor: editor) { [weak self] result in
            guard let self else { return }
            phaseWatch?.cancel()
            phaseWatch = nil
            annotateWatch?.cancel()
            annotateWatch = nil
            annotating = nil
            setupAppendTo = nil
            Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(600))
                if self?.recording == nil { self?.recordingPhase = nil }
            }
            var problem = recording?.warning
            let hidden = recording?.hidden ?? []
            recording = nil
            switch result {
            case let .success(editor):
                if let editor {
                    editor.reloadAfterRecording()
                    show(.editor(editor), animated: false)
                } else {
                    show(.home, animated: false)
                }
            case let .failure(err):
                problem = err.localizedDescription
                show(editor.map { .editor($0) } ?? .home, animated: false)
            }
            reloadProjects()
            hidden.filter { $0 !== Self.mainWindow }.forEach { $0.orderFront(nil) }
            presentMainWindow()
            dismissWindow?(id: Self.captureBarID)
            if let problem {
                Task { [weak self] in
                    try? await Task.sleep(for: .milliseconds(700))
                    self?.error = problem
                }
            }
        }
        recording = controller
        phaseWatch = Task { [weak self] in
            for await phase in Observations({ controller.phase }) { self?.recordingPhase = phase }
        }
        annotating = nil
        let session = AnnotationController.shared.session
        annotateWatch = Task { [weak self] in
            for await active in Observations({ session.isActive }) { self?.annotating = active }
        }
        controller.start()
    }
}
