import Foundation
import CryptoKit
import Darwin

public struct ClaudeInstructionSnapshot: Equatable, Sendable {
    public let fullText: String
    public let managedText: String?
    public let exists: Bool
    public let isLegacyStandalone: Bool
    public let writable: Bool
}

public enum ClaudeInstructionError: LocalizedError, Equatable {
    case symbolicLink
    case notRegularFile
    case tooLarge
    case invalidUTF8
    case malformedMarkers
    case changedOnDisk
    case notWritable
    case emptyInstructions
    case reservedMarkers

    public var errorDescription: String? {
        switch self {
        case .symbolicLink:
            return "此路径是符号链接。为避免修改链接指向的其他配置，请先在文件管理器中确认并使用普通文件。"
        case .notRegularFile:
            return "Claude 指令路径不是普通文件，无法安全修改。"
        case .tooLarge:
            return "Claude 指令文件超过 1 MB，请先检查文件内容。"
        case .invalidUTF8:
            return "Claude 指令文件不是有效的 UTF-8 文本，未作修改。"
        case .malformedMarkers:
            return "CodeJump 标记缺失、重复或格式不完整，请先检查 CLAUDE.md，未作修改。"
        case .changedOnDisk:
            return "CLAUDE.md 已被其他程序修改。请重新加载，再保存你的修改。"
        case .notWritable:
            return "当前无法写入 Claude 指令文件或所在目录，请检查文件权限。"
        case .emptyInstructions:
            return "指令不能为空；如需停用，请使用移除功能。"
        case .reservedMarkers:
            return "指令正文不能包含 CodeJump 管理标记。"
        }
    }
}

/// Edits only a delimited block in Claude Code's global instructions. The snapshot
/// is an optimistic concurrency check; no configuration is written while reading.
public enum ClaudeInstructions {
    public static let defaultText = """
    ## CodeJump 代码引用

    涉及源码或调用链时，先核对代码，再使用 Markdown 符号链接：`[完整类名#方法名](项目内完整相对路径:行号)`；引用类时省略 `#方法名`。
    - 所有源码链接标签只用完整类名或类名#方法名；字段、调用点、重复位置也使用所属符号，不用“第N行”等位置说明替代。输出前核对标签；同名类或重载补充必要包名、参数类型。
    - 同项目省略项目名；跨项目或项目归属不清时，标签加“项目名 / ”，只添加消歧所需的说明。
    - 正文和链接目标都不用本机绝对路径；目录不省略，目标相对于所属项目根目录，标签与目标必须一致。
    - 调用链每个节点分别链接，箭头和中文解释放在链接外，避免将整条链放进代码块。
    - 路径或行号未核实就不编造：未知行号可省略，未知路径用行内代码写完整符号并说明未核实；不要为普通概念说明添加代码引用。
    """

    static let beginMarker = "<!-- CodeJump:begin -->"
    static let endMarker = "<!-- CodeJump:end -->"
    private static let maximumBytes = 1_048_576

    // Exact legacy documents are recognized by digest; no former private examples are embedded.
    private static let legacyDigests: Set<String> = [
        "8a47c6a25cd1d2129ba1b99285a9dca67b95af4f263cb2d207911e4ee4227292",
        "575faa6147a122a2ed91c2a6149672c36859820ebf55a4695ecdf5028a21b7f3"
    ]

    public static func read(at url: URL) throws -> ClaudeInstructionSnapshot {
        let manager = FileManager.default
        guard let attributes = try attributesIfPresent(at: url) else {
            return ClaudeInstructionSnapshot(fullText: "", managedText: nil, exists: false,
                                             isLegacyStandalone: false, writable: parentIsWritable(of: url))
        }
        try requireRegularFile(attributes)
        guard (attributes[.size] as? NSNumber)?.intValue ?? 0 <= maximumBytes else {
            throw ClaudeInstructionError.tooLarge
        }
        let bytes = try Data(contentsOf: url)
        guard bytes.count <= maximumBytes else { throw ClaudeInstructionError.tooLarge }
        guard String(data: bytes, encoding: .utf8) != nil else { throw ClaudeInstructionError.invalidUTF8 }
        // String(data:encoding:) consumes a UTF-8 BOM; decoding preserves it so
        // backups and unrelated user content retain their exact original bytes.
        let text = String(decoding: bytes, as: UTF8.self)
        let block = try managedBlock(in: text)
        let legacy = legacyDigests.contains(SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined())
        return ClaudeInstructionSnapshot(
            fullText: text, managedText: legacy ? text : block.map { String(text[$0.body]) }, exists: true,
            isLegacyStandalone: legacy,
            writable: manager.isWritableFile(atPath: url.path) && parentIsWritable(of: url))
    }

    /// Returns a backup URL if an existing file changed, or nil for first install / no-op.
    @discardableResult
    public static func save(_ text: String, at url: URL, expected: ClaudeInstructionSnapshot) throws -> URL? {
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { throw ClaudeInstructionError.emptyInstructions }
        guard !body.contains("<!-- CodeJump:") else { throw ClaudeInstructionError.reservedMarkers }
        let current = try unchangedSnapshot(at: url, expected: expected)
        let blockText = beginMarker + "\n" + body + "\n" + endMarker
        let result: String
        if current.isLegacyStandalone {
            result = blockText + "\n"
        } else if let block = try managedBlock(in: current.fullText) {
            result = current.fullText.replacingCharacters(in: block.range, with: blockText)
        } else {
            let separator = current.fullText.isEmpty || current.fullText.hasSuffix("\n\n") ? ""
                : current.fullText.hasSuffix("\n") ? "\n" : "\n\n"
            result = current.fullText + separator + blockText + "\n"
        }
        return try write(result, at: url, expected: current)
    }

    @discardableResult
    public static func remove(at url: URL, expected: ClaudeInstructionSnapshot) throws -> URL? {
        let current = try unchangedSnapshot(at: url, expected: expected)
        let result: String
        if current.isLegacyStandalone {
            result = ""
        } else if let block = try managedBlock(in: current.fullText) {
            result = current.fullText.replacingCharacters(in: block.range, with: "")
        } else {
            return nil
        }
        return try write(result, at: url, expected: current)
    }

    private struct Block {
        let range: Range<String.Index>
        let body: Range<String.Index>
    }

    private static func managedBlock(in text: String) throws -> Block? {
        let starts = text.ranges(of: beginMarker)
        let ends = text.ranges(of: endMarker)
        // Also reject incomplete, mistyped or orphaned CodeJump markers.
        let prefixes = text.ranges(of: "<!-- CodeJump:")
        guard !starts.isEmpty || !ends.isEmpty || !prefixes.isEmpty else { return nil }
        guard starts.count == 1, ends.count == 1, prefixes.count == 2,
              let start = starts.first, let end = ends.first, start.upperBound < end.lowerBound,
              isWholeLine(start, in: text), isWholeLine(end, in: text) else {
            throw ClaudeInstructionError.malformedMarkers
        }
        var bodyStart = start.upperBound
        if text[bodyStart...].hasPrefix("\r\n") || text[bodyStart...].hasPrefix("\n") {
            bodyStart = text.index(after: bodyStart)
        }
        var bodyEnd = end.lowerBound
        if bodyEnd > bodyStart, text[..<bodyEnd].hasSuffix("\r\n") || text[..<bodyEnd].hasSuffix("\n") {
            bodyEnd = text.index(before: bodyEnd)
        }
        return Block(range: start.lowerBound..<end.upperBound, body: bodyStart..<bodyEnd)
    }

    private static func isWholeLine(_ range: Range<String.Index>, in text: String) -> Bool {
        let before = range.lowerBound == text.startIndex || text[..<range.lowerBound].hasSuffix("\n")
            || text[..<range.lowerBound].hasSuffix("\r\n")
        let after = range.upperBound == text.endIndex || text[range.upperBound...].hasPrefix("\n")
            || text[range.upperBound...].hasPrefix("\r\n")
        return before && after
    }

    private static func unchangedSnapshot(at url: URL, expected: ClaudeInstructionSnapshot) throws -> ClaudeInstructionSnapshot {
        let current = try read(at: url)
        // String equality normalizes canonically equivalent Unicode; bytes matter here.
        guard current.exists == expected.exists,
              current.fullText.utf8.elementsEqual(expected.fullText.utf8) else {
            throw ClaudeInstructionError.changedOnDisk
        }
        return current
    }

    private static func write(_ text: String, at url: URL, expected: ClaudeInstructionSnapshot) throws -> URL? {
        guard !text.utf8.elementsEqual(expected.fullText.utf8) else { return nil }
        let bytes = Data(text.utf8)
        guard bytes.count <= maximumBytes else { throw ClaudeInstructionError.tooLarge }
        guard expected.writable else { throw ClaudeInstructionError.notWritable }
        let manager = FileManager.default
        let parent = url.deletingLastPathComponent()
        try manager.createDirectory(at: parent, withIntermediateDirectories: true,
                                    attributes: [.posixPermissions: 0o700])
        _ = try unchangedSnapshot(at: url, expected: expected)
        let mode = try attributesIfPresent(at: url)?[.posixPermissions] ?? NSNumber(value: 0o600)
        var backup: URL?
        if expected.exists {
            let directory = parent.appendingPathComponent("codejump-backups", isDirectory: true)
            if let attributes = try attributesIfPresent(at: directory) {
                if attributes[.type] as? FileAttributeType == .typeSymbolicLink { throw ClaudeInstructionError.symbolicLink }
                guard attributes[.type] as? FileAttributeType == .typeDirectory else { throw ClaudeInstructionError.notRegularFile }
            } else {
                try manager.createDirectory(at: directory, withIntermediateDirectories: false,
                                            attributes: [.posixPermissions: 0o700])
            }
            let path = directory.appendingPathComponent("\(url.lastPathComponent).\(UUID().uuidString).bak")
            try Data(expected.fullText.utf8).write(to: path, options: .withoutOverwriting)
            try manager.setAttributes([.posixPermissions: mode], ofItemAtPath: path.path)
            backup = path
        }
        let temporary = parent.appendingPathComponent(".CodeJump-\(UUID().uuidString).tmp")
        defer { try? manager.removeItem(at: temporary) }
        try bytes.write(to: temporary, options: .withoutOverwriting)
        try manager.setAttributes([.posixPermissions: mode], ofItemAtPath: temporary.path)
        _ = try unchangedSnapshot(at: url, expected: expected)
        guard rename(temporary.path, url.path) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        return backup
    }

    private static func requireRegularFile(_ attributes: [FileAttributeKey: Any]) throws {
        if attributes[.type] as? FileAttributeType == .typeSymbolicLink { throw ClaudeInstructionError.symbolicLink }
        guard attributes[.type] as? FileAttributeType == .typeRegular else { throw ClaudeInstructionError.notRegularFile }
    }

    private static func attributesIfPresent(at url: URL) throws -> [FileAttributeKey: Any]? {
        do { return try FileManager.default.attributesOfItem(atPath: url.path) }
        catch CocoaError.fileReadNoSuchFile { return nil }
        catch CocoaError.fileNoSuchFile { return nil }
    }

    private static func parentIsWritable(of url: URL) -> Bool {
        let manager = FileManager.default
        var directory = url.deletingLastPathComponent()
        while !manager.fileExists(atPath: directory.path), directory.path != "/" {
            directory.deleteLastPathComponent()
        }
        var isDirectory: ObjCBool = false
        return manager.fileExists(atPath: directory.path, isDirectory: &isDirectory)
            && isDirectory.boolValue && manager.isWritableFile(atPath: directory.path)
    }
}
