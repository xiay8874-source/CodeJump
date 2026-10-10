import Foundation

/// Conservatively supplements a file URL with labels from the same accessibility neighborhood.
/// This performs no I/O. Conflicting positions remain unchanged and explicitly require confirmation.
public enum ReferenceContext {
    public static func enrich(_ reference: CodeReference, labels: [String]) -> CodeReference {
        guard let targetPath = reference.path, !targetPath.isEmpty, labels.count <= 32,
              labels.reduce(0, { $0 + $1.utf8.prefix(65_537).count }) <= 65_536 else { return reference }
        let targetName = basename(targetPath)
        let targetClass = (targetName as NSString).deletingPathExtension
        guard !targetName.isEmpty, !targetClass.isEmpty else { return reference }
        var candidates: [Supplement: CodeReference] = [:]
        var symbols: [String: String] = [:]
        var ambiguous = reference.contextAmbiguous

        for label in labels {
            // An AX label should be small; larger text nodes belong in the normal paragraph parser.
            guard label.utf8.prefix(4097).count <= 4096 else { continue }
            for candidate in ReferenceParser.parse(label) {
                guard matches(candidate, targetPath: targetPath, targetName: targetName, targetClass: targetClass),
                      matchesProject(candidate.projectHint, reference: reference, path: targetPath),
                      candidate.revision == nil || candidate.revision == reference.revision else { continue }
                let candidateSymbol = method(candidate.symbol, className: targetClass)
                let existingSymbol = method(reference.symbol, className: targetClass)
                if let candidateSymbol, let originalSymbol = candidate.symbol {
                    symbols[candidateSymbol] = originalSymbol
                }
                let positionMatches = compatible(reference.line, candidate.line)
                    && compatible(reference.endLine, candidate.endLine)
                    && compatible(reference.column, candidate.column)
                let symbolMatches = compatible(existingSymbol, candidateSymbol)
                if !positionMatches || !symbolMatches { ambiguous = true }
                // A title may describe a method accurately while its line is stale. Preserve
                // the target position and retain that unique method for the resolver to check.
                let canSupplementPosition = positionMatches && symbolMatches
                let addition = Supplement(
                    line: canSupplementPosition && reference.line == nil ? candidate.line : nil,
                    endLine: canSupplementPosition && reference.endLine == nil ? candidate.endLine : nil,
                    column: canSupplementPosition && reference.column == nil ? candidate.column : nil,
                    symbol: reference.symbol == nil ? candidateSymbol : nil
                )
                guard !addition.isEmpty else { continue }
                candidates[addition] = candidate

            }
        }
        if candidates.count > 1 || symbols.count > 1 { ambiguous = true }
        var result = reference
        if candidates.count == 1, symbols.count <= 1, let (addition, _) = candidates.first {
            result.line = result.line ?? addition.line
            result.endLine = result.endLine ?? addition.endLine
            result.column = result.column ?? addition.column
        }
        // Different spelling separators (Foo.method and Foo#method) identify one method.
        // Distinct method names remain ambiguous and must never be chosen arbitrarily.
        if result.symbol == nil, symbols.count == 1 { result.symbol = symbols.first?.value }
        result.contextAmbiguous = ambiguous
        return result
    }

    private static func matches(_ candidate: CodeReference, targetPath: String, targetName: String, targetClass: String) -> Bool {
        if let path = candidate.path {
            guard basename(path) == targetName else { return false }
            let normalizedPath = dropRelativePrefix(path)
            let normalizedTarget = dropRelativePrefix(targetPath)
            if normalizedPath.contains("/") {
                // A visible label with an explicit different location is stronger evidence than
                // its matching basename. A plain filename or matching suffix remains sufficient.
                if normalizedPath.hasPrefix("/") || normalizedPath.hasPrefix("~/") {
                    guard normalizedPath == normalizedTarget else { return false }
                } else if let ellipsis = normalizedPath.range(of: ".../", options: .backwards) {
                    let suffix = String(normalizedPath[ellipsis.upperBound...])
                    guard normalizedTarget.hasSuffix("/" + suffix) || normalizedTarget == suffix else { return false }
                } else {
                    guard normalizedTarget.hasSuffix("/" + normalizedPath) || normalizedTarget == normalizedPath else { return false }
                }
            }
            if let symbol = candidate.symbol, symbol.contains("#") || symbol.contains(".") {
                return symbol.split(whereSeparator: { $0 == "#" || $0 == "." }).first.map(String.init) == targetClass
            }
            return true
        }
        guard let symbol = candidate.symbol else { return false }
        return symbol.split(whereSeparator: { $0 == "#" || $0 == "." }).first.map(String.init) == targetClass
    }

    private static func matchesProject(_ hint: String?, reference: CodeReference, path: String) -> Bool {
        guard let hint else { return true }
        if let project = reference.projectHint { return hint == project }
        return path.split(separator: "/").contains(Substring(hint))
    }
    private static func method(_ symbol: String?, className: String) -> String? {
        guard let symbol, !symbol.isEmpty, symbol != className else { return nil }
        for separator in ["#", "."] {
            let prefix = className + separator
            if symbol.hasPrefix(prefix) { return String(symbol.dropFirst(prefix.count)) }
        }
        return symbol
    }
    private static func basename(_ path: String) -> String { (path as NSString).lastPathComponent }
    private static func dropRelativePrefix(_ path: String) -> String {
        var result = path
        while result.hasPrefix("./") { result.removeFirst(2) }
        return result
    }
    private static func compatible<T: Equatable>(_ existing: T?, _ candidate: T?) -> Bool {
        guard let existing, let candidate else { return true }
        return existing == candidate
    }
    private struct Supplement: Hashable {
        let line: Int?
        let endLine: Int?
        let column: Int?
        let symbol: String?
        var isEmpty: Bool { line == nil && endLine == nil && column == nil && symbol == nil }
    }
}
