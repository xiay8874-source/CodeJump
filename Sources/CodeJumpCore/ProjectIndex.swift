import Foundation
import Darwin

public struct IndexedFile: Codable, Hashable, Sendable {
    public var projectID: UUID
    public var absolutePath: String
    public var relativePath: String
    public var filename: String
    public var stem: String

    public init(projectID: UUID, absolutePath: String, relativePath: String) {
        self.projectID = projectID
        self.absolutePath = absolutePath
        self.relativePath = relativePath
        self.filename = URL(fileURLWithPath: absolutePath).lastPathComponent
        self.stem = URL(fileURLWithPath: absolutePath).deletingPathExtension().lastPathComponent
    }
}

/// A portable snapshot. Build and refresh on a background queue, then atomically replace the snapshot.
public struct ProjectIndex: Codable, Sendable {
    public var projects: [ProjectRoot]
    public var files: [IndexedFile]

    public init(projects: [ProjectRoot], files: [IndexedFile]) {
        self.projects = projects
        self.files = files
    }

    public static let excludedDirectoryNames: Set<String> = [
        ".git", ".hg", ".svn", ".idea", ".vscode", ".build", ".swiftpm", ".gradle",
        "node_modules", "bower_components", "build", "target", "dist", "vendor", "DerivedData",
        "Pods", "Carthage", ".next", ".nuxt", ".cache", ".turbo", "coverage", "__pycache__",
        ".venv", "venv"
    ]
    private static let excludedExtensions: Set<String> = [
        "class", "jar", "war", "ear", "o", "a", "so", "dylib", "dll", "exe", "pyc", "pyo",
        "zip", "gz", "xz", "bz2", "7z", "rar", "tar", "dmg", "iso", "pdf", "png", "jpg",
        "jpeg", "gif", "webp", "heic", "ico", "icns", "mp3", "mp4", "mov", "wav", "ttf",
        "woff", "woff2", "eot", "DS_Store"
    ]

    public static func build(projects: [ProjectRoot]) throws -> ProjectIndex {
        var normalized = projects
        var files: [IndexedFile] = []
        for i in normalized.indices {
            normalized[i].path = canonicalPath(normalized[i].path)
            guard normalized[i].enabled else { continue }
            let root = URL(fileURLWithPath: normalized[i].path, isDirectory: true)
            let values = try root.resourceValues(forKeys: [.isDirectoryKey])
            guard values.isDirectory == true else {
                throw CocoaError(.fileReadUnsupportedScheme, userInfo: [NSFilePathErrorKey: root.path])
            }
            files.append(contentsOf: try scan(project: normalized[i], path: root.path))
        }
        return ProjectIndex(projects: normalized, files: sorted(files))
    }

    /// Filesystem events use the same project-relative rule as scanning. A project root may
    /// itself live below a directory such as build/ or .cache/; only components inside the
    /// deepest containing root count. Paths outside every root are kept for updating(paths:).
    public static func isIgnoredEvent(_ path: String, roots: [String]) -> Bool {
        let lexical = lexicalPath(path)
        guard let root = roots.map(lexicalPath).filter({ isWithin(lexical, directory: $0) })
                .max(by: { $0.count < $1.count }) else { return false }
        return isExcluded(lexical, root: root)
    }

    /// Refresh only the touched subtrees. Deleted directories remove all their indexed descendants.
    /// Coalesced parent events and events outside the imported roots do not trigger unrelated scans.
    public func updating(paths: [String]) throws -> ProjectIndex {
        let eventPaths = Set(paths.flatMap { path -> [String] in
            let lexical = lexicalPath(path)
            let url = URL(fileURLWithPath: lexical)
            // FSEvents normally reports canonical paths, but callers can use aliases such as
            // /var -> /private/var. Preserve the leaf too, so a replaced symlink invalidates
            // its old indexed location rather than only its new destination.
            let canonicalParent = URL(fileURLWithPath: canonicalPath(url.deletingLastPathComponent().path))
                .appendingPathComponent(url.lastPathComponent).path
            return [lexical, canonicalPath(path), canonicalParent]
        })
        guard !eventPaths.isEmpty else { return self }
        var result = files
        for project in projects where project.enabled {
            let root = lexicalPath(project.path)
            var touched: [String] = []
            for event in eventPaths {
                if isWithin(root, directory: event) { touched.append(root) }
                else if isWithin(event, directory: root), !isExcluded(event, root: root) { touched.append(event) }
            }
            // Keeping parents before descendants lets us collapse a burst to its minimal subtrees.
            touched.sort { $0.count < $1.count }
            var minimal: [String] = []
            for path in touched where !minimal.contains(where: { isWithin(path, directory: $0) }) {
                minimal.append(path)
            }
            guard !minimal.isEmpty else { continue }
            result.removeAll { file in
                file.projectID == project.id && minimal.contains { isWithin(file.absolutePath, directory: $0) }
            }
            for path in minimal {
                result.append(contentsOf: try Self.scan(project: project, path: path))
            }
        }
        return ProjectIndex(projects: projects, files: Self.sorted(result))
    }

    private static func sorted(_ files: [IndexedFile]) -> [IndexedFile] {
        files.sorted {
            if $0.absolutePath == $1.absolutePath { return $0.projectID.uuidString < $1.projectID.uuidString }
            return $0.absolutePath < $1.absolutePath
        }
    }

    private static func scan(project: ProjectRoot, path: String) throws -> [IndexedFile] {
        let root = project.path
        let url = URL(fileURLWithPath: path)
        guard isWithin(path, directory: root), !isExcluded(path, root: root),
              !hasSymlinkComponent(path, root: root) else { return [] }
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey]
        let initial: URLResourceValues
        do { initial = try url.resourceValues(forKeys: keys) }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile {
            return []
        }
        guard initial.isSymbolicLink != true else { return [] }
        if initial.isRegularFile == true {
            return shouldIndex(url) ? [indexed(url, project: project)] : []
        }
        guard initial.isDirectory == true else { return [] }
        var scanError: Error?
        guard let enumerator = FileManager.default.enumerator(
            at: url, includingPropertiesForKeys: Array(keys), options: [],
            errorHandler: { _, error in scanError = error; return false }
        ) else { return [] }
        var result: [IndexedFile] = []
        for case let child as URL in enumerator {
            let values = try child.resourceValues(forKeys: keys)
            if values.isSymbolicLink == true {
                enumerator.skipDescendants()
                continue
            }
            if values.isDirectory == true {
                if excludedDirectoryNames.contains(child.lastPathComponent) || child.lastPathComponent.hasPrefix(".") {
                    enumerator.skipDescendants()
                }
            } else if values.isRegularFile == true, shouldIndex(child) {
                result.append(indexed(child, project: project))
            }
        }
        if let scanError { throw scanError }
        return result
    }

    private static func indexed(_ url: URL, project: ProjectRoot) -> IndexedFile {
        IndexedFile(projectID: project.id, absolutePath: url.path,
                    relativePath: String(url.path.dropFirst(project.path.count + (project.path == "/" ? 0 : 1))))
    }

    private static func shouldIndex(_ url: URL) -> Bool {
        !url.lastPathComponent.hasPrefix(".") && !excludedExtensions.contains(url.pathExtension.lowercased())
    }
}

func lexicalPath(_ path: String) -> String {
    let expanded = (path as NSString).expandingTildeInPath
    let absolute = expanded.hasPrefix("/") ? expanded : FileManager.default.currentDirectoryPath + "/" + expanded
    var components: [Substring] = []
    for part in absolute.split(separator: "/") {
        if part == "." { continue }
        if part == ".." { if !components.isEmpty { components.removeLast() }; continue }
        components.append(part)
    }
    return "/" + components.joined(separator: "/")
}

func canonicalPath(_ path: String) -> String {
    // Foundation deliberately abbreviates /private/var to /var on macOS, whereas its directory
    // enumerator returns /private/var. POSIX realpath supplies one consistent identity instead.
    var current = lexicalPath(path)
    var missing: [String] = []
    while true {
        if let resolved = realpath(current, nil) {
            defer { free(resolved) }
            let base = String(cString: resolved)
            return missing.isEmpty ? base : lexicalPath(base + "/" + missing.reversed().joined(separator: "/"))
        }
        guard current != "/" else { return lexicalPath(path) }
        let url = URL(fileURLWithPath: current)
        missing.append(url.lastPathComponent)
        current = url.deletingLastPathComponent().path
    }
}

func isWithin(_ path: String, directory: String) -> Bool {
    path == directory || path.hasPrefix(directory == "/" ? "/" : directory + "/")
}

private func isExcluded(_ path: String, root: String) -> Bool {
    guard path != root else { return false }
    let relative = String(path.dropFirst(root.count + (root == "/" ? 0 : 1)))
    return relative.split(separator: "/").contains {
        $0.hasPrefix(".") || ProjectIndex.excludedDirectoryNames.contains(String($0))
    }
}

private func hasSymlinkComponent(_ path: String, root: String) -> Bool {
    guard path != root else { return false }
    var current = URL(fileURLWithPath: root)
    let relative = String(path.dropFirst(root.count + (root == "/" ? 0 : 1)))
    for part in relative.split(separator: "/") {
        current.appendPathComponent(String(part))
        if (try? current.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true { return true }
    }
    return false
}
