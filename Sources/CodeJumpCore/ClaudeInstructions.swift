import Foundation
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

    // Exact standalone content installed before managed blocks were introduced.
    // A heading match or similar prose is deliberately insufficient for migration.
    static let legacyStandaloneText = """
    # 代码引用与编辑器定位规范

    当回答涉及真实代码、源码定位、业务实现或调用链时，遵循以下规范，便于通过 CodeJump 定位到本地编辑器。

    ## 1. 使用真实、完整的代码名称

    - 使用源码中实际存在的完整类名和方法名，不用简称或概念名称替代。
    - 例如使用 BatchCreateRecordEnricherManager，不简写为 EnricherManager。
    - 方法引用使用“类名#方法名”，避免单独输出没有所属类的裸方法名。
    - 存在同名类时补充包名；存在方法重载时补充已核实的参数类型。
    - 概念性名称、伪代码和假设实现必须明确标注。

    ## 2. 优先使用 Markdown 超链接

    - 同一项目内，可见标签写“完整类名#方法名”；引用类时省略方法名，不重复添加项目名。
    - 跨项目或存在项目归属歧义时，标签写“项目名 / 完整类名#方法名”。
    - 链接目标使用项目内完整相对路径，已核实行号时追加“:行号”。
    - 正文和链接目标均不使用本机绝对路径，不暴露用户名或机器目录。
    - 链接目标中的目录必须完整，不使用 ... 等省略写法。
    - 链接标签与目标必须对应同一个文件、类或方法。

    格式示例：

    ```markdown
    [完整类名#方法名](模块/src/main/java/包路径/完整类名.java:行号)
    [项目名 / 完整类名#方法名](模块/src/main/java/包路径/完整类名.java:行号)
    ```

    以上仅为格式示意，实际输出必须替换为已核实的名称、路径和行号。

    ## 3. 清晰表达调用链和项目归属

    - 同项目调用链不必在每个节点重复标注项目。
    - 跨项目调用链中，对跨项目节点标明所属项目，避免混淆调用方和被调用方。
    - 区分接口、实现类及不同项目中的同名类。
    - 优先使用逐项列表，或“代码链接 → 代码链接”表达调用链。
    - 中文解释和箭头放在引用外，不把整条调用链包进一个行内代码中。
    - 不确定项目归属时明确说明，不根据名称猜测。

    ## 4. 以已核实的源码为准

    - 不编造项目归属、路径、类名、方法名、参数类型或行号。
    - 修改代码后，引用行号前重新核对当前位置。
    - 不知道行号时可以省略行号，不必强行补齐。
    - 不知道准确路径时，使用行内代码形式的“完整类名#方法名”或完整类名，不编造链接；跨项目时补充必要的项目说明。
    - 仅凭文档、记忆或推测得出的代码引用，应标注“未核实源码”。
    - 引用历史版本时说明对应分支或提交，不把历史行号当成当前工作区位置。

    仅在涉及代码引用时应用这些规则。普通问答和纯概念说明保持自然、简洁，不添加无关的项目名、路径或代码引用。

    """

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
        let legacy = bytes == Data(legacyStandaloneText.utf8)
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
