import Foundation

/// Immutable lookup tables make resolution proportional to the number of matching filenames,
/// rather than to the size of all imported repositories.
public struct CodeResolver: Sendable {
    private let projects: [UUID: ProjectRoot]
    private let byAbsolutePath: [String: [IndexedFile]]
    private let byFilename: [String: [IndexedFile]]
    private let byStem: [String: [IndexedFile]]
    public static let maximumInspectedFiles = 64
    public static let maximumSourceBytes = 2 * 1_024 * 1_024

    public init(index: ProjectIndex) {
        var projects: [UUID: ProjectRoot] = [:]
        for project in index.projects where project.enabled { projects[project.id] = project }
        self.projects = projects
        let files = index.files.filter { projects[$0.projectID] != nil }
        self.byAbsolutePath = Dictionary(grouping: files, by: \.absolutePath)
        self.byFilename = Dictionary(grouping: files, by: \.filename)
        self.byStem = Dictionary(grouping: files, by: \.stem)
    }

    public func resolve(_ reference: CodeReference) -> [JumpCandidate] {
        let target = Target(reference)
        guard let path = target.path, !path.isEmpty else { return [] }
        let files = matchingFiles(path: path, projectHint: reference.projectHint)
        var candidates: [JumpCandidate] = []
        for (offset, file) in files.enumerated() {
            guard let project = projects[file.projectID] else { continue }
            let canonical = canonicalPath(file.absolutePath)
            // Recheck the boundary and existence at use time: a cached directory may have been
            // replaced with a symlink since the last filesystem notification.
            guard canonical == lexicalPath(file.absolutePath),
                  isWithin(canonical, directory: lexicalPath(project.path)),
                  (try? URL(fileURLWithPath: canonical).resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
            else { continue }
            var candidate = JumpCandidate(project: project, absolutePath: canonical,
                                          relativePath: file.relativePath, line: reference.line,
                                          column: reference.column, symbol: target.symbol)
            if reference.contextAmbiguous {
                candidate.require("链接目标与附近标注不一致，请核对打开位置")
            }
            if let owner = target.owner, owner != file.stem {
                candidate.require("引用类名 \(owner) 与目标文件 \(file.filename) 不同；请确认是否为内部类或链接目标有误")
            }
            if let revision = reference.revision, !revision.isEmpty {
                candidate.require("引用版本为 \(revision)；将打开当前工作区文件，并非历史版本")
            }
            if target.symbol == nil, reference.line == nil {
                if reference.column != nil { candidate.require("未提供行号，无法核对列号"); candidate.column = nil }
                candidates.append(candidate)
                continue
            }
            guard offset < Self.maximumInspectedFiles else {
                candidate.require("同名候选过多，尚未核对源码位置；请缩小项目范围")
                // A location that was not verified must not be presented as an exact jump.
                candidate.line = nil; candidate.column = nil
                candidates.append(candidate)
                continue
            }
            let source: String
            do { source = try readSource(canonical) }
            catch {
                candidate.require("无法核对源码位置（\(error.localizedDescription)）；确认后仅打开文件")
                candidate.line = nil; candidate.column = nil
                candidates.append(candidate)
                continue
            }
            if let symbol = target.symbol {
                guard URL(fileURLWithPath: canonical).pathExtension.lowercased() == "java" else {
                    candidate.require("此语言尚不支持方法声明定位；确认后仅打开文件")
                    candidate.line = nil; candidate.column = nil
                    candidates.append(candidate)
                    continue
                }
                let declarations = JavaDeclarations.find(symbol: symbol, source: source)
                if declarations.isEmpty {
                    candidate.require("未找到 \(symbol) 的 Java 方法声明；确认后仅打开文件")
                    candidate.line = nil; candidate.column = nil
                    candidates.append(candidate)
                } else {
                    for declaration in declarations {
                        var match = candidate
                        match.line = declaration.line
                        match.column = nil
                        if let requested = reference.line {
                            let lastRequested = reference.endLine ?? requested
                            if (declaration.startLine...declaration.endLine).contains(requested),
                               lastRequested >= requested, lastRequested <= declaration.endLine {
                                // A reference can legitimately point into a method body, rather
                                // than only to the name on its declaration line.
                                match.line = requested
                                match.column = reference.column
                                validateLocation(reference, source: source, candidate: &match)
                                match.appendReason("已核对 Java 方法范围：\(declaration.signature)")
                            } else {
                                let original = reference.endLine.map { "\(requested)-\($0)" } ?? String(requested)
                                match.require("引用第 \(original) 行不在 \(symbol) 的当前方法范围（\(declaration.startLine)-\(declaration.endLine) 行）；将打开当前声明第 \(declaration.line) 行")
                                match.appendReason("Java 方法声明：\(declaration.signature)")
                            }
                        } else {
                            match.appendReason("Java 方法声明：\(declaration.signature)")
                        }
                        if declarations.count > 1 { match.require("存在多个同名声明，请选择目标重载") }
                        candidates.append(match)
                    }
                }
            } else if reference.line != nil {
                validateLocation(reference, source: source, candidate: &candidate)
                candidates.append(candidate)
            }
        }
        var seen = Set<String>()
        return candidates.filter { seen.insert("\($0.project.id):\($0.id)").inserted }.sorted {
            if $0.project.name != $1.project.name { return $0.project.name < $1.project.name }
            if $0.absolutePath != $1.absolutePath { return $0.absolutePath < $1.absolutePath }
            return ($0.line ?? 0) < ($1.line ?? 0)
        }
    }

    private func matchingFiles(path: String, projectHint: String?) -> [IndexedFile] {
        let query = path.replacingOccurrences(of: "\\", with: "/")
        let eligible = projects.values.filter { project in
            guard let projectHint, !projectHint.isEmpty else { return true }
            return projectNames(project).contains(projectHint.lowercased())
        }
        let allowed = Set(eligible.map(\.id))
        guard !allowed.isEmpty else { return [] }
        if query.hasPrefix("/") || query.hasPrefix("~/") {
            let canonical = canonicalPath(query)
            return (byAbsolutePath[canonical] ?? []).filter { allowed.contains($0.projectID) }
        }
        var components = query.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        while components.first == "." { components.removeFirst() }
        guard !components.contains(".."), let basename = components.last,
              basename != "...", basename != "…" else { return [] }
        let pool = (byFilename[basename] ?? []) + (byStem[basename] ?? [])
        return pool.filter { file in
            guard allowed.contains(file.projectID), let project = projects[file.projectID] else { return false }
            var parts = components
            if parts.count > 1, projectNames(project).contains(parts[0].lowercased()) { parts.removeFirst() }
            let candidateParts = file.relativePath.split(separator: "/").map(String.init)
            return Self.matches(parts: parts, candidate: candidateParts, stem: file.stem)
        }
    }

    private func projectNames(_ project: ProjectRoot) -> Set<String> {
        Set(([project.name, URL(fileURLWithPath: project.path).lastPathComponent] + project.aliases).map { $0.lowercased() })
    }

    private static func matches(parts: [String], candidate: [String], stem: String) -> Bool {
        guard let last = parts.last, let filename = candidate.last,
              last == filename || last == stem else { return false }
        let pathParts = Array(parts.dropLast())
        let actual = Array(candidate.dropLast())
        guard !pathParts.isEmpty else { return true }
        // Ellipses stand for zero or more complete directory segments. All other segments must
        // be contiguous. Match backwards so the filename and final directories stay anchored.
        var p = pathParts.count - 1
        var a = actual.count - 1
        while p >= 0 {
            if pathParts[p] == "..." || pathParts[p] == "…" {
                while p >= 0 && (pathParts[p] == "..." || pathParts[p] == "…") { p -= 1 }
                if p < 0 { return true }
                // Try every occurrence rather than greedily choosing the last repeated segment.
                for end in stride(from: a, through: 0, by: -1) where actual[end] == pathParts[p] {
                    let remaining = Array(pathParts[...p]) + [filename]
                    let prefix = Array(actual[...end]) + [filename]
                    if matches(parts: remaining, candidate: prefix, stem: stem) { return true }
                }
                return false
            }
            guard a >= 0, actual[a] == pathParts[p] else { return false }
            p -= 1; a -= 1
        }
        return true
    }

    private func readSource(_ path: String) throws -> String {
        let url = URL(fileURLWithPath: path)
        let values = try url.resourceValues(forKeys: [.fileSizeKey])
        guard let size = values.fileSize, size <= Self.maximumSourceBytes else { throw SourceError.tooLarge }
        // Read at most the bound even if the file grows after the metadata check.
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: Self.maximumSourceBytes + 1) ?? Data()
        guard data.count <= Self.maximumSourceBytes else { throw SourceError.tooLarge }
        guard let text = String(data: data, encoding: .utf8) else { throw SourceError.notUTF8 }
        return text
    }

    private func validateLocation(_ reference: CodeReference, source: String, candidate: inout JumpCandidate) {
        guard let line = reference.line else { return }
        let lines = source.split(separator: "\n", omittingEmptySubsequences: false)
        if line < 1 || line > lines.count {
            candidate.require("指定行 \(line) 超出文件范围（共 \(lines.count) 行）；确认后仅打开文件")
            candidate.line = nil; candidate.column = nil
            return
        }
        if let end = reference.endLine, end < line || end > lines.count {
            candidate.require("行号范围终点 \(end) 无效；将定位起始行 \(line)")
        }
        if let column = reference.column, column < 1 || column > lines[line - 1].utf16.count + 1 {
            candidate.require("列号 \(column) 超出该行范围；将定位第 \(line) 行")
            candidate.column = nil
        }
    }
}

private extension JumpCandidate {
    mutating func require(_ text: String) { requiresConfirmation = true; appendReason(text) }
    mutating func appendReason(_ text: String) { reason += reason.isEmpty ? text : "；" + text }
}

private enum SourceError: LocalizedError {
    case tooLarge, notUTF8
    var errorDescription: String? {
        switch self {
        case .tooLarge: "文件超过 2 MB 检查上限"
        case .notUTF8: "文件不是 UTF-8 文本"
        }
    }
}

private struct Target {
    var path: String?
    var symbol: String?
    var owner: String?

    init(_ reference: CodeReference) {
        path = reference.path
        symbol = reference.symbol
        if let raw = symbol, !raw.isEmpty {
            // Parser accepts both Class#method and Class.method, including package-qualified names.
            let base = String(raw.prefix { $0 != "(" })
            if let split = base.lastIndex(where: { $0 == "#" || $0 == "." }) {
                let owner = String(base[..<split])
                let method = String(base[base.index(after: split)...])
                self.owner = owner.split(separator: ".").last.map(String.init)
                if path == nil { path = owner.replacingOccurrences(of: ".", with: "/") }
                symbol = method
            } else if path == nil {
                path = base
                symbol = nil
            } else {
                symbol = base
            }
        }
    }
}

/// A bounded, lexical Java declaration reader. Strings/comments are removed before tokenizing;
/// declarations are accepted only directly inside a named class/interface/enum/record body.
/// This intentionally declines method calls and unsupported syntax instead of guessing a line.
private enum JavaDeclarations {
    struct Declaration { let line: Int; let startLine: Int; let endLine: Int; let signature: String }
    struct Token { let text: String; let line: Int }
    struct Scope { var typeName: String?; var memberStart: Int }

    static func find(symbol: String, source: String) -> [Declaration] {
        let tokens = tokenize(source)
        var scopes: [Scope] = []
        var globalStart = 0
        var results: [Declaration] = []
        for i in tokens.indices {
            let text = tokens[i].text
            if text == "{" {
                let start = scopes.last?.memberStart ?? globalStart
                let prefix = Array(tokens[start..<i])
                let type = declaredType(prefix)
                scopes.append(Scope(typeName: type, memberStart: i + 1))
            } else if text == "}" {
                if !scopes.isEmpty { scopes.removeLast() }
                if !scopes.isEmpty { scopes[scopes.count - 1].memberStart = i + 1 }
                else { globalStart = i + 1 }
            } else if text == ";" {
                if !scopes.isEmpty { scopes[scopes.count - 1].memberStart = i + 1 }
                else { globalStart = i + 1 }
            } else if text == "(", i > 0, tokens[i - 1].text == symbol,
                      let scope = scopes.last, let typeName = scope.typeName,
                      let close = closingParen(tokens, from: i),
                      let terminator = declarationTerminator(tokens, after: close),
                      validPrefix(Array(tokens[scope.memberStart..<(i - 1)]), constructor: symbol == typeName) {
                let end: Int
                if tokens[terminator].text == "{" {
                    guard let bodyEnd = closingBrace(tokens, from: terminator) else { continue }
                    end = bodyEnd
                } else { end = terminator }
                let signature = tokens[(i - 1)...close].map(\.text).joined(separator: " ")
                    .replacingOccurrences(of: "( ", with: "(")
                    .replacingOccurrences(of: " )", with: ")")
                    .replacingOccurrences(of: " ,", with: ",")
                results.append(Declaration(line: tokens[i - 1].line,
                    startLine: tokens[scope.memberStart].line, endLine: tokens[end].line,
                    signature: String(signature.prefix(180))))
            }
        }
        return results
    }

    private static func declaredType(_ prefix: [Token]) -> String? {
        let typeWords: Set<String> = ["class", "interface", "enum", "record"]
        for i in prefix.indices where typeWords.contains(prefix[i].text) {
            guard i + 1 < prefix.count, i == 0 || prefix[i - 1].text != ".",
                  isIdentifier(prefix[i + 1].text) else { continue }
            // A class token inside an expression is not a named type declaration.
            if prefix[..<i].contains(where: { $0.text == "=" || $0.text == "new" }) { continue }
            return prefix[i + 1].text
        }
        return nil
    }

    private static func closingParen(_ tokens: [Token], from: Int) -> Int? {
        var depth = 0
        for i in from..<min(tokens.count, from + 4_096) {
            if tokens[i].text == "(" { depth += 1 }
            if tokens[i].text == ")" { depth -= 1; if depth == 0 { return i } }
            if tokens[i].text == "{" || tokens[i].text == ";" { return nil }
        }
        return nil
    }

    private static func closingBrace(_ tokens: [Token], from: Int) -> Int? {
        var depth = 0
        for i in from..<tokens.count {
            if tokens[i].text == "{" { depth += 1 }
            if tokens[i].text == "}" { depth -= 1; if depth == 0 { return i } }
        }
        return nil
    }

    private static func declarationTerminator(_ tokens: [Token], after: Int) -> Int? {
        guard after + 1 < tokens.count else { return nil }
        let first = tokens[after + 1].text
        if first == "{" || first == ";" { return after + 1 }
        guard first == "throws" || first == "default" || first == "[" else { return nil }
        for i in (after + 1)..<min(tokens.count, after + 256) {
            if tokens[i].text == "{" || tokens[i].text == ";" { return i }
            if ["=", "->", "(", ")"].contains(tokens[i].text) { return nil }
        }
        return nil
    }

    private static func validPrefix(_ tokens: [Token], constructor: Bool) -> Bool {
        var plain: [String] = []
        var i = 0
        while i < tokens.count {
            if tokens[i].text == "@" {
                i += 1
                if i < tokens.count, isIdentifier(tokens[i].text) { i += 1 }
                while i + 1 < tokens.count, tokens[i].text == ".", isIdentifier(tokens[i + 1].text) { i += 2 }
                if i < tokens.count, tokens[i].text == "(" {
                    guard let end = closingParen(tokens, from: i) else { return false }
                    i = end + 1
                }
            } else { plain.append(tokens[i].text); i += 1 }
        }
        let forbidden: Set<String> = ["=", "new", "return", "throw", "->", "::", ";", "{", "}", "(", ")"]
        guard !plain.contains(where: { forbidden.contains($0) }), plain.last != "." else { return false }
        let modifiers: Set<String> = ["public", "protected", "private", "static", "final", "abstract",
                                      "synchronized", "native", "strictfp", "default"]
        let type = plain.filter { !modifiers.contains($0) }
        return constructor || type.contains(where: isIdentifier)
    }

    private static func isIdentifier(_ text: String) -> Bool {
        guard let first = text.utf8.first else { return false }
        return first == 95 || first == 36 || first >= 128 || (65...90).contains(first) || (97...122).contains(first)
    }

    private static func tokenize(_ source: String) -> [Token] {
        let bytes = Array(source.utf8)
        var result: [Token] = []
        var i = 0
        var line = 1
        func at(_ offset: Int) -> UInt8? { offset < bytes.count ? bytes[offset] : nil }
        func word(_ byte: UInt8) -> Bool {
            byte == 95 || byte == 36 || byte >= 128 || (65...90).contains(byte) ||
            (97...122).contains(byte) || (48...57).contains(byte)
        }
        while i < bytes.count {
            let byte = bytes[i]
            if byte == 10 { line += 1; i += 1; continue }
            if byte == 13 || byte == 9 || byte == 32 { i += 1; continue }
            if byte == 47, at(i + 1) == 47 {
                i += 2
                while i < bytes.count, bytes[i] != 10 { i += 1 }
                continue
            }
            if byte == 47, at(i + 1) == 42 {
                i += 2
                while i < bytes.count {
                    if bytes[i] == 10 { line += 1 }
                    if bytes[i] == 42, at(i + 1) == 47 { i += 2; break }
                    i += 1
                }
                continue
            }
            if byte == 34 || byte == 39 {
                let triple = byte == 34 && at(i + 1) == 34 && at(i + 2) == 34
                i += triple ? 3 : 1
                while i < bytes.count {
                    if bytes[i] == 10 { line += 1 }
                    if bytes[i] == 92 { i += min(2, bytes.count - i); continue }
                    if bytes[i] == byte {
                        if !triple { i += 1; break }
                        if at(i + 1) == 34, at(i + 2) == 34 { i += 3; break }
                    }
                    i += 1
                }
                continue
            }
            let start = i
            if word(byte) {
                i += 1
                while i < bytes.count, word(bytes[i]) { i += 1 }
            } else if (byte == 45 && at(i + 1) == 62) || (byte == 58 && at(i + 1) == 58) { i += 2 }
            else { i += 1 }
            result.append(Token(text: String(decoding: bytes[start..<i], as: UTF8.self), line: line))
        }
        return result
    }
}
