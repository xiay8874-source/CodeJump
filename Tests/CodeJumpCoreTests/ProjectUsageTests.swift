import Foundation
import Testing
@testable import CodeJumpCore

struct ProjectUsageTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func project(_ name: String, path: String? = nil, aliases: [String] = [], enabled: Bool = true,
                         id: String = UUID().uuidString) -> ProjectRoot {
        ProjectRoot(id: UUID(uuidString: id)!, name: name, path: path ?? "/projects/\(name)", aliases: aliases, enabled: enabled)
    }

    private func history(_ project: ProjectRoot, count: Int, daysAgo: Double = 0) -> (String, ProjectUsage) {
        (project.id.uuidString, ProjectUsage(lastOpened: now.addingTimeInterval(-86_400 * daysAgo), selectionCount: count))
    }

    @Test
    func recordingUpdatesTimeAndCountAndSaturatesWithoutOverflow() throws {
        var usage = ProjectUsage()
        #expect(usage.lastOpened == nil)
        #expect(usage.selectionCount == 0)
        usage.record(at: now)
        #expect(usage.lastOpened == now)
        #expect(usage.selectionCount == 1)
        let later = now.addingTimeInterval(10)
        usage.record(at: later)
        #expect(usage.lastOpened == later)
        #expect(usage.selectionCount == 2)
        let restored = try JSONDecoder().decode(ProjectUsage.self, from: JSONEncoder().encode(usage))
        #expect(restored == usage)
        var saturated = ProjectUsage(selectionCount: Int.max)
        saturated.record(at: now)
        #expect(saturated.selectionCount == Int.max)
        #expect(saturated.lastOpened == now)
        var corrupt = ProjectUsage()
        corrupt.selectionCount = Int.min
        corrupt.record(at: now)
        #expect(corrupt.selectionCount == 1)
        #expect(ProjectUsage(selectionCount: -1).selectionCount == 0)
    }

    @Test
    func recentSelectionsOutrankEquallyFrequentOldSelections() {
        let old = project("A old")
        let recent = project("Z recent")
        let usage = Dictionary(uniqueKeysWithValues: [history(old, count: 3, daysAgo: 7), history(recent, count: 3)])
        #expect(ProjectRanking.sorted(projects: [old, recent], usage: usage, now: now).map(\.id) == [recent.id, old.id])
    }

    @Test
    func FrequentRecentProjectCanOutrankASingleUseToday() {
        let occasional = project("A occasional")
        let frequent = project("Z frequent")
        let usage = Dictionary(uniqueKeysWithValues: [history(occasional, count: 1), history(frequent, count: 10, daysAgo: 2)])
        #expect(ProjectRanking.sorted(projects: [occasional, frequent], usage: usage, now: now).first?.id == frequent.id)
    }

    @Test
    func OldFavoritesDecayEvenWithVeryLargeHistoricalCounts() {
        let old = project("A historical favorite")
        let recent = project("Z current")
        let usage = Dictionary(uniqueKeysWithValues: [history(old, count: Int.max, daysAgo: 180), history(recent, count: 1)])
        #expect(ProjectRanking.sorted(projects: [old, recent], usage: usage, now: now).first?.id == recent.id)
    }

    @Test
    func DisabledProjectsNeverAppear() {
        let disabled = project("disabled", enabled: false)
        let enabled = project("enabled")
        let usage = Dictionary(uniqueKeysWithValues: [history(disabled, count: Int.max)])
        #expect(ProjectRanking.sorted(projects: [disabled, enabled], usage: usage, now: now) == [enabled])
        #expect(ProjectRanking.sorted(projects: [disabled, enabled], usage: usage, query: "disabled", now: now).isEmpty)
    }

    @Test
    func SearchRelevancePrecedesUsageAndMatchesAliasesPathsAndChinese() {
        let exact = project("Alpha")
        let prefix = project("Alpha tools")
        let substring = project("My Alpha")
        let alias = project("中文工程", path: "/work/物流/后端", aliases: ["物流服务", "alpha-alias"])
        let usage = Dictionary(uniqueKeysWithValues: [history(substring, count: 100), history(prefix, count: 10)])
        let matches = ProjectRanking.sorted(projects: [substring, prefix, alias, exact], usage: usage, query: "  ALPHA  ", now: now)
        #expect(matches.map(\.id) == [exact.id, prefix.id, alias.id, substring.id])
        #expect(ProjectRanking.sorted(projects: [alias], usage: usage, query: "物流服务", now: now) == [alias])
        #expect(ProjectRanking.sorted(projects: [alias], usage: usage, query: "/WORK/物流", now: now) == [alias])
        #expect(ProjectRanking.sorted(projects: [alias], usage: usage, query: "中文", now: now) == [alias])
        #expect(ProjectRanking.sorted(projects: [alias], usage: usage, query: "不存在", now: now).isEmpty)
    }

    @Test
    func UnusedAndTiedProjectsHaveStableNamePathAndIDOrdering() {
        let a = project("Same", path: "/a", id: "00000000-0000-0000-0000-000000000001")
        let b = project("same", path: "/a", id: "00000000-0000-0000-0000-000000000002")
        let c = project("Same", path: "/b", id: "00000000-0000-0000-0000-000000000003")
        let z = project("Zulu")
        let expected = [a.id, b.id, c.id, z.id]
        #expect(ProjectRanking.sorted(projects: [z, c, b, a], usage: [:], now: now).map(\.id) == expected)
        let equal = Dictionary(uniqueKeysWithValues: [a, b, c, z].map { history($0, count: 2) })
        #expect(ProjectRanking.sorted(projects: [b, a, z, c], usage: equal, now: now).map(\.id) == expected)
    }

    @Test
    func FutureAndInvalidTimestampsCannotBreakRanking() {
        let a = project("A")
        let b = project("B")
        var usage = Dictionary(uniqueKeysWithValues: [history(a, count: 2), history(b, count: 2, daysAgo: -365)])
        #expect(ProjectRanking.sorted(projects: [b, a], usage: usage, now: now).map(\.id) == [a.id, b.id])
        usage[b.id.uuidString] = ProjectUsage(lastOpened: Date(timeIntervalSince1970: .nan), selectionCount: Int.max)
        #expect(ProjectRanking.sorted(projects: [b, a], usage: usage, now: now).map(\.id) == [a.id, b.id])
        usage[b.id.uuidString] = ProjectUsage(lastOpened: nil, selectionCount: Int.max)
        #expect(ProjectRanking.sorted(projects: [b, a], usage: usage, now: now).map(\.id) == [a.id, b.id])
    }
}
