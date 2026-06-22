import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// Runs external cleanup tools (brew, docker, pnpm, fclones) for command-based
/// categories. Mirrors the `Process` pattern in `GitMaintenance.swift` but captures
/// output so failures can be surfaced to the user.
enum CommandRunner {
    /// Where GUI apps (which don't inherit a login shell PATH) should look for tools.
    private static let searchDirs = [
        "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin",
    ]

    struct Output: Sendable {
        let code: Int32
        let stdout: String
        let stderr: String
        var ok: Bool { code == 0 }
    }

    private static let cacheLock = NSLock()
    nonisolated(unsafe) private static var resolveCache: [String: URL?] = [:]

    /// Resolve a tool name to an executable URL, or nil if it isn't installed.
    /// Falls back to the user's login shell so tools installed via nvm/volta/asdf/etc.
    /// (which a GUI app's minimal PATH wouldn't see) are still found. Cached per session.
    static func resolve(_ name: String) -> URL? {
        cacheLock.lock()
        if let cached = resolveCache[name] { cacheLock.unlock(); return cached }
        cacheLock.unlock()
        let result = uncachedResolve(name)
        cacheLock.lock(); resolveCache[name] = result; cacheLock.unlock()
        return result
    }

    private static func uncachedResolve(_ name: String) -> URL? {
        let fm = FileManager.default
        for dir in searchDirs {
            let u = URL(fileURLWithPath: dir).appendingPathComponent(name)
            if fm.isExecutableFile(atPath: u.path) { return u }
        }
        // Login shell carries the user's real PATH (Homebrew, nvm, volta, asdf …).
        if let out = try? loginShell("command -v \(name) 2>/dev/null"), out.ok {
            // Interactive shells can print prompt noise; take the last absolute path line.
            let line = out.stdout
                .split(separator: "\n")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .last(where: { $0.hasPrefix("/") && fm.isExecutableFile(atPath: $0) })
            if let line { return URL(fileURLWithPath: line) }
        }
        return nil
    }

    static func hasBinary(_ name: String) -> Bool { resolve(name) != nil }

    /// Forget cached resolutions (e.g. after installing a tool).
    static func clearCache() {
        cacheLock.lock(); resolveCache.removeAll(); cacheLock.unlock()
    }

    /// True when the path lives on an APFS volume (required for clone-dedupe).
    static func isAPFS(_ url: URL) -> Bool {
        var s = statfs()
        guard statfs(url.path, &s) == 0 else { return false }
        let type = withUnsafePointer(to: &s.f_fstypename) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MFSTYPENAMELEN)) {
                String(cString: $0)
            }
        }
        return type == "apfs"
    }

    @discardableResult
    static func run(_ cmd: ShellCommand) -> Output {
        guard hasBinary(cmd.executable) else {
            return Output(code: 127, stdout: "", stderr: "\(cmd.executable): command not found")
        }
        // Run through the login shell so the full user environment is present — node-based
        // tools like pnpm need `node` on PATH, which a GUI app otherwise lacks.
        let line = ([cmd.executable] + cmd.arguments).map(shellQuote).joined(separator: " ")
        return (try? loginShell(line))
            ?? Output(code: -1, stdout: "", stderr: "failed to launch \(cmd.executable)")
    }

    private static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Run a command line via the user's interactive login shell.
    private static func loginShell(_ line: String) throws -> Output {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        return try capture(URL(fileURLWithPath: shell), ["-lic", line])
    }

    /// Two-stage APFS clone-dedupe of every `node_modules` under `roots`:
    /// `fclones group <dirs> > report`, then `fclones dedupe < report` (non-destructive —
    /// identical files become copy-on-write clones). Returns the dedupe stage output.
    static func dedupeNodeModules(under roots: [URL], scanner: DiskScanner) -> Output {
        guard let fclones = resolve("fclones") else {
            return Output(code: 127, stdout: "", stderr: "fclones is not installed")
        }
        let dirs = scanner.namedDirectories(["node_modules"], under: roots).map(\.url.path)
        guard !dirs.isEmpty else {
            return Output(code: 0, stdout: "", stderr: "no node_modules found")
        }

        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("fclones-\(UUID().uuidString).txt")
        FileManager.default.createFile(atPath: tmp.path, contents: nil)
        defer { try? FileManager.default.removeItem(at: tmp) }

        // Stage 1: group duplicates into a report file.
        guard let writeHandle = try? FileHandle(forWritingTo: tmp) else {
            return Output(code: -1, stdout: "", stderr: "could not create temp report")
        }
        let group = Process()
        group.executableURL = fclones
        group.arguments = ["group"] + dirs
        group.standardOutput = writeHandle
        group.standardError = FileHandle.nullDevice
        do {
            try group.run()
            group.waitUntilExit()
        } catch {
            try? writeHandle.close()
            return Output(code: -1, stdout: "", stderr: "fclones group failed: \(error.localizedDescription)")
        }
        try? writeHandle.close()

        // Stage 2: dedupe (apply) consuming the report on stdin.
        guard let readHandle = try? FileHandle(forReadingFrom: tmp) else {
            return Output(code: -1, stdout: "", stderr: "could not read temp report")
        }
        defer { try? readHandle.close() }
        return (try? capture(fclones, ["dedupe"], stdin: readHandle))
            ?? Output(code: -1, stdout: "", stderr: "fclones dedupe failed")
    }

    private static func capture(_ exe: URL, _ args: [String], stdin: FileHandle? = nil) throws -> Output {
        let p = Process()
        p.executableURL = exe
        p.arguments = args
        let outPipe = Pipe()
        let errPipe = Pipe()
        p.standardOutput = outPipe
        p.standardError = errPipe
        if let stdin { p.standardInput = stdin }
        try p.run()
        // Read before waiting to avoid deadlock if the pipe buffer fills.
        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return Output(
            code: p.terminationStatus,
            stdout: String(decoding: outData, as: UTF8.self),
            stderr: String(decoding: errData, as: UTF8.self),
        )
    }
}
