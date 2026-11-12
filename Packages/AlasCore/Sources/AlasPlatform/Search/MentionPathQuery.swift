import Foundation

/// A worktree `@` query with a `/` in it. Every segment matches one folder
/// level, in order and without skipping levels: `al/so/ui` finds
/// `Alas/Sources/UI`, and `Alas/Sources/` lists that folder's children. A
/// segment matches its folder exactly, as a prefix, as a substring, or as a
/// fuzzy subsequence, in that order of preference. The chain may start at any
/// depth; among equally good matches, chains starting at the root rank first.
public enum MentionPathQuery: Sendable {
    public struct Match: Equatable, Sendable {
        public let url: URL
        /// Worktree-relative, without a trailing slash.
        public let relativePath: String
        /// Character offsets into `relativePath` of the letters the query matched.
        public let matchedOffsets: [Int]
        /// The folder a query ending in `/` names, listed so it can be attached.
        public let isQueriedFolder: Bool
    }

    public struct Result: Equatable, Sendable {
        public let matches: [Match]
        /// Relative path components of the one folder the segments before
        /// the last `/` resolve to; nil when several fit equally well.
        public let folder: [String]?
    }

    /// nil when `query` names no folder level or nothing matches, leaving
    /// the caller's plain fuzzy ranking.
    public static func match(files: [URL], query: String, limit: Int, relativeTo root: URL) -> Result? {
        var segments = query.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        let leaf = segments.removeLast()
        let folderSegments = segments.filter { !$0.isEmpty }
        guard !folderSegments.isEmpty else { return nil }

        var candidates: [Candidate] = []
        for file in files {
            let relativePath = relativePath(for: file, root: root)
            let components = relativePath.split(separator: "/").map(String.init)
            if leaf.isEmpty {
                // The folder itself, then its direct children.
                if file.hasDirectoryPath, let folder = candidate(
                    file, relativePath, components, folderSegments, start: components.count - folderSegments.count, leaf: nil
                ) {
                    candidates.append(folder)
                }
                if let child = candidate(
                    file, relativePath, components, folderSegments, start: components.count - folderSegments.count - 1, leaf: ""
                ) {
                    candidates.append(child)
                }
            } else if let match = candidate(
                file, relativePath, components, folderSegments, start: components.count - folderSegments.count - 1, leaf: leaf
            ) {
                candidates.append(match)
            }
        }
        guard !candidates.isEmpty else { return nil }

        candidates.sort(by: Candidate.ranksBefore)
        let best = candidates[0]
        var bestFolders = Set<ArraySlice<String>>()
        for candidate in candidates where candidate.folderTier == best.folderTier && candidate.anchored == best.anchored {
            bestFolders.insert(candidate.folder)
            if bestFolders.count > 1 { break }
        }
        // A folder can match both as the listed folder and as a child
        // (`a/` against `a/a`); its better-ranked reading wins.
        var seen = Set<URL>()
        var matches: [Match] = []
        for candidate in candidates where seen.insert(candidate.match.url).inserted {
            matches.append(candidate.match)
            if matches.count == limit { break }
        }
        return Result(matches: matches, folder: bestFolders.count == 1 ? Array(best.folder) : nil)
    }

    private struct Candidate {
        let match: Match
        let folder: ArraySlice<String>
        let folderTier: Int
        let folderScore: Double
        let anchored: Bool
        let leafTier: Int
        let leafScore: Double
        let isDirectory: Bool

        static func ranksBefore(_ lhs: Candidate, _ rhs: Candidate) -> Bool {
            if lhs.folderTier != rhs.folderTier { return lhs.folderTier > rhs.folderTier }
            if lhs.anchored != rhs.anchored { return lhs.anchored }
            if lhs.folderScore != rhs.folderScore { return lhs.folderScore > rhs.folderScore }
            if lhs.leafTier != rhs.leafTier { return lhs.leafTier > rhs.leafTier }
            if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
            if lhs.leafScore != rhs.leafScore { return lhs.leafScore > rhs.leafScore }
            return lhs.match.relativePath.localizedStandardCompare(rhs.match.relativePath) == .orderedAscending
        }
    }

    /// The listed folder itself sorts above any child.
    private static let queriedFolderTier = 5

    /// `components[start...]` against the folder segments, then the last
    /// component against `leaf`: nil `leaf` lists the folder itself, an empty
    /// one any child.
    private static func candidate(
        _ file: URL,
        _ relativePath: String,
        _ components: [String],
        _ folderSegments: [String],
        start: Int,
        leaf: String?
    ) -> Candidate? {
        guard start >= 0 else { return nil }
        var hits: [(position: Int, offsets: [Int])] = []
        var folderTier = 0
        var folderScore = 0.0
        for (index, segment) in folderSegments.enumerated() {
            let position = start + index
            guard let hit = match(segment: segment, component: components[position]) else { return nil }
            folderTier += hit.tier
            folderScore += hit.score
            hits.append((position, hit.offsets))
        }
        let folderEnd = start + folderSegments.count

        var leafTier = queriedFolderTier
        var leafScore = 0.0
        if let leaf {
            leafTier = 0
            if !leaf.isEmpty {
                let position = components.count - 1
                guard let hit = match(segment: leaf, component: components[position]) else { return nil }
                leafTier = hit.tier
                leafScore = hit.score
                hits.append((position, hit.offsets))
            }
        }

        // Component offsets in `relativePath`, only for files that matched.
        var componentStarts: [Int] = []
        var offset = 0
        for component in components {
            componentStarts.append(offset)
            offset += component.count + 1
        }
        let offsets = hits.flatMap { hit in hit.offsets.map { $0 + componentStarts[hit.position] } }

        return Candidate(
            match: Match(url: file, relativePath: relativePath, matchedOffsets: offsets, isQueriedFolder: leaf == nil),
            folder: components[..<folderEnd],
            folderTier: folderTier,
            folderScore: folderScore,
            anchored: start == 0,
            leafTier: leafTier,
            leafScore: leafScore,
            isDirectory: file.hasDirectoryPath
        )
    }

    /// Tier (exact 4, prefix 3, substring 2, subsequence 1), the fuzzy score
    /// of a subsequence match, and the matched character offsets in `component`.
    private static func match(segment: String, component: String) -> (tier: Int, score: Double, offsets: [Int])? {
        let needle = Array(segment.lowercased())
        let haystack = Array(component.lowercased())
        if haystack == needle { return (4, 0, Array(haystack.indices)) }
        if haystack.starts(with: needle) { return (3, 0, Array(needle.indices)) }
        if needle.count < haystack.count {
            for start in 1...(haystack.count - needle.count)
            where haystack[start..<(start + needle.count)].elementsEqual(needle) {
                return (2, 0, Array(start..<(start + needle.count)))
            }
        }
        guard let fuzzy = FuzzyMatch.score(query: segment, target: component) else { return nil }
        return (1, fuzzy.score, fuzzy.indices)
    }

    private static func relativePath(for file: URL, root: URL) -> String {
        let rootPath = root.standardizedFileURL.path
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        var path = file.standardizedFileURL.path
        if path.hasPrefix(prefix) { path.removeFirst(prefix.count) }
        while path.hasSuffix("/") { path.removeLast() }
        return path
    }
}
