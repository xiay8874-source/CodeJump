import Foundation

/// A bounded, local parser. It deliberately keeps ambiguous references separate for the resolver.
public enum ReferenceParser {
    private static let maximumInputBytes = 65_536
    private static let maximumReferences = 128
    private static let maximumLineBytes = 4096
    private static let extensions = "java|kt|kts|swift|m|mm|h|hpp|c|cc|cpp|cs|fs|go|rs|py|pyi|rb|php|scala|sc|groovy|js|jsx|ts|tsx|vue|svelte|html|css|scss|sass|less|sql|sh|bash|zsh|xml|json|yaml|yml|toml|md|mdx|gradle|properties|proto|dart|ex|exs|erl|hrl|clj|cljs|lua|r|R"
    private static let position = #"(?::[0-9]+(?:-[0-9]+|:[0-9]+)?|#L[0-9]+(?:-L?[0-9]+)?)?"#
    private static let markdown = regex(#"!?\[([^\[\]\r\n]*)\]\(((?:[^()\r\n]|\([^()\r\n]*\))*)\)"#)
    private static let angleURL = regex(#"<([A-Za-z][A-Za-z0-9+.-]*://[^<>\r\n]+)>"#)
    private static let url = regex(#"[A-Za-z][A-Za-z0-9+.-]*://[^\s<>\"`]+"#)
    private static let inlineCode = regex(#"`([^`\r\n]+)`"#)
    private static let quotedPath = regex(#"[\"“]([^\"”\r\n]+)[\"”]"#)
    private static let revisionReference = regex(#"(?<![\w@])([A-Za-z][\w.-]*@[A-Za-z0-9_./-]+:[^\s`<>\"，。]+)"#)
    private static let absolutePath = regex(#"(?<![\w:/])((?:~/|/)(?=\S)(?:[^\r\n`<>\"|;]*?)\.(?:"# + extensions + ")" + position + #")(?=$|[\s,;，。、)）\]}>行])"#)
    private static let relativePath = regex(#"(?<![\w./:@-])((?:[\p{L}\p{N}_.$@+~()-]+/)*[\p{L}\p{N}_.$@+~-]+\.(?:"# + extensions + ")" + position + #")(?=$|[\s,;，。、)）\]}>行])"#)
    private static let symbolReference = regex(#"(?<![A-Za-z0-9_./:@$-])((?:[a-z][A-Za-z0-9_$]*\.)*[A-Z][A-Za-z0-9_$]*(?:[.#][A-Za-z_$][A-Za-z0-9_$]*)*(?:\([^()\r\n]{0,256}\))?(?::[0-9]+(?:-[0-9]+|:[0-9]+)?|#L[0-9]+(?:-L?[0-9]+)?)?)(?![A-Za-z0-9_./:#$-])"#)
    private static let sourceExtension = regex(#"\.(?:"# + extensions + #")(?=$|[^\p{L}\p{N}_])"#, options: [.caseInsensitive])
    private static let fileEnding = regex(#"\.(?:"# + extensions + ")$", options: [.caseInsensitive])
    private static let locationSuffix = regex(#"(?::([0-9]+)(?:-([0-9]+)|:([0-9]+))?|#L([0-9]+)(?:-L?([0-9]+))?)$"#)
    private static let adjacentLines = regex(#"^\s*[（(]\s*(?:第\s*)?([0-9]+)(?:\s*[-–—至]\s*([0-9]+))?\s*行\s*[）)]"#)
    private static let bareClass = regex(#"^[A-Z][A-Za-z0-9_$]*$"#)
    private static let distinctiveClass = regex(#"^[A-Z][A-Za-z0-9_$]*[A-Z][a-z][A-Za-z0-9_$]*$"#)
    private static let symbolOnly = regex(#"^(?:[a-z][A-Za-z0-9_$]*\.)*[A-Z][A-Za-z0-9_$]*(?:[.#][A-Za-z_$][A-Za-z0-9_$]*)*$"#)
    private static let projectPrefix = regex(#"^([A-Za-z][A-Za-z0-9_.-]*)\s+/\s+(.+)$"#)
    private static let precedingProject = regex(#"(?:^|\s)([A-Za-z][A-Za-z0-9_.-]*)\s+/\s*$"#)
    private static let revisionPrefix = regex(#"^([A-Za-z][A-Za-z0-9_.-]*)@([A-Za-z0-9_./-]{1,128}):(.+)$"#)
    private static let revisionMethod = regex(#"^(.*(?:\.[A-Za-z]+)(?::[0-9]+(?:-[0-9]+|:[0-9]+)?|#L[0-9]+(?:-L?[0-9]+)?))/([^/\s]+)$"#)

    /// Opt-in for a caller that obtained an exact class label from an accessibility element.
    /// Generic prose should use `parse`, which does not treat a word like "Hello" as a class.
    public static func parseClassLabel(_ text: String) -> CodeReference? {
        let label = text.trimmingCharacters(in: .whitespaces)
        guard label.utf8.count <= 256, safe(label), first(bareClass, label) != nil,
              label.contains(where: { $0.isLowercase }) else { return nil }
        return CodeReference(source: text, symbol: label)
    }

    public static func parse(_ text: String) -> [CodeReference] {
        var seen = Set<Identity>()
        return Array(parseLocated(text).map(\.reference).filter { seen.insert(Identity($0)).inserted }.prefix(maximumReferences))
    }

    public static func parseLocated(_ text: String) -> [LocatedReference] {
        guard !text.isEmpty, text.utf8.prefix(maximumInputBytes + 1).count <= maximumInputBytes else { return [] }
        let original = text as NSString
        let remainder = NSMutableString(string: text)
        var found: [LocatedReference] = []

        func mask(_ range: NSRange) {
            remainder.replaceCharacters(in: range, with: String(repeating: " ", count: range.length))
        }
        func record(_ reference: CodeReference?, at range: NSRange, adjacent: Bool = false) {
            guard var reference, found.count < 4096 else { return }
            var occurrenceRange = range
            if adjacent, reference.line == nil {
                let tailRange = NSRange(location: NSMaxRange(range), length: min(64, original.length - NSMaxRange(range)))
                let tail = original.substring(with: tailRange)
                if let match = first(adjacentLines, tail), let line = positiveInt(group(match, 1, tail)),
                   let end = optionalLine(group(match, 2, tail)), end.value == nil || end.value! >= line {
                    reference.line = line
                    reference.endLine = end.value
                    reference.source += (tail as NSString).substring(with: match.range)
                    occurrenceRange.length += NSMaxRange(match.range)
                }
            }
            if reference.projectHint == nil {
                let start = max(0, range.location - 100)
                let prefix = original.substring(with: NSRange(location: start, length: range.location - start))
                if let hint = first(precedingProject, prefix) { reference.projectHint = group(hint, 1, prefix) }
            }
            found.append(LocatedReference(reference: reference, range: occurrenceRange))
        }

        // Accessibility APIs sometimes return an entire document. Ignore oversized individual
        // lines before regular expressions, preserving offsets for the remaining useful lines.
        text.enumerateSubstrings(in: text.startIndex..., options: .byLines) { substring, range, _, _ in
            if let substring, substring.utf8.prefix(maximumLineBytes + 1).count > maximumLineBytes {
                mask(NSRange(range, in: text))
            }
        }

        // Reserve entire links, including titles: a rejected web URL must never become a local path.
        for match in matches(markdown, String(remainder)) {
            var target = group(match, 2, text).trimmingCharacters(in: .whitespaces)
            if target.hasPrefix("<"), let end = target.firstIndex(of: ">") { target = String(target[target.index(after: target.startIndex)..<end]) }
            else if let title = target.range(of: #"\s+[\"'].*[\"']$"#, options: .regularExpression) { target.removeSubrange(title) }
            var ref = atom(target, source: original.substring(with: match.range), allowBareClass: false)
            let label = group(match, 1, text)
            if let labelRef = atom(label, source: label, allowBareClass: false), labelRef.path == nil,
               let symbol = labelRef.symbol, label.contains("#") || label.contains(".") {
                if ref?.symbol == nil { ref?.symbol = symbol; ref?.parameterSignature = labelRef.parameterSignature }
            }
            record(ref, at: match.range, adjacent: true)
            mask(match.range)
        }
        for match in matches(angleURL, String(remainder)) {
            let target = original.substring(with: match.range(at: 1))
            record(atom(target, source: original.substring(with: match.range), allowBareClass: false), at: match.range)
            mask(match.range)
        }
        for match in matches(url, String(remainder)) {
            let raw = original.substring(with: match.range)
            let target = raw.trimmingCharacters(in: CharacterSet(charactersIn: ".,;，。)）]}"))
            record(atom(target, source: raw, allowBareClass: false), at: match.range)
            mask(match.range)
        }
        for pattern in [inlineCode, quotedPath] {
            for match in matches(pattern, String(remainder)) {
                let target = original.substring(with: match.range(at: 1))
                record(atom(target, source: original.substring(with: match.range), allowBareClass: pattern === inlineCode), at: match.range, adjacent: true)
                mask(match.range)
            }
        }
        for match in matches(revisionReference, String(remainder)) {
            let raw = original.substring(with: match.range(at: 1)).trimmingCharacters(in: CharacterSet(charactersIn: ",;，。)）]}"))
            record(atom(raw, source: raw, allowBareClass: false), at: match.range)
            mask(match.range)
        }
        // Absolute paths may contain spaces. Relative paths with spaces are supported when quoted,
        // inside a Markdown link, in inline code, or when the whole input is one reference.
        if found.isEmpty, canBeWholeReference(text), let ref = atom(text, source: text, allowBareClass: first(distinctiveClass, text.trimmingCharacters(in: .whitespaces)) != nil) {
            return [LocatedReference(reference: ref, range: NSRange(location: 0, length: original.length))]
        }
        let pathPatterns = first(sourceExtension, String(remainder)) == nil
            ? [symbolReference] : [absolutePath, relativePath, symbolReference]
        for pattern in pathPatterns {
            for match in matches(pattern, String(remainder)) {
                let raw = original.substring(with: match.range(at: 1))
                record(atom(raw, source: raw, allowBareClass: false), at: match.range, adjacent: true)
                mask(match.range)
            }
        }
        return found.sorted { $0.range.location < $1.range.location }
    }

    private static func atom(_ input: String, source: String, allowBareClass: Bool) -> CodeReference? {
        var value = input.trimmingCharacters(in: .whitespaces)
        guard safe(value), value.utf8.count <= 4096 else { return nil }
        if value.contains("://") { return urlReference(value, source: source) }
        // Do not accept alternate URI schemes, drive paths, or shell fragments as relative files.
        if value.hasPrefix("javascript:"), value.hasPrefix("data:"), value.hasPrefix("vscode:") { return nil }
        var hint: String?
        var revision: String?
        var method: String?
        if let match = first(projectPrefix, value) { hint = group(match, 1, value); value = group(match, 2, value) }
        if let match = first(revisionPrefix, value) {
            hint = group(match, 1, value); revision = group(match, 2, value); value = group(match, 3, value)
            if let suffix = first(revisionMethod, value) { method = group(suffix, 2, value); value = group(suffix, 1, value) }
        }
        var line: Int?
        var endLine: Int?
        var column: Int?
        if let suffix = first(locationSuffix, value) {
            let firstLine = group(suffix, 1, value).isEmpty ? group(suffix, 4, value) : group(suffix, 1, value)
            guard let start = positiveInt(firstLine),
                  let end = optionalLine(group(suffix, 2, value).isEmpty ? group(suffix, 5, value) : group(suffix, 2, value)),
                  let col = optionalLine(group(suffix, 3, value)), end.value == nil || end.value! >= start else { return nil }
            line = start; endLine = end.value; column = col.value
            value = (value as NSString).substring(to: suffix.range.location)
        }
        var signature: String?
        if let open = value.firstIndex(of: "("), value.hasSuffix(")") {
            let base = String(value[..<open])
            guard symbolName(base) != nil else { return nil }
            signature = String(value[value.index(after: open)..<value.index(before: value.endIndex)])
            value = base
        }
        guard safe(value), !value.contains(":"), !value.contains("#"), !value.isEmpty else {
            // A # may be a Java-style method separator, but never part of a file path.
            if !value.contains(":"), let symbol = symbolName(value), value.contains("#") {
                return CodeReference(source: source, symbol: symbol, line: line, endLine: endLine, column: column, projectHint: hint, revision: revision, parameterSignature: signature)
            }
            return nil
        }
        if first(fileEnding, value) != nil {
            guard validPath(value) else { return nil }
            return CodeReference(source: source, path: value, symbol: method, line: line, endLine: endLine, column: column, projectHint: hint, revision: revision, parameterSignature: signature)
        }
        if let symbol = symbolName(value), line != nil || value.contains(".") || allowBareClass {
            // All-caps log levels and constant names are not useful unqualified class references.
            guard value.contains(where: { $0.isLowercase }) else { return nil }
            return CodeReference(source: source, symbol: symbol, line: line, endLine: endLine, column: column, projectHint: hint, revision: revision, parameterSignature: signature)
        }
        return nil
    }

    private static func urlReference(_ value: String, source: String) -> CodeReference? {
        guard let decoded = value.removingPercentEncoding, safe(decoded), let components = URLComponents(string: value), components.user == nil, components.password == nil, components.port == nil else { return nil }
        switch components.scheme?.lowercased() {
        case "file":
            guard components.host == nil || components.host == "" || components.host?.lowercased() == "localhost",
                  components.query == nil, components.path.hasPrefix("/") else { return nil }
            guard let decodedPath = components.percentEncodedPath.removingPercentEncoding else { return nil }
            let target = decodedPath + (components.fragment.map { "#" + $0 } ?? "")
            return atom(target, source: source, allowBareClass: false)
        case "codejump":
            guard components.host?.lowercased() == "open", components.path.isEmpty || components.path == "/", components.fragment == nil else { return nil }
            var query: [String: String] = [:]
            for item in components.queryItems ?? [] {
                guard ["path", "line", "endLine", "column", "project", "symbol", "revision"].contains(item.name), query[item.name] == nil,
                      let value = item.value, safe(value) else { return nil }
                query[item.name] = value
            }
            guard let path = query["path"], var reference = atom(path, source: source, allowBareClass: false), reference.path != nil else { return nil }
            if let raw = query["line"] { guard let line = positiveInt(raw) else { return nil }; reference.line = line }
            if let raw = query["endLine"] { guard let end = positiveInt(raw), let line = reference.line, end >= line else { return nil }; reference.endLine = end }
            if let raw = query["column"] { guard let col = positiveInt(raw), reference.line != nil else { return nil }; reference.column = col }
            if let project = query["project"] { guard project.utf8.count <= 256 else { return nil }; reference.projectHint = project }
            if let symbol = query["symbol"] { guard symbol.utf8.count <= 256 else { return nil }; reference.symbol = symbol }
            if let revision = query["revision"] { guard revision.utf8.count <= 128 else { return nil }; reference.revision = revision }
            if let end = reference.endLine, let line = reference.line, end < line { return nil }
            return reference
        default:
            return nil
        }
    }

    private static func canBeWholeReference(_ value: String) -> Bool {
        guard !value.contains("\n"), !value.contains("\r") else { return false }
        if first(projectPrefix, value) != nil || first(revisionPrefix, value) != nil { return true }
        let leading = value.trimmingCharacters(in: .whitespaces).split(separator: "/", omittingEmptySubsequences: false).first ?? ""
        return !leading.contains(where: \.isWhitespace)
    }
    private static func validPath(_ value: String) -> Bool {
        guard !value.contains("="), !value.hasPrefix("-"), !value.contains("?"), !value.contains("*") else { return false }
        // Bare prose ending in a filename is not a relative path containing spaces.
        if !value.contains("/"), value.contains(where: \.isWhitespace) { return false }
        return true
    }
    private static func safe(_ value: String) -> Bool {
        !value.isEmpty && !value.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) || $0.value == 0x2028 || $0.value == 0x2029 }
        && !value.contains("$(") && !value.contains("`") && !value.contains(";") && !value.contains("|")
    }
    private static func symbolName(_ value: String) -> String? { first(symbolOnly, value) == nil ? nil : value }
    private static func positiveInt(_ value: String) -> Int? {
        guard !value.isEmpty, value.utf8.count <= 8, value.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }), let number = Int(value), number > 0, number <= 10_000_000 else { return nil }
        return number
    }
    private struct OptionalLine { let value: Int? }
    private static func optionalLine(_ value: String) -> OptionalLine? {
        value.isEmpty ? OptionalLine(value: nil) : positiveInt(value).map { OptionalLine(value: $0) }
    }
    private struct Identity: Hashable {
        let path: String?, symbol: String?, line: Int?, endLine: Int?, column: Int?, project: String?, revision: String?, signature: String?
        init(_ reference: CodeReference) {
            path = reference.path; symbol = reference.symbol; line = reference.line; endLine = reference.endLine
            column = reference.column; project = reference.projectHint; revision = reference.revision; signature = reference.parameterSignature
        }
    }
    private static func regex(_ pattern: String, options: NSRegularExpression.Options = []) -> NSRegularExpression { try! NSRegularExpression(pattern: pattern, options: options) }
    private static func matches(_ regex: NSRegularExpression, _ text: String) -> [NSTextCheckingResult] { regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) }
    private static func first(_ regex: NSRegularExpression, _ text: String) -> NSTextCheckingResult? { regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) }
    private static func group(_ match: NSTextCheckingResult, _ index: Int, _ text: String) -> String {
        let range = match.range(at: index)
        return range.location == NSNotFound ? "" : (text as NSString).substring(with: range)
    }
}
