// ABOUTME: Seeds a newly created project directory with the default config templates.
// ABOUTME: Called only by the paths that create the directory, never the ones that adopt one.

import Foundation

extension Project {
    /// Seed a newly created project with one template per config file the app
    /// reads from the project directory.
    ///
    /// Called only by the two paths that *create* the project directory — a new
    /// empty project and a fresh clone — and never by the paths that adopt a
    /// directory the user already had, which would drop untracked files into a
    /// repository they merely registered.
    ///
    /// Each writer skips itself when its file already exists, so seeding is per
    /// file rather than all-or-nothing: a project that already carries its own
    /// ports.yml still gains the templates it lacks.
    static func seedDefaultConfigs(projectDirectory: String) {
        Verification.Config.writeDefault(projectDirectory: projectDirectory)
        Initialization.Config.writeDefault(projectDirectory: projectDirectory)
        ProcessCompose.PortsConfig.writeDefault(projectDirectory: projectDirectory)
        ProcessCompose.Config.writeDefault(projectDirectory: projectDirectory)
    }
}
