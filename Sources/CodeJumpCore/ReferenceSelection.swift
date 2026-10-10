import Foundation

/// Pure selection policy shared by accessibility capture and regression tests.
public enum ReferenceSelection {
    public static func select(text: String, utf16Offset: Int?) -> [CodeReference] {
        let occurrences = ReferenceParser.parseLocated(text)
        if let offset = utf16Offset {
            let hit = occurrences.filter { NSLocationInRange(offset, $0.range) }
            if !hit.isEmpty { return hit.map(\.reference) }
        }
        return occurrences.map {
            var reference = $0.reference
            // Having a pointer coordinate that misses a reference is not authority to open
            // the nearest one, even when the paragraph contains only one valid reference.
            if utf16Offset != nil { reference.isFallback = true }
            return reference
        }
    }
}
