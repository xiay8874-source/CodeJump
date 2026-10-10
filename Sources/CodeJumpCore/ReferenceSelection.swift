import Foundation

/// Pure selection policy shared by accessibility capture and regression tests.
public enum ReferenceSelection {
    public static func select(text: String, utf16Offset: Int?) -> [CodeReference] {
        let occurrences = ReferenceParser.parseLocated(text)
        let symbols = contextSymbols(text)
        if let offset = utf16Offset {
            let hit = occurrences.filter { NSLocationInRange(offset, $0.range) }
            if !hit.isEmpty { return hit.map(\.reference) }
            if let hit = symbols.first(where: { NSLocationInRange(offset, $0.range) }) { return [hit.reference] }
        }
        return (occurrences + symbols.filter { symbol in
            !occurrences.contains { NSIntersectionRange($0.range, symbol.range).length > 0 }
        }).prefix(128).map {
            var reference = $0.reference
            // Having a pointer coordinate that misses a reference is not authority to open
            // the nearest one, even when the paragraph contains only one valid reference.
            if utf16Offset != nil || symbols.contains(where: { $0.reference == reference }) { reference.isFallback = true }
            return reference
        }
    }
    /// Only distinctive CamelCase symbols are mined from a paragraph. All context results
    /// require confirmation unless an actual AX character offset hits the occurrence.
    private static func contextSymbols(_ text: String) -> [LocatedReference] {
        guard text.utf8.prefix(65_537).count <= 65_536 else { return [] }
        let regex = try! NSRegularExpression(pattern: #"(?<![A-Za-z0-9_$./:#])[A-Za-z_$][A-Za-z0-9_$]{2,127}(?![A-Za-z0-9_$./:#])"#)
        let input = text as NSString
        let reserved = try! NSRegularExpression(pattern: #"!?\[[^\]\r\n]*\]\([^\r\n]*\)|[A-Za-z][A-Za-z0-9+.-]*://[^\s<>`]+"#)
        let reservedRanges = reserved.matches(in: text, range: NSRange(location: 0, length: input.length)).map(\.range)
        return regex.matches(in: text, range: NSRange(location: 0, length: input.length)).prefix(512).compactMap { match in
            guard !reservedRanges.contains(where: { NSIntersectionRange($0, match.range).length > 0 }) else { return nil }
            let value = input.substring(with: match.range)
            guard value.dropFirst().contains(where: { $0.isUppercase }), value.contains(where: { $0.isLowercase }) else { return nil }
            // Never mine local symbols from a rejected URL, including its query parameters.
            let before = input.substring(to: match.range.location).split(whereSeparator: { $0.isWhitespace || $0 == "`" }).last.map(String.init) ?? ""
            if before.contains("://") { return nil }
            guard let reference = ReferenceParser.parseExplicitLabel(value) else { return nil }
            return LocatedReference(reference: reference, range: match.range)
        }
    }

}
