// ABOUTME: Seeds a newly created project directory with the default config templates.
// ABOUTME: Called only by the paths that create the directory, never the ones that adopt one.

import Foundation

extension Project {
    /// Every config file Atelier reads from the project directory.
    ///
    /// One entry per file, each a `Project.ConfigFile` declared beside the type
    /// that parses it — so the names, the template and the schema stay together
    /// and this list only has to know that a file exists. Held as
    /// `any ProjectConfigFile` because the four carry different contents and
    /// seeding cares about none of them.
    ///
    /// **This list is not the trust boundary and adding to it is not free.** A
    /// file named here is one Atelier reads from `Project.directory` and,
    /// for three of the four, runs commands out of unattended. See
    /// `Project.ConfigFile` for why that location is what makes it safe.
    static let configFiles: [any ProjectConfigFile] = [
        Verification.Config.configFile,
        Initialization.Config.configFile,
        ProcessCompose.PortsConfig.configFile,
        ProcessCompose.Config.configFile,
    ]

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
    ///
    /// **Whether a template's example is commented out is decided per file, not
    /// here.** The mechanism is uniform and the safety decision is not:
    /// verification's example check and execution's example process are
    /// uncommented on purpose, initialization's and ports' are commented on
    /// purpose, and each template's own doc comment says why. This loop must
    /// stay ignorant of that.
    static func seedDefaultConfigs(projectDirectory: String) {
        for file in configFiles {
            file.writeDefault(projectDirectory: projectDirectory)
        }
    }
}
