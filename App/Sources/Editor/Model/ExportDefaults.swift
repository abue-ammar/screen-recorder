//
//  ExportDefaults.swift
//  Slice
//
//  Created by rit3zh CX on 11/12/26.
//

import Foundation
import SliceCore

/// The settings the last video was exported with, which new projects start from.
enum ExportDefaults {
    private static let key = "export.lastSettings"

    static var last: ExportSettings? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(ExportSettings.self, from: data)
    }

    static func remember(_ settings: ExportSettings) {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }

    /// A new, empty project that exports as the last export did.
    static func newProject(name: String) throws -> (ProjectBundle, Project) {
        var (bundle, project) = try ProjectBundle.create(name: name)
        guard let last else { return (bundle, project) }
        project.export = last
        try bundle.save(project)
        return (bundle, project)
    }
}
