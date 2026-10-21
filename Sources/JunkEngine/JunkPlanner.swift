import Foundation
import CleanerKit

/// Turns raw rule candidates into final items: removes protected paths and guarantees that every
/// path belongs to exactly one category (see `JunkCatalog` for the priority scheme).
enum JunkPlanner {
    /// - Parameter isProtected: the safety check applied to every candidate; injectable so tests can measure
    ///   the planner on its own (the real check resolves symlinks and costs a few syscalls per path).
    static func assign(_ rules: [JunkRule], _ raw: [[JunkCandidate]], env: JunkEnvironment,
                       isProtected: (URL) -> Bool = { SafetyGuard.isProtected($0) }) -> [[JunkCandidate]] {
        var result = Array(repeating: [JunkCandidate](), count: rules.count)
        var claimed = ClaimedPaths()
        let order = rules.indices.sorted {
            rules[$0].priority != rules[$1].priority ? rules[$0].priority > rules[$1].priority : $0 < $1
        }
        // Higher-priority rules claim first, so a lower-priority folder that contains their paths
        // gets split instead of being counted twice.
        for i in order {
            var accepted: [JunkCandidate] = []
            for candidate in raw[i] {
                accepted += resolve(candidate, rule: rules[i], env: env, claimed: &claimed, depth: 0, isProtected: isProtected)
            }
            result[i] = accepted
        }
        return result
    }

    private static func resolve(_ candidate: JunkCandidate, rule: JunkRule, env: JunkEnvironment,
                                claimed: inout ClaimedPaths, depth: Int,
                                isProtected: (URL) -> Bool) -> [JunkCandidate] {
        let key = FS.key(candidate.url)
        // Cheap rejections first: already owned (same path, or inside an owned path), or protected.
        if claimed.coversOrInside(key) || isProtected(candidate.url) { return [] }
        // Contains something owned by another item → offer its other children instead.
        if claimed.containsClaimed(inside: key) {
            guard depth < 8, FS.isDirectory(candidate.url) else { return [] }
            return FS.children(of: candidate.url)
                .filter { !rule.excludes($0.lastPathComponent, env: env) }
                .flatMap { resolve(JunkCandidate($0), rule: rule, env: env, claimed: &claimed, depth: depth + 1, isProtected: isProtected) }
        }
        claimed.claim(key)
        return [candidate]
    }
}

/// The set of already-owned paths (comparison keys, see `FS.key`) with O(depth) queries.
/// A plain array of claimed paths made every query O(n) and the whole scan quadratic (8k items ≈ 7 s).
struct ClaimedPaths {
    private var claimed = Set<String>()
    /// Every proper ancestor of every claimed path.
    private var ancestors = Set<String>()

    var count: Int { claimed.count }

    /// True when `key` itself, or any folder above it, is claimed.
    func coversOrInside(_ key: String) -> Bool {
        if claimed.contains(key) { return true }
        var end = key.endIndex
        while let slash = key[..<end].lastIndex(of: "/") {
            if slash == key.startIndex { break }
            end = slash
            if claimed.contains(String(key[..<end])) { return true }
        }
        return false
    }

    /// True when something strictly below `key` is claimed.
    func containsClaimed(inside key: String) -> Bool { ancestors.contains(key) }

    mutating func claim(_ key: String) {
        guard claimed.insert(key).inserted else { return }
        var end = key.endIndex
        while let slash = key[..<end].lastIndex(of: "/") {
            if slash == key.startIndex { break }
            end = slash
            // Ancestors of an ancestor are already present once one is.
            if !ancestors.insert(String(key[..<end])).inserted { break }
        }
    }
}
