//
//  RenderState.swift
//  SliceCore
//
//  Created by rit3zh CX on 10/8/26.
//

import CoreImage
import Foundation
import Synchronization

/// What the compositor and preview render from, shared between the editor and their render threads.
public final class RenderState: Sendable {
    private struct State {
        var project: Project
        var cursor: CursorTrack
        var options = FrameRenderer.Options()
        var sceneCache: (size: CGSize, scene: RenderScene)?
    }

    private let state: Mutex<State>

    public init(project: Project, cursor: CursorTrack) {
        state = Mutex(State(project: project, cursor: cursor))
    }

    public func current() -> (project: Project, cursor: CursorTrack, options: FrameRenderer.Options) {
        state.withLock { ($0.project, $0.cursor, $0.options) }
    }

    public func update(project: Project, cursor: CursorTrack? = nil) {
        state.withLock {
            $0.project = project
            if let cursor { $0.cursor = cursor }
            $0.sceneCache = nil
        }
    }

    /// New options; the background image stays, as it's only replaced through `update(backgroundImage:)`.
    public func update(options: FrameRenderer.Options) {
        state.withLock {
            let background = $0.options.backgroundImage
            $0.options = options
            $0.options.backgroundImage = background
        }
    }

    public func update(backgroundImage: CIImage?) {
        state.withLock { $0.options.backgroundImage = backgroundImage }
    }

    public func snapshot(size: CGSize) -> (RenderScene, FrameRenderer.Options) {
        state.withLock {
            if let c = $0.sceneCache, c.size == size { return (c.scene, $0.options) }
            let scene = RenderScene(project: $0.project, output: size, cursor: $0.cursor)
            $0.sceneCache = (size, scene)
            return (scene, $0.options)
        }
    }
}
