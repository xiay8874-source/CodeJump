import Foundation

public enum ImportHint {
    /// An absolute reference to an existing file outside every enabled project usually means
    /// a new git worktree has not been imported yet. Returns the nearest enclosing repository
    /// root (a directory containing a .git file or folder) so feedback can name the folder to add.
    public static func missingProjectRoot(for references: [CodeReference], projects: [ProjectRoot]) -> String? {
        let roots = projects.filter(\.enabled).map { canonicalPath($0.path) }
        for reference in references {
            guard let path = reference.path, path.hasPrefix("/") || path.hasPrefix("~/") else { continue }
            let file = canonicalPath(path)
            guard (try? URL(fileURLWithPath: file).resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true,
                  !roots.contains(where: { isWithin(file, directory: $0) }) else { continue }
            var directory = URL(fileURLWithPath: file).deletingLastPathComponent()
            while directory.path != "/" {
                if FileManager.default.fileExists(atPath: directory.appendingPathComponent(".git").path) {
                    return directory.path
                }
                directory.deleteLastPathComponent()
            }
        }
        return nil
    }
}
