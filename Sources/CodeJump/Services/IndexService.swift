import CodeJumpCore
import Foundation

actor IndexService {
    private var index = ProjectIndex(projects: [], files: [])
    private var resolver = CodeResolver(index: ProjectIndex(projects: [], files: []))
    private let cacheURL: URL
    private var appliedGeneration = 0

    init(cacheURL: URL) { self.cacheURL = cacheURL }

    func restore(projects: [ProjectRoot]) -> Int? {
        guard let data = try? Data(contentsOf: cacheURL),
              let cached = try? JSONDecoder().decode(ProjectIndex.self, from: data),
              cached.projects == projects else { return nil }
        index = cached; resolver = CodeResolver(index: cached)
        return cached.files.count
    }

    func refresh(projects: [ProjectRoot], changedPaths: [String]? = nil, generation: Int) throws -> (Int, Double) {
        guard generation >= appliedGeneration else { return (index.files.count, 0) }
        let started = Date()
        let newIndex: ProjectIndex
        if let paths = changedPaths, !paths.isEmpty, index.projects == projects {
            newIndex = try index.updating(paths: paths)
        } else {
            newIndex = try ProjectIndex.build(projects: projects)
        }
        index = newIndex
        appliedGeneration = generation
        resolver = CodeResolver(index: newIndex)
        let data = try JSONEncoder().encode(newIndex)
        try data.write(to: cacheURL, options: .atomic)
        return (newIndex.files.count, Date().timeIntervalSince(started) * 1000)
    }

    func resolve(_ references: [CodeReference]) -> ([JumpCandidate], Double) {
        let started = Date()
        var seen = Set<String>()
        let candidates = references.flatMap { resolver.resolve($0) }.filter { seen.insert($0.id).inserted }
        return (candidates, Date().timeIntervalSince(started) * 1000)
    }
}
