import Foundation
import CleanerKit

/// Turns raw rule candidates into final items: removes protected paths and guarantees that every
/// path belongs to exactly one category (see `JunkCatalog` for the priority scheme).
enum JunkPlanner {
    static func assign(_ rules: [JunkRule], _ raw: [[JunkCandidate]], env: JunkEnvironment) -> [[JunkCandidate]] {
        var result = Array(repeating: [JunkCandidate](), count: rules.count)
        var claimed: [String] = []
        let order = rules.indices.sorted {
            rules[$0].priority != rules[$1].priority ? rules[$0].priority > rules[$1].priority : $0 < $1
        }
        // Higher-priority rules claim first, so a lower-priority folder that contains their paths
        // gets split instead of being counted twice.
        for i in order {
            var accepted: [JunkCandidate] = []
            for candidate in raw[i] {
                accepted += resolve(candidate, rule: rules[i], env: env, claimed: &claimed, depth: 0)
            }
            result[i] = accepted
        }
        return result
    }

    private static func resolve(_ candidate: JunkCandidate, rule: JunkRule, env: JunkEnvironment,
                                claimed: inout [String], depth: Int) -> [JunkCandidate] {
        if SafetyGuard.isProtected(candidate.url) { return [] }
        let key = FS.key(candidate.url)
        // Already owned (same path, or inside an owned path).
        if claimed.contains(where: { key == $0 || key.hasPrefix($0 + "/") }) { return [] }
        // Contains something owned by another item → offer its other children instead.
        if claimed.contains(where: { $0.hasPrefix(key + "/") }) {
            guard depth < 8, FS.isDirectory(candidate.url) else { return [] }
            return FS.children(of: candidate.url)
                .filter { !rule.excludes($0.lastPathComponent, env: env) }
                .flatMap { resolve(JunkCandidate($0), rule: rule, env: env, claimed: &claimed, depth: depth + 1) }
        }
        claimed.append(key)
        return [candidate]
    }
}
