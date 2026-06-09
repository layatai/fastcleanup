import Foundation

/// Runs `git gc` to repack a repository's history. This reclaims space inside
/// `.git` (loose objects, stale packs, reflog) without losing any commits.
enum GitMaintenance {
    static func gc(at repo: URL) {
        let git = URL(fileURLWithPath: "/usr/bin/git")
        guard FileManager.default.isExecutableFile(atPath: git.path) else { return }
        let p = Process()
        p.executableURL = git
        p.arguments = ["-C", repo.path, "gc", "--prune=now", "--quiet"]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do {
            try p.run()
            p.waitUntilExit()
        } catch {
            // git unavailable or repo locked — skip silently
        }
    }
}
