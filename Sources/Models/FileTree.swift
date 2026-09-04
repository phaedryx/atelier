// ABOUTME: FileNode tree model with lazy directory loading (children loaded on expand).
// ABOUTME: DirectoryWatcher uses FSEventStream for real-time recursive file system monitoring.

import Foundation

// MARK: - FileNode

struct FileNode: Identifiable {
    let id: String // relative path from worktree root (empty string for root)
    let name: String // last path component
    let isDirectory: Bool
    var children: [FileNode]? // nil = not yet loaded (lazy), [] = loaded but empty

    /// Whether this directory's children have been loaded.
    var isLoaded: Bool {
        children != nil
    }

    /// Build a shallow tree (root level only). Directory children are nil (lazy).
    static func buildShallowTree(rootPath: String) -> [FileNode] {
        buildShallowChildren(at: rootPath, relativeTo: rootPath) ?? []
    }

    /// Load immediate children of a single directory. Directories get children = nil (lazy).
    static func loadChildren(atRelativePath relativePath: String, rootPath: String) -> [FileNode] {
        let dirPath = relativePath.isEmpty
            ? rootPath
            : (rootPath as NSString).appendingPathComponent(relativePath)
        return buildShallowChildren(at: dirPath, relativeTo: rootPath) ?? []
    }

    /// Insert loaded children at a specific path in the tree, returning the updated tree.
    static func insertChildren(_ children: [FileNode], atPath path: String, in nodes: [FileNode]) -> [FileNode] {
        nodes.map { node in
            if node.id == path, node.isDirectory {
                return FileNode(id: node.id, name: node.name, isDirectory: true, children: children)
            } else if node.isDirectory, let nodeChildren = node.children, path.hasPrefix(node.id + "/") {
                let updatedChildren = insertChildren(children, atPath: path, in: nodeChildren)
                return FileNode(id: node.id, name: node.name, isDirectory: true, children: updatedChildren)
            }
            return node
        }
    }

    /// Ensure all ancestor directories for a file path are loaded. Returns the updated tree.
    static func ensureAncestorsLoaded(for filePath: String, in nodes: [FileNode], rootPath: String) -> [FileNode] {
        let components = filePath.split(separator: "/").map(String.init)
        guard components.count > 1 else { return nodes }

        var result = nodes
        var current = ""
        for component in components.dropLast() {
            current = current.isEmpty ? component : current + "/" + component
            if let node = findNode(atPath: current, in: result), node.isDirectory, !node.isLoaded {
                let children = loadChildren(atRelativePath: current, rootPath: rootPath)
                result = insertChildren(children, atPath: current, in: result)
            }
        }
        return result
    }

    /// Refresh all previously-loaded nodes, preserving lazy structure for unloaded directories.
    static func refreshLoadedNodes(in nodes: [FileNode], rootPath: String) -> [FileNode] {
        // A root that cannot be read right now is not an empty root; keeping what
        // is already on screen is the honest answer.
        guard let freshRoot = buildShallowChildren(at: rootPath, relativeTo: rootPath) else {
            return nodes
        }
        return mergeNodes(fresh: freshRoot, existing: nodes, rootPath: rootPath)
    }

    // MARK: - Lookup

    static func findNode(atPath path: String, in nodes: [FileNode]) -> FileNode? {
        for node in nodes {
            if node.id == path {
                return node
            }
            if node.isDirectory, let children = node.children, path.hasPrefix(node.id + "/") {
                if let found = findNode(atPath: path, in: children) {
                    return found
                }
            }
        }
        return nil
    }

    /// Immediate children of one directory, or **nil when the directory could not
    /// be read** — permission denied, or a path that blinked out from under a
    /// background refresh. The two used to answer the same `[]`, and `mergeNodes`
    /// mapped that straight onto the node, so one transient failure collapsed a
    /// subtree the user had expanded. Absent is not empty.
    private static func buildShallowChildren(at directoryPath: String, relativeTo rootPath: String) -> [FileNode]? {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(atPath: directoryPath) else {
            return nil
        }

        var dirs: [FileNode] = []
        var files: [FileNode] = []

        for entry in entries {
            if entry == ".git" {
                continue
            }

            let fullPath = (directoryPath as NSString).appendingPathComponent(entry)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: fullPath, isDirectory: &isDir) else { continue }

            let relativePath = if rootPath.hasSuffix("/") {
                String(fullPath.dropFirst(rootPath.count))
            } else {
                String(fullPath.dropFirst(rootPath.count + 1))
            }

            if isDir.boolValue {
                dirs.append(FileNode(id: relativePath, name: entry, isDirectory: true, children: nil))
            } else {
                files.append(FileNode(id: relativePath, name: entry, isDirectory: false, children: []))
            }
        }

        dirs.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        files.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

        return dirs + files
    }

    /// Merge fresh shallow nodes with existing tree, preserving loaded children.
    private static func mergeNodes(fresh: [FileNode], existing: [FileNode], rootPath: String) -> [FileNode] {
        let existingByID = Dictionary(existing.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })

        return fresh.map { freshNode in
            if freshNode.isDirectory,
               let existingNode = existingByID[freshNode.id],
               existingNode.isLoaded
            {
                // Previously loaded — refresh its children recursively. A read
                // that fails leaves the loaded subtree exactly as it was.
                let dirPath = (rootPath as NSString).appendingPathComponent(freshNode.id)
                guard let freshChildren = buildShallowChildren(at: dirPath, relativeTo: rootPath) else {
                    return existingNode
                }
                let mergedChildren = mergeNodes(
                    fresh: freshChildren,
                    existing: existingNode.children ?? [],
                    rootPath: rootPath
                )
                return FileNode(id: freshNode.id, name: freshNode.name, isDirectory: true, children: mergedChildren)
            } else {
                return freshNode
            }
        }
    }
}

// MARK: - DirectoryWatcher

/// Watches a directory tree for changes using macOS FSEventStream.
/// Calls `onChange` on the main thread when files are created, deleted, or renamed.
final class DirectoryWatcher: @unchecked Sendable {
    /// What the FSEvents context points at.
    ///
    /// Not `self`: the context holds a raw pointer, the stream can have a
    /// callback already in flight when the watcher is released — from any
    /// thread, since nothing pins this type to one — and
    /// `Unmanaged.passUnretained(self)` gave that callback a dangling pointer to
    /// resurrect. The stream owns this box instead (retained into the context,
    /// released by the context's own release callback), so it outlives the
    /// watcher, and `disarm()` is what makes a stopped watcher silent.
    private final class Callback: @unchecked Sendable {
        private let lock = NSLock()
        private var onChange: (() -> Void)?

        init(_ onChange: @escaping () -> Void) {
            self.onChange = onChange
        }

        func disarm() {
            lock.lock()
            onChange = nil
            lock.unlock()
        }

        /// Read on the main queue, not at the FSEvents callback: a `stop()` that
        /// lands between the two then suppresses the hop that is already queued.
        func fire() {
            DispatchQueue.main.async { [self] in
                lock.lock()
                let handler = onChange
                lock.unlock()
                handler?()
            }
        }
    }

    private let lock = NSLock()
    private var stream: FSEventStreamRef?
    private let callbackBox: Callback

    init(path: String, onChange: @escaping () -> Void) {
        let box = Callback(onChange)
        callbackBox = box

        let pathsToWatch = [path] as CFArray
        var context = FSEventStreamContext()
        context.info = Unmanaged.passRetained(box).toOpaque()
        context.release = { pointer in
            guard let pointer else { return }
            Unmanaged<Callback>.fromOpaque(pointer).release()
        }

        let flags = UInt32(
            kFSEventStreamCreateFlagUseCFTypes |
                kFSEventStreamCreateFlagFileEvents |
                kFSEventStreamCreateFlagNoDefer
        )

        guard let stream = FSEventStreamCreate(
            nil,
            DirectoryWatcher.callback,
            &context,
            pathsToWatch,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            1.0, // 1 second coalescing latency
            FSEventStreamCreateFlags(flags)
        ) else {
            // No stream means nothing will ever call the context's release, so
            // the retain above is ours to undo.
            if let info = context.info {
                Unmanaged<Callback>.fromOpaque(info).release()
            }
            return
        }

        self.stream = stream
        FSEventStreamScheduleWithRunLoop(stream, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        FSEventStreamStart(stream)
    }

    func stop() {
        callbackBox.disarm()
        lock.lock()
        let stream = stream
        self.stream = nil
        lock.unlock()
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
    }

    deinit {
        stop()
    }

    private static let callback: FSEventStreamCallback = {
        _, clientCallBackInfo, _, _, _, _ in
        guard let info = clientCallBackInfo else { return }
        Unmanaged<Callback>.fromOpaque(info).takeUnretainedValue().fire()
    }
}
