import Foundation

// MARK: - Palette Filter
//
// Pure query matching for the Action Palette. Kept free of Cocoa so it
// can be unit-tested headlessly. Matching rule: every whitespace-separated
// token of the query must appear (case-insensitively, as a substring) in
// the target text. Empty query matches everything.

enum PaletteFilter {

    static func matches(_ query: String, in text: String) -> Bool {
        let tokens = query
            .lowercased()
            .split(whereSeparator: { $0.isWhitespace })
        if tokens.isEmpty { return true }
        let haystack = text.lowercased()
        return tokens.allSatisfy { haystack.contains($0) }
    }
}
