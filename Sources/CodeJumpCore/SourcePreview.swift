import Foundation

public struct PreviewLine: Sendable, Identifiable, Codable {
    public let number: Int
    public let text: String
    public let highlighted: Bool
    public var id: Int { number }
}

public enum SourcePreview {
    public static func read(_ candidate: JumpCandidate, radius: Int = 4) throws -> [PreviewLine] {
        _ = try EditorLaunchPlan.makeArguments(candidate: candidate, editor: .idea)
        let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: candidate.absolutePath))
        defer { try? handle.close() }
        let data = try handle.read(upToCount: CodeResolver.maximumSourceBytes + 1) ?? Data()
        guard data.count <= CodeResolver.maximumSourceBytes, let source = String(data: data, encoding: .utf8) else {
            throw CocoaError(.fileReadInapplicableStringEncoding)
        }
        let lines = source.components(separatedBy: "\n")
        let line = candidate.line ?? 1
        guard line > 0, line <= lines.count else { throw EditorLaunchError.invalidPosition }
        let radius = min(12, max(0, radius))
        return (max(1, line - radius)...min(lines.count, line + radius)).map {
            PreviewLine(number: $0, text: String(lines[$0 - 1].prefix(400)), highlighted: $0 == line)
        }
    }
}

public struct RecentJump: Codable, Identifiable, Sendable {
    public var id: UUID
    public var projectID: UUID
    public var path: String
    public var symbol: String?
    public var line: Int?
    public var date: Date
    public init(candidate: JumpCandidate) {
        id = UUID(); projectID = candidate.project.id; path = candidate.absolutePath
        symbol = candidate.symbol; line = candidate.line; date = Date()
    }
    public var reference: CodeReference {
        CodeReference(source: path, path: path, symbol: symbol, line: line, isFallback: true)
    }
}
