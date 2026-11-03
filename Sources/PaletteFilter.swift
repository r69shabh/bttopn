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

// MARK: - MRU ordering
//
// Pure most-recently-used reorder for palette results. `mru` is the stored
// list of stable entry ids, most recent first. Hits come first (MRU order),
// everything else keeps its original relative order. Duplicate ids in `mru`
// are ignored; stable — only exact id matches are reordered. O(n·m), fine
// for a few hundred entries.

enum PaletteMRU {

    static func ordered<T>(_ items: [T], mru: [String], id: (T) -> String) -> [T] {
        guard !mru.isEmpty else { return items }

        var hits: [T] = []
        var seen = Set<String>()
        for key in mru {
            if seen.contains(key) { continue }
            if let match = items.first(where: { id($0) == key }) {
                hits.append(match)
                seen.insert(key)
            }
        }
        let rest = items.filter { !seen.contains(id($0)) }
        return hits + rest
    }
}
