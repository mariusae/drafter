import Foundation

/// Subsequence matching for "go to anything": every character of the query
/// appears in order in the candidate. Matches at word starts and in runs score
/// higher, so "wwsa" finds "Why We Should Start with APIs".
public enum Fuzzy {
    public struct Match: Sendable {
        public var score: Int
        /// Character offsets (in UTF-16) of the matched characters, for highlighting.
        public var ranges: [NSRange]
    }

    public static func match(_ query: String, in candidate: String) -> Match? {
        let needle = Array(query.lowercased().filter { !$0.isWhitespace })
        if needle.isEmpty { return Match(score: 0, ranges: []) }
        let haystack = Array(candidate)
        let lower = haystack.map { Character($0.lowercased()) }

        // Greedy from each possible start of the first character, keeping the
        // best: cheap, and good enough for titles.
        var best: Match?
        var start = 0
        while start < lower.count {
            guard let first = lower[start...].firstIndex(of: needle[0]) else { break }
            if let candidateMatch = scoreFrom(first, needle: needle, haystack: haystack, lower: lower),
               candidateMatch.score > (best?.score ?? .min) {
                best = candidateMatch
            }
            start = first + 1
        }
        return best
    }

    private static func scoreFrom(_ first: Int, needle: [Character], haystack: [Character], lower: [Character]) -> Match? {
        var score = 0
        var positions: [Int] = []
        var index = first
        var previous = -2
        for character in needle {
            guard let found = lower[index...].firstIndex(of: character) else { return nil }
            var points = 1
            if found == 0 { points += 8 }
            else if isBoundary(haystack, found) { points += 6 }
            if found == previous + 1 { points += 5 }
            else if previous >= 0 { points -= min(found - previous - 1, 5) }
            score += points
            positions.append(found)
            previous = found
            index = found + 1
        }
        // Shorter candidates are the more specific answer.
        score -= haystack.count / 16
        return Match(score: score, ranges: ranges(positions, in: haystack))
    }

    private static func isBoundary(_ text: [Character], _ index: Int) -> Bool {
        let before = text[index - 1]
        if before.isWhitespace || "-_/.:([".contains(before) { return true }
        return before.isLowercase && text[index].isUppercase
    }

    private static func ranges(_ positions: [Int], in text: [Character]) -> [NSRange] {
        // Character positions to UTF-16 ranges, merging runs.
        var offsets: [Int] = []
        offsets.reserveCapacity(text.count + 1)
        var utf16 = 0
        for character in text {
            offsets.append(utf16)
            utf16 += character.utf16.count
        }
        var result: [NSRange] = []
        for position in positions {
            let range = NSRange(location: offsets[position], length: text[position].utf16.count)
            if let last = result.last, NSMaxRange(last) == range.location {
                result[result.count - 1].length += range.length
            } else {
                result.append(range)
            }
        }
        return result
    }
}
