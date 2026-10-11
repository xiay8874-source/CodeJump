import AppKit
import CodeJumpCore
import Foundation

/// Discovery is local to this user's Application Support directory; credentials never enter preferences or diagnostics.
actor IDEABridge {
    private struct Endpoint: Decodable, Sendable { let port: Int; let token: String; let pid: Int32; let home: String }
    private struct Hit: Decodable, Sendable {
        let target: String; let project: String; let path: String; let line: Int
        let symbol: String; let signature: String; let preview: [PreviewLine]
    }
    private struct Selection: Decodable {
        let project: String
        let frameActive: Bool?
        let frameFocused: Bool?
    }
    private var previews: [String: [PreviewLine]] = [:]
    private let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("CodeJump/idea")

    private func endpoints(applicationPath: String?) async -> [(String, Endpoint)] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        var results: [(String, Endpoint)] = []
        for file in files.filter({ $0.pathExtension == "json" }).prefix(8) {
            guard let data = try? Data(contentsOf: file), data.count <= 4096,
                  let endpoint = try? JSONDecoder().decode(Endpoint.self, from: data),
                  (1024...65535).contains(endpoint.port), endpoint.token.count >= 32 else { continue }
            let matches = await MainActor.run {
                guard let application = NSRunningApplication(processIdentifier: endpoint.pid), !application.isTerminated,
                      application.bundleIdentifier?.hasPrefix("com.jetbrains.intellij") == true,
                      let bundle = application.bundleURL?.resolvingSymlinksInPath() else { return false }
                if let applicationPath, bundle.path != URL(fileURLWithPath: applicationPath).resolvingSymlinksInPath().path { return false }
                return bundle.appendingPathComponent("Contents").path == URL(fileURLWithPath: endpoint.home).resolvingSymlinksInPath().path
            }
            if matches { results.append((file.lastPathComponent, endpoint)) }
        }
        return results
    }

    private static func request(_ path: String, endpoint: Endpoint, body: Data) async throws -> Data {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(endpoint.port)/\(path)")!)
        request.httpMethod = "POST"; request.httpBody = body; request.timeoutInterval = 2
        request.setValue("Bearer " + endpoint.token, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let config = URLSessionConfiguration.ephemeral
        config.connectionProxyDictionary = [:]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let (data, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200, data.count <= 2_000_000 else { throw URLError(.badServerResponse) }
        return data
    }

    func resolve(_ references: [CodeReference], projects: [ProjectRoot], applicationPath: String?) async -> [JumpCandidate] {
        var requests: [[String: String]] = []
        for reference in references where reference.symbol != nil && reference.revision == nil && !reference.contextAmbiguous {
            for project in projects where project.enabled {
                if let hint = reference.projectHint,
                   !([project.name, URL(fileURLWithPath: project.path).lastPathComponent] + project.aliases).contains(where: { $0.lowercased() == hint.lowercased() }) { continue }
                if requests.count >= 64 { break }
                requests.append(["project": project.path, "path": reference.path ?? "", "symbol": reference.symbol ?? "", "signature": reference.parameterSignature ?? ""])
            }
        }
        guard !requests.isEmpty, let body = try? JSONSerialization.data(withJSONObject: ["requests": requests]), body.count <= 16384 else { return [] }
        let available = await endpoints(applicationPath: applicationPath)
        let hits = await withTaskGroup(of: (String, [Hit]).self, returning: [(String, [Hit])].self) { group in
            for (name, endpoint) in available {
                group.addTask {
                    guard let data = try? await Self.request("resolve", endpoint: endpoint, body: body),
                          let hits = try? JSONDecoder().decode([Hit].self, from: data) else { return (name, []) }
                    return (name, hits)
                }
            }
            var result: [(String, [Hit])] = []
            for await value in group { result.append(value) }
            return result
        }
        if previews.count > 512 { previews.removeAll() }
        var candidates: [JumpCandidate] = []
        for (endpoint, values) in hits {
            for hit in values.prefix(128) {
                guard let project = projects.first(where: { $0.path == hit.project && $0.enabled }) else { continue }
                var candidate = JumpCandidate(project: project, absolutePath: hit.path,
                    relativePath: hit.path.hasPrefix(project.path + "/") ? String(hit.path.dropFirst(project.path.count + 1)) : hit.path,
                    line: hit.line > 0 ? hit.line : nil, symbol: hit.symbol,
                    reason: "IDEA PSI · \(hit.signature.isEmpty ? hit.symbol : hit.signature) · 确认后定位当前声明",
                    requiresConfirmation: true)
                candidate.pluginTarget = hit.target; candidate.pluginEndpoint = endpoint
                candidates.append(candidate); previews[hit.target] = hit.preview
            }
        }
        return candidates
    }

    func preview(_ target: String) -> [PreviewLine] { previews[target] ?? [] }

    func navigate(_ candidate: JumpCandidate, applicationPath: String?, projects: [ProjectRoot]) async throws -> Bool {
        guard let target = candidate.pluginTarget,
              let endpoint = await endpoints(applicationPath: applicationPath).first(where: { $0.0 == candidate.pluginEndpoint })?.1 else { throw URLError(.cannotConnectToHost) }
        let body = try JSONSerialization.data(withJSONObject: ["target": target])
        _ = try await Self.request("navigate", endpoint: endpoint, body: body)
        // New companions can confirm that the requested project's frame is already focused.
        if let data = try? await Self.request("selection", endpoint: endpoint, body: Data("{}".utf8)),
           let selections = try? JSONDecoder().decode([Selection].self, from: data),
           selections.contains(where: { $0.project == candidate.project.path && $0.frameActive == true && $0.frameFocused == true }) {
            return true
        }
        // Older companions select the editor without bringing its project window forward.
        // Restrict the focus attempt to the same verified IDEA process that handled navigation.
        return await ProjectWindowFocus.focus(project: candidate.project, editor: .idea,
            configuredProjects: projects, applicationPath: applicationPath, expectedPID: endpoint.pid)
    }

    func connected(applicationPath: String?) async -> Int {
        var count = 0
        for (_, endpoint) in await endpoints(applicationPath: applicationPath) {
            if (try? await Self.request("projects", endpoint: endpoint, body: Data("{}".utf8))) != nil { count += 1 }
        }
        return count
    }
}
