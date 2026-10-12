import Foundation

/// Usage is stored by ProjectRoot.id.uuidString so renaming a project preserves its history.
public struct ProjectUsage: Codable, Equatable, Sendable {
    public var lastOpened: Date?
    public var selectionCount: Int

    public init(lastOpened: Date? = nil, selectionCount: Int = 0) {
        self.lastOpened = lastOpened
        self.selectionCount = max(0, selectionCount)
    }

    public mutating func record(at: Date) {
        lastOpened = at
        selectionCount = selectionCount >= Int.max ? Int.max : max(0, selectionCount) + 1
    }
}

public enum ProjectRanking {
    /// Search relevance (exact, prefix, substring) comes first. Within each tier:
    /// score = (1 + log2(1 + selections)) * 2^(-daysSinceLastOpen / 7).
    /// Frequency grows logarithmically; a seven-day half-life prevents historical favorites
    /// from permanently occupying the first position. Future timestamps count as today.
    /// No history, invalid timestamps, or zero selections receive a zero score.
    public static func sorted(projects: [ProjectRoot], usage: [String: ProjectUsage],
                              query: String = "", now: Date = Date()) -> [ProjectRoot] {
        let query = key(query.trimmingCharacters(in: .whitespacesAndNewlines))
        let ranked: [RankedProject] = projects.compactMap { project in
            guard project.enabled else { return nil }
            let name = key(project.name)
            let path = key(project.path)
            let terms = [name, path] + project.aliases.map(key)
            let relevance: Int
            if query.isEmpty || terms.contains(query) { relevance = 0 }
            else if terms.contains(where: { $0.hasPrefix(query) }) { relevance = 1 }
            else if terms.contains(where: { $0.contains(query) }) { relevance = 2 }
            else { return nil }
            let id = project.id.uuidString
            return RankedProject(project: project, relevance: relevance,
                                 score: score(usage[id], now: now), name: name, path: path, id: id)
        }
        return ranked.sorted {
            if $0.relevance != $1.relevance { return $0.relevance < $1.relevance }
            if $0.score != $1.score { return $0.score > $1.score }
            if $0.name != $1.name { return $0.name < $1.name }
            if $0.path != $1.path { return $0.path < $1.path }
            return $0.id < $1.id
        }.map(\.project)
    }

    private static func score(_ usage: ProjectUsage?, now: Date) -> Double {
        guard let usage, let lastOpened = usage.lastOpened, usage.selectionCount > 0 else { return 0 }
        let seconds = now.timeIntervalSince(lastOpened)
        guard seconds.isFinite else { return 0 }
        let ageDays = max(0, seconds) / 86_400
        return (1 + log2(1 + Double(usage.selectionCount))) * exp2(-ageDays / 7)
    }

    private static func key(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }

    private struct RankedProject {
        let project: ProjectRoot
        let relevance: Int
        let score: Double
        let name: String
        let path: String
        let id: String
    }
}

public enum CandidateOrdering {
    /// Moves whole projects and keeps the resolver's order inside each project.
    /// The remembered source project comes first, then projects by their latest activity
    /// (an opened jump or a project selection), then projects without history.
    /// Copies of one file in several git worktrees therefore list the worktree in use first.
    public static func sorted(_ candidates: [JumpCandidate], preferredProjectID: UUID? = nil,
                              recentJumps: [RecentJump], usage: [String: ProjectUsage]) -> [JumpCandidate] {
        var lastActive: [UUID: Date] = [:]
        func note(_ id: UUID, _ date: Date) {
            if lastActive[id].map({ date > $0 }) ?? true { lastActive[id] = date }
        }
        for jump in recentJumps { note(jump.projectID, jump.date) }
        for (key, value) in usage {
            if let id = UUID(uuidString: key), let opened = value.lastOpened { note(id, opened) }
        }
        return candidates.enumerated().sorted { left, right in
            let l = left.element.project.id, r = right.element.project.id
            if l != r {
                let lp = l == preferredProjectID, rp = r == preferredProjectID
                if lp != rp { return lp }
                switch (lastActive[l], lastActive[r]) {
                case let (a?, b?) where a != b: return a > b
                case (.some, nil): return true
                case (nil, .some): return false
                default: break
                }
            }
            return left.offset < right.offset
        }.map(\.element)
    }
}
