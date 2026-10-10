import CodeJumpCore
import Foundation

@main struct CodeJumpCLI {
    static func main() throws {
        let arguments = Array(CommandLine.arguments.dropFirst())
        var roots: [ProjectRoot] = [], query = "", repetitions = 1
        var position = 0
        while position < arguments.count {
            switch arguments[position] {
            case "--project":
                position += 1
                guard position < arguments.count else { throw CLIError.usage }
                let url = URL(fileURLWithPath: (arguments[position] as NSString).expandingTildeInPath).standardizedFileURL
                roots.append(ProjectRoot(name: url.lastPathComponent, path: url.path))
            case "--query":
                position += 1
                guard position < arguments.count else { throw CLIError.usage }
                query = arguments[position]
            case "--benchmark":
                position += 1
                guard position < arguments.count, let count = Int(arguments[position]), (1...10000).contains(count) else { throw CLIError.usage }
                repetitions = count
            case "--help", "-h": print("codejump-cli --project PATH [--project PATH] --query REFERENCE [--benchmark N]\n只读解析与性能检查，不启动编辑器。"); return
            default: throw CLIError.usage
            }
            position += 1
        }
        guard !roots.isEmpty, !query.isEmpty else { throw CLIError.usage }
        let start = Date()
        let index = try ProjectIndex.build(projects: roots)
        let buildTime = Date().timeIntervalSince(start) * 1000
        let resolver = CodeResolver(index: index)
        var timings: [Double] = [], results: [JumpCandidate] = []
        for _ in 0..<repetitions {
            let time = Date()
            results = ReferenceParser.parse(query).flatMap { resolver.resolve($0) }
            timings.append(Date().timeIntervalSince(time) * 1000)
        }
        let sorted = timings.sorted()
        struct Report: Encodable {
            let files: Int; let indexMilliseconds: Double; let repetitions: Int
            let medianMilliseconds: Double; let p95Milliseconds: Double; let maxMilliseconds: Double
            let references: [CodeReference]; let candidates: [JumpCandidate]
        }
        let report = Report(files: index.files.count, indexMilliseconds: buildTime, repetitions: repetitions,
            medianMilliseconds: sorted[sorted.count / 2], p95Milliseconds: sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.95))],
            maxMilliseconds: sorted.last ?? 0, references: ReferenceParser.parse(query), candidates: results)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        print(String(decoding: try encoder.encode(report), as: UTF8.self))
    }
    enum CLIError: Error { case usage }
}
