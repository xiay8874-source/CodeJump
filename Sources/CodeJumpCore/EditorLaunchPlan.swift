import Foundation
import Darwin

public enum EditorKind: String, CaseIterable, Codable, Sendable {
    case idea, vscode, cursor, zed

    public var displayName: String {
        switch self {
        case .idea: return "IntelliJ IDEA"
        case .vscode: return "Visual Studio Code"
        case .cursor: return "Cursor"
        case .zed: return "Zed"
        }
    }
}

public enum EditorLaunchError: LocalizedError, Equatable, Sendable {
    case invalidPath(String)
    case projectNotFound(String)
    case projectRootChanged
    case fileNotFound(String)
    case fileOutsideProject
    case invalidPosition
    case invalidApplicationPath
    case editorNotFound(EditorKind)

    public var errorDescription: String? {
        switch self {
        case .invalidPath(let path): return "需要本机绝对路径：\(path)"
        case .projectNotFound(let path): return "项目目录不存在或不可读取：\(path)"
        case .projectRootChanged: return "项目目录的真实位置已变化或被符号链接替换，请检查后重新导入项目。"
        case .fileNotFound(let path): return "源文件不存在或不是普通文件：\(path)"
        case .fileOutsideProject: return "文件已移到项目范围之外，或符号链接指向了其他项目。请重新搜索。"
        case .invalidPosition: return "行号和列号必须是有效的正整数；指定列号时也需要行号。"
        case .invalidApplicationPath: return "请选择本机的编辑器 .app 应用。"
        case .editorNotFound(let editor): return "未找到 \(editor.displayName) 的启动程序，请在设置中选择它的 .app 应用。"
        }
    }
}

/// A launch plan contains an executable and separate arguments, never shell text.
/// Rebuild the plan immediately before Process.run() to revalidate a stale index hit.
public struct EditorLaunchPlan: Sendable {
    public var executable: String
    public var arguments: [String]

    public static func make(candidate: JumpCandidate, editor: EditorKind,
                            applicationPath: String? = nil) throws -> EditorLaunchPlan {
        let arguments = try makeArguments(candidate: candidate, editor: editor)
        let executable = try resolveExecutable(editor: editor, applicationPath: applicationPath)
        return EditorLaunchPlan(executable: executable, arguments: arguments)
    }

    /// Checks the filesystem without launching or discovering an application.
    public static func makeArguments(candidate: JumpCandidate, editor: EditorKind) throws -> [String] {
        if let line = candidate.line, line < 1 || line > Int(Int32.max) {
            throw EditorLaunchError.invalidPosition
        }
        if let column = candidate.column,
           candidate.line == nil || column < 1 || column > Int(Int32.max) {
            throw EditorLaunchError.invalidPosition
        }

        let root = try canonicalURL(candidate.project.path, isProject: true)
        // Imported roots are already POSIX-canonical. Pin that identity rather
        // than letting root and file both follow a newly substituted root symlink.
        guard root.path == candidate.project.path else {
            throw EditorLaunchError.projectRootChanged
        }
        let file = try canonicalURL(candidate.absolutePath)
        guard (try? root.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
            throw EditorLaunchError.projectNotFound(candidate.project.path)
        }
        // Compare components, not string prefixes: /repo-copy is not inside /repo.
        let rootParts = root.pathComponents
        let fileParts = file.pathComponents
        guard fileParts.count > rootParts.count,
              fileParts.starts(with: rootParts) else {
            throw EditorLaunchError.fileOutsideProject
        }
        guard (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else {
            throw EditorLaunchError.fileNotFound(candidate.absolutePath)
        }

        switch editor {
        case .idea:
            // JetBrains CommandLineProcessor parses and opens paths sequentially.
            // Opening the root before the file prevents LightEdit for a closed project.
            // https://github.com/JetBrains/intellij-community/blob/master/platform/platform-impl/src/com/intellij/ide/CommandLineProcessor.kt
            var arguments = [root.path]
            if let line = candidate.line { arguments += ["--line", String(line)] }
            // IDEA's CLI column is passed directly to the zero-based OpenFileDescriptor.
            if let column = candidate.column { arguments += ["--column", String(column - 1)] }
            arguments.append(file.path)
            return arguments
        case .vscode, .cursor:
            // Do not use --reuse-window: it targets the last active window, which
            // may belong to a different project. An explicit folder scopes the open.
            // https://code.visualstudio.com/docs/configure/command-line
            guard candidate.line != nil else { return [root.path, file.path] }
            return [root.path, "--goto", location(file: file.path, candidate: candidate)]
        case .zed:
            // https://zed.dev/docs/reference/cli
            return [root.path, location(file: file.path, candidate: candidate)]
        }
    }

    private static func location(file: String, candidate: JumpCandidate) -> String {
        guard let line = candidate.line else { return file }
        if let column = candidate.column { return "\(file):\(line):\(column)" }
        return "\(file):\(line)"
    }

    private static func canonicalURL(_ path: String, isProject: Bool = false) throws -> URL {
        guard path.hasPrefix("/"), !path.contains("\0"), !path.contains("\n"), !path.contains("\r") else {
            throw EditorLaunchError.invalidPath(path)
        }
        // realpath resolves symlinks before subsequent ".." components, matching
        // the filesystem. Lexically standardizing first can select a different file.
        guard let resolved = path.withCString({ realpath($0, nil) }) else {
            throw isProject ? EditorLaunchError.projectNotFound(path) : EditorLaunchError.fileNotFound(path)
        }
        defer { free(resolved) }
        return URL(fileURLWithPath: String(cString: resolved))
    }

    static func resolveExecutable(editor: EditorKind, applicationPath: String? = nil,
                                  homeDirectory: String = FileManager.default.homeDirectoryForCurrentUser.path,
                                  isExecutable: (String) -> Bool = { path in
                                      let file = URL(fileURLWithPath: path).resolvingSymlinksInPath()
                                      return FileManager.default.isExecutableFile(atPath: path)
                                          && (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
                                  }) throws -> String {
        let candidates = try executableCandidates(editor: editor, applicationPath: applicationPath,
                                                   homeDirectory: homeDirectory)
        guard let executable = candidates.first(where: isExecutable) else {
            throw EditorLaunchError.editorNotFound(editor)
        }
        return executable
    }

    static func executableCandidates(editor: EditorKind, applicationPath: String?, homeDirectory: String) throws -> [String] {
        let appNames: [String]
        let relativeExecutable: String
        switch editor {
        case .idea:
            appNames = ["IntelliJ IDEA.app", "IntelliJ IDEA CE.app", "IntelliJ IDEA Ultimate.app", "IDEA.app"]
            relativeExecutable = "Contents/MacOS/idea"
        case .vscode:
            appNames = ["Visual Studio Code.app"]
            relativeExecutable = "Contents/Resources/app/bin/code"
        case .cursor:
            appNames = ["Cursor.app"]
            relativeExecutable = "Contents/Resources/app/bin/cursor"
        case .zed:
            appNames = ["Zed.app", "Zed Preview.app"]
            relativeExecutable = "Contents/MacOS/cli"
        }
        let appPaths: [String]
        if let applicationPath {
            guard applicationPath.hasPrefix("/"),
                  !applicationPath.contains("\0"), !applicationPath.contains("\n"), !applicationPath.contains("\r"),
                  URL(fileURLWithPath: applicationPath).pathExtension.lowercased() == "app" else {
                throw EditorLaunchError.invalidApplicationPath
            }
            // An explicitly chosen app must never silently fall back to another app.
            appPaths = [applicationPath]
        } else {
            appPaths = ["/Applications", homeDirectory + "/Applications"].flatMap { directory in
                appNames.map { directory + "/" + $0 }
            }
        }
        return appPaths.map { URL(fileURLWithPath: $0).appendingPathComponent(relativeExecutable).standardizedFileURL.path }
    }
}
