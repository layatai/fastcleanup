import Foundation

struct DiskScanner: Sendable {
    private static let sizeKeys: Set<URLResourceKey> =
        [.isRegularFileKey, .isDirectoryKey, .totalFileAllocatedSizeKey,
         .fileAllocatedSizeKey, .fileSizeKey]

    func collect(_ def: CategoryDefinition) -> [ScanItem] {
        switch def.strategy {
        case .children:                 return def.roots.flatMap { childrenItems(of: $0) }
        case .namedDirectories(let n):  return namedDirectories(Set(n), under: def.roots)
        case .cacheDirectories(let n):  return namedDirectories(Set(n), under: def.roots, skip: [], maxDepth: 6)
        case .namedFiles(let s):        return namedFiles(suffixes: s, under: def.roots)
        case .largeFiles(let m):        return largeFiles(minBytes: m, under: def.roots)
        case .oldFiles(let d):          return oldFiles(olderThanDays: d, under: def.roots)
        case .paths:                    return def.roots.compactMap { pathItem($0) }.sorted { $0.size > $1.size }
        case .gitRepositories(let m):   return gitRepositories(minBytes: m, under: def.roots)
        case .command(let s):           return commandItem(sizingRoots: s, def: def)
        }
    }

    /// A command-based category yields one representative item. Its size is the sum of
    /// the existing backing dirs (may be 0 when there's no cheap estimate). The item is
    /// always returned so the actionable category surfaces even at 0 bytes.
    func commandItem(sizingRoots: [URL], def: CategoryDefinition) -> [ScanItem] {
        let fm = FileManager.default
        var total: Int64 = 0
        var anchor: URL?
        for root in sizingRoots where fm.fileExists(atPath: root.path) {
            total += size(of: root)
            if anchor == nil { anchor = root }
        }
        let url = anchor ?? def.roots.first ?? fm.homeDirectoryForCurrentUser
        return [ScanItem(url: url, size: total, modified: nil)]
    }

    func pathItem(_ url: URL) -> ScanItem? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let s = size(of: url)
        guard s > 0 else { return nil }
        let mod = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        return ScanItem(url: url, size: s, modified: mod)
    }

    func gitRepositories(minBytes: Int64, under roots: [URL],
                         skip: Set<String> = ["Library", "Applications", ".Trash", "node_modules"]) -> [ScanItem] {
        let fm = FileManager.default
        var items: [ScanItem] = []
        for root in roots {
            guard let en = fm.enumerator(at: root,
                includingPropertiesForKeys: [.isDirectoryKey], options: []) else { continue }
            for case let url as URL in en {
                if Task.isCancelled { break }
                let name = url.lastPathComponent
                let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
                guard isDir else { continue }
                if name == ".git" {
                    let s = size(of: url)
                    if s >= minBytes {
                        // Item URL is the repo root (parent of .git); size is the .git footprint.
                        items.append(ScanItem(url: url.deletingLastPathComponent(), size: s, modified: nil))
                    }
                    en.skipDescendants()
                } else if skip.contains(name) {
                    en.skipDescendants()
                }
            }
        }
        return items.sorted { $0.size > $1.size }
    }

    func fileSize(_ url: URL) -> Int64 {
        let v = try? url.resourceValues(forKeys: Self.sizeKeys)
        return Int64(v?.totalFileAllocatedSize ?? v?.fileAllocatedSize ?? v?.fileSize ?? 0)
    }

    func size(of url: URL) -> Int64 {
        let rv = try? url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey])
        if rv?.isRegularFile == true { return fileSize(url) }
        guard rv?.isDirectory == true else { return 0 }
        guard let en = FileManager.default.enumerator(
            at: url, includingPropertiesForKeys: Array(Self.sizeKeys), options: []) else { return 0 }
        var total: Int64 = 0
        for case let child as URL in en {
            if Task.isCancelled { break }
            let v = try? child.resourceValues(forKeys: Self.sizeKeys)
            if v?.isRegularFile == true {
                total += Int64(v?.totalFileAllocatedSize ?? v?.fileAllocatedSize ?? v?.fileSize ?? 0)
            }
        }
        return total
    }

    func childrenItems(of root: URL) -> [ScanItem] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.contentModificationDateKey],
            options: []) else { return [] }
        var items: [ScanItem] = []
        for child in entries {
            if Task.isCancelled { break }
            let s = size(of: child)
            guard s > 0 else { continue }
            let mod = (try? child.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            items.append(ScanItem(url: child, size: s, modified: mod))
        }
        return items
    }

    func namedDirectories(_ names: Set<String>, under roots: [URL],
        skip: Set<String> = ["Library", "Applications", ".Trash", "Music",
                             "Movies", "Pictures", ".cache", ".npm", ".pnpm-store", ".git"],
        maxDepth: Int? = nil) -> [ScanItem] {
        let fm = FileManager.default
        var items: [ScanItem] = []
        for root in roots {
            let rootDepth = root.pathComponents.count
            guard let en = fm.enumerator(at: root,
                includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey],
                options: []) else { continue }
            for case let url as URL in en {
                if Task.isCancelled { break }
                let name = url.lastPathComponent
                let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
                guard isDir else { continue }
                if names.contains(name) {
                    let s = size(of: url)
                    if s > 0 {
                        let mod = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
                        items.append(ScanItem(url: url, size: s, modified: mod))
                    }
                    en.skipDescendants()
                } else if skip.contains(name) {
                    en.skipDescendants()
                } else if let maxDepth, url.pathComponents.count - rootDepth >= maxDepth {
                    en.skipDescendants()
                }
            }
        }
        return items.sorted { $0.size > $1.size }
    }

    /// Regular files whose name ends with any of `suffixes` (e.g. stale `*.vscdb.backup`
    /// snapshots editors leave in globalStorage). Matches by name, not size/date.
    func namedFiles(suffixes: [String], under roots: [URL]) -> [ScanItem] {
        let fm = FileManager.default
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .totalFileAllocatedSizeKey,
                                         .fileSizeKey, .contentModificationDateKey]
        var items: [ScanItem] = []
        for root in roots {
            guard let en = fm.enumerator(at: root, includingPropertiesForKeys: Array(keys),
                                         options: []) else { continue }
            for case let url as URL in en {
                if Task.isCancelled { break }
                guard suffixes.contains(where: { url.lastPathComponent.hasSuffix($0) }) else { continue }
                let v = try? url.resourceValues(forKeys: keys)
                guard v?.isRegularFile == true else { continue }
                let s = Int64(v?.totalFileAllocatedSize ?? v?.fileSize ?? 0)
                guard s > 0 else { continue }
                items.append(ScanItem(url: url, size: s, modified: v?.contentModificationDate))
            }
        }
        return items.sorted { $0.size > $1.size }
    }

    func largeFiles(minBytes: Int64, under roots: [URL]) -> [ScanItem] {
        scanFiles(under: roots) { size, _ in size >= minBytes }
    }

    func oldFiles(olderThanDays days: Int, under roots: [URL]) -> [ScanItem] {
        let cutoff = Date().addingTimeInterval(-Double(days) * 86_400)
        return scanFiles(under: roots) { size, mod in size > 0 && (mod ?? .distantFuture) < cutoff }
    }

    private func scanFiles(under roots: [URL],
                           _ match: (Int64, Date?) -> Bool) -> [ScanItem] {
        let fm = FileManager.default
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .totalFileAllocatedSizeKey,
                                         .fileSizeKey, .contentModificationDateKey]
        var items: [ScanItem] = []
        for root in roots {
            guard let en = fm.enumerator(at: root, includingPropertiesForKeys: Array(keys),
                                         options: [.skipsHiddenFiles]) else { continue }
            for case let url as URL in en {
                if Task.isCancelled { break }
                let v = try? url.resourceValues(forKeys: keys)
                guard v?.isRegularFile == true else { continue }
                let s = Int64(v?.totalFileAllocatedSize ?? v?.fileSize ?? 0)
                if match(s, v?.contentModificationDate) {
                    items.append(ScanItem(url: url, size: s, modified: v?.contentModificationDate))
                }
            }
        }
        return items.sorted { $0.size > $1.size }
    }
}
