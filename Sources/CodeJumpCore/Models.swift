import Foundation

public struct ProjectRoot: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var path: String
    public var aliases: [String]
    public var enabled: Bool
    public init(id: UUID = UUID(), name: String, path: String, aliases: [String] = [], enabled: Bool = true) {
        self.id = id; self.name = name; self.path = path; self.aliases = aliases; self.enabled = enabled
    }
}

public struct CodeReference: Hashable, Sendable, Codable {
    public var source: String
    public var path: String?
    public var symbol: String?
    public var line: Int?
    public var endLine: Int?
    public var column: Int?
    public var projectHint: String?
    public var revision: String?
    public var contextAmbiguous: Bool
    public init(source: String, path: String? = nil, symbol: String? = nil, line: Int? = nil,
                endLine: Int? = nil, column: Int? = nil, projectHint: String? = nil, revision: String? = nil, contextAmbiguous: Bool = false) {
        self.source = source; self.path = path; self.symbol = symbol; self.line = line
        self.endLine = endLine; self.column = column; self.projectHint = projectHint; self.revision = revision
        self.contextAmbiguous = contextAmbiguous
    }
}

public struct JumpCandidate: Hashable, Sendable, Identifiable, Codable {
    public var project: ProjectRoot
    public var absolutePath: String
    public var relativePath: String
    public var line: Int?
    public var column: Int?
    public var symbol: String?
    public var reason: String
    public var requiresConfirmation: Bool
    public var id: String { "\(project.id.uuidString):\(absolutePath):\(line ?? 0):\(column ?? 0)" }
    public init(project: ProjectRoot, absolutePath: String, relativePath: String, line: Int? = nil,
                column: Int? = nil, symbol: String? = nil, reason: String = "", requiresConfirmation: Bool = false) {
        self.project = project; self.absolutePath = absolutePath; self.relativePath = relativePath
        self.line = line; self.column = column; self.symbol = symbol; self.reason = reason
        self.requiresConfirmation = requiresConfirmation
    }
}
