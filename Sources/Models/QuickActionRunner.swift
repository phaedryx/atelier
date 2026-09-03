// ABOUTME: Spawns one-shot coding-agent subprocesses or git/gh commands for quick actions.
// ABOUTME: Forks from the active session for context-aware tasks like PR creation.

import Foundation
import os

private let logger = Logger(subsystem: "atelier", category: "quick-action")

enum QuickAction: String, CaseIterable, Identifiable {
    case commit
    case push
    case createPR
    case closePR

    var id: String {
        rawValue
    }

    var label: String {
        switch self {
        case .commit: NSLocalizedString("Commit", comment: "")
        case .push: NSLocalizedString("Push", comment: "")
        case .createPR: NSLocalizedString("Create PR", comment: "")
        case .closePR: NSLocalizedString("Close PR", comment: "")
        }
    }

    var icon: String {
        switch self {
        case .commit: "checkmark.circle"
        case .push: "arrow.up"
        case .createPR: "arrow.triangle.pull"
        case .closePR: "xmark.circle"
        }
    }

    /// Whether this action requires claude -p (vs direct git/gh command).
    var usesLLM: Bool {
        switch self {
        case .commit, .createPR: true
        case .push, .closePR: false
        }
    }

    var requiresGitHubRemote: Bool {
        switch self {
        case .createPR, .closePR: true
        case .commit, .push: false
        }
    }

    var prompt: String? {
        switch self {
        case .commit:
            "Stage and commit all changes in the working tree with a good commit message based on the changes. Do not push."
        case .createPR:
            "Create a pull request for the current changes. Write a clear title and description based on what we've been working on."
        case .push, .closePR:
            nil
        }
    }
}

extension QuickAction {
    enum State: Equatable {
        case idle
        case running(QuickAction)
        case succeeded(QuickAction)
        case failed(QuickAction)
    }
}

extension QuickAction {
    struct LogEntry: Identifiable {
        let id = UUID()
        let timestamp: Date
        let action: QuickAction
        let command: String
        var output: String
        var exitCode: Int32?
    }
}

extension QuickAction {
    @MainActor
    final class Runner: ObservableObject {
        @Published var state: QuickAction.State = .idle
        @Published var log: [QuickAction.LogEntry] = []
        var onSuccess: ((QuickAction) -> Void)?
        private var runningProcess: Process?
        private var dismissWork: DispatchWorkItem?

        func run(
            action: QuickAction,
            claudePath: String?,
            ghPath: String?,
            workingDirectory: String,
            branchName: String? = nil
        ) {
            guard case .idle = state else { return }

            state = .running(action)
            dismissWork?.cancel()

            switch action {
            case .commit, .createPR:
                guard let claudePath else { return }
                runClaudeAction(action: action, claudePath: claudePath, workingDirectory: workingDirectory)
            case .push:
                runPush(workingDirectory: workingDirectory)
            case .closePR:
                guard let ghPath, let branchName else { return }
                runClosePR(ghPath: ghPath, branchName: branchName, workingDirectory: workingDirectory)
            }
        }

        private func runClaudeAction(action: QuickAction, claudePath: String, workingDirectory: String) {
            guard let prompt = action.prompt else { return }

            var args: [String] = []
            args.append(claudePath)
            args.append("-p")
            args.append(CommandBuilder.shellQuote(prompt))
            args.append("--output-format")
            args.append("json")
            args.append("--continue")
            args.append("--fork-session")
            args.append("--no-session-persistence")
            args.append("--dangerously-skip-permissions")

            let innerCommand = args.joined(separator: " ")
            let shell = CommandBuilder.userShell
            runShellCommand(action: action, shell: shell, arguments: ["-lic", innerCommand], workingDirectory: workingDirectory)
        }

        private func runPush(workingDirectory: String) {
            let dir = workingDirectory
            let actionRaw = QuickAction.push.rawValue
            let command = "git push -u origin HEAD"

            appendLog(action: .push, command: command)
            logger.info("Quick action \(actionRaw) starting in \(dir)")

            Task.detached {
                let result = Git.Operations.pushCurrentBranch(at: dir)
                await MainActor.run {
                    self.updateLog(output: result.output, exitCode: result.success ? 0 : 1)
                    self.runningProcess = nil
                    self.state = result.success ? .succeeded(.push) : .failed(.push)
                    if result.success {
                        self.onSuccess?(.push)
                    }
                    self.scheduleDismiss()
                }
            }
        }

        private func runClosePR(ghPath: String, branchName: String, workingDirectory: String) {
            let command = "\(ghPath) pr close \(branchName) --comment 'Closed from Atelier'"

            appendLog(action: .closePR, command: command)
            logger.info("Quick action closePR starting in \(workingDirectory)")

            let dir = workingDirectory
            let path = ghPath
            let branch = branchName
            Task.detached {
                // Bounded, unlike `runShellCommand` below: this one never registers a
                // `runningProcess`, so `cancel()` cannot reach it and a stalled `gh`
                // would leave the action spinning forever.
                let success: Bool
                let output: String
                if let result = ProcessRunner.capture(
                    executable: path,
                    arguments: ["pr", "close", branch, "--comment", "Closed from Atelier"],
                    currentDirectory: URL(fileURLWithPath: dir),
                    timeout: ProcessRunner.Timeout.network
                ) {
                    output = [result.stdoutText, result.stderrText]
                        .filter { !$0.isEmpty }
                        .joined(separator: "\n")
                    success = result.isSuccess
                } else {
                    output = "gh pr close did not finish in time"
                    success = false
                }
                await MainActor.run {
                    self.updateLog(output: output, exitCode: success ? 0 : 1)
                    self.runningProcess = nil
                    self.state = success ? .succeeded(.closePR) : .failed(.closePR)
                    if success {
                        self.onSuccess?(.closePR)
                    }
                    self.scheduleDismiss()
                }
            }
        }

        private func runShellCommand(
            action: QuickAction,
            shell: String,
            arguments: [String],
            workingDirectory: String
        ) {
            let fullCommand = "\(shell) \(arguments.joined(separator: " "))"
            let entryID = appendLog(action: action, command: fullCommand)
            let actionRaw = action.rawValue
            let dir = workingDirectory

            logger.info("Quick action \(actionRaw) starting in \(dir)")
            logger.info("Command: \(fullCommand)")

            // Deliberately not `ProcessRunner`: this runs the user's own command,
            // which has no honest deadline, and it registers `runningProcess` so
            // `cancel()` can stop it — cancellation the user drives beats a guess.
            Task.detached {
                let process = Process()
                let pipe = Pipe()
                process.executableURL = URL(fileURLWithPath: shell)
                process.arguments = arguments
                process.currentDirectoryURL = URL(fileURLWithPath: dir)
                process.standardOutput = pipe
                process.standardError = pipe

                let success: Bool
                let output: String
                do {
                    try process.run()
                    await MainActor.run { self.runningProcess = process }
                    // Drain the pipe while the child is still running. stdout and
                    // stderr share one pipe, so waiting on exit first deadlocks as
                    // soon as the child outgrows the ~64KB buffer — reachable for
                    // `claude -p --output-format json` on a large diff, since the
                    // JSON embeds the whole assistant reply.
                    let handle = pipe.fileHandleForReading
                    let reader = Task.detached { handle.readDataToEndOfFile() }
                    process.waitUntilExit()
                    let data = await reader.value
                    output = String(data: data, encoding: .utf8) ?? ""
                    success = Self.parseSuccess(output: output, exitCode: process.terminationStatus)
                } catch {
                    output = "Failed to launch: \(error.localizedDescription)"
                    success = false
                }

                let exitCode = process.terminationStatus
                await MainActor.run {
                    if let idx = self.log.firstIndex(where: { $0.id == entryID }) {
                        self.log[idx].output = output
                        self.log[idx].exitCode = exitCode
                    }
                    self.runningProcess = nil
                    self.state = success ? .succeeded(action) : .failed(action)
                    if success {
                        self.onSuccess?(action)
                    }
                    self.scheduleDismiss()
                }
            }
        }

        @discardableResult
        private func appendLog(action: QuickAction, command: String) -> UUID {
            let entry = QuickAction.LogEntry(
                timestamp: Date(),
                action: action,
                command: command,
                output: ""
            )
            log.append(entry)
            return entry.id
        }

        private func updateLog(output: String, exitCode: Int32) {
            guard let idx = log.indices.last else { return }
            log[idx].output = output
            log[idx].exitCode = exitCode
        }

        func cancel() {
            runningProcess?.terminate()
            runningProcess = nil
            state = .idle
        }

        func clearLog() {
            log.removeAll()
        }

        private nonisolated static func parseSuccess(output: String, exitCode: Int32) -> Bool {
            guard exitCode == 0 else { return false }
            guard let data = output.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else {
                return true
            }
            let isError = json["is_error"] as? Bool ?? false
            return !isError
        }

        private func scheduleDismiss() {
            dismissWork?.cancel()
            let work = DispatchWorkItem { [weak self] in
                self?.state = .idle
            }
            dismissWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: work)
        }
    }
}
