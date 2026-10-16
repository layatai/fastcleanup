import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

public enum CleanupError: Error, Equatable, LocalizedError {
    case protectedPath, unsafeFile, changedFile, unreadableFile, tooManyEntries, invalidSelection
    case stalePlan, expiredPlan, unknownPlan, destinationExists, unsupportedPlatform
    public var errorDescription: String? {
        switch self {
        case .protectedPath: return "A protected or excluded path overlaps this item."
        case .unsafeFile: return "This item contains a link, cloud item, mount boundary, or unsupported file type."
        case .changedFile: return "Files changed since analysis. Rescan and review again."
        case .unreadableFile: return "The complete item could not be inspected."
        case .tooManyEntries: return "This item exceeds the bounded Smart Cleanup inspection limit. Use manual review."
        case .invalidSelection: return "The selection does not belong to this scan."
        case .stalePlan: return "The scan changed. Review a new plan."
        case .expiredPlan: return "This review expired. Review the items again."
        case .unknownPlan: return "This plan has already been used or discarded."
        case .destinationExists: return "The original location already exists. Nothing was overwritten."
        case .unsupportedPlatform: return "Trash operations require macOS."
        }
    }
}

public struct FileStamp: Equatable, Sendable {
    public struct Entry: Equatable, Sendable {
        public let relativePath: String
        public let device: UInt64
        public let inode: UInt64
        public let mode: UInt32
        public let size: Int64
        public let allocatedBytes: Int64
        public let modifiedSeconds: Int64
        public let modifiedNanos: Int64
        public let changedSeconds: Int64
        public let changedNanos: Int64
        public init(relativePath: String, device: UInt64, inode: UInt64, mode: UInt32, size: Int64,
                    modifiedSeconds: Int64, modifiedNanos: Int64, changedSeconds: Int64, changedNanos: Int64, allocatedBytes: Int64 = 0) {
            self.allocatedBytes = max(0, allocatedBytes)
            self.relativePath = relativePath; self.device = device; self.inode = inode; self.mode = mode; self.size = size
            self.modifiedSeconds = modifiedSeconds; self.modifiedNanos = modifiedNanos
            self.changedSeconds = changedSeconds; self.changedNanos = changedNanos
        }
    }
    public let entries: [Entry]
    public init(entries: [Entry]) { self.entries = entries }
    public var allocatedBytes: Int64 {
        entries.filter { ($0.mode & UInt32(S_IFMT)) == UInt32(S_IFREG) }.reduce(0) { total, entry in
            let (sum, overflow) = total.addingReportingOverflow(entry.allocatedBytes)
            return overflow ? Int64.max : sum
        }
    }
}

public protocol CleanupFileSystem: Sendable {
    func stamp(_ url: URL) throws -> FileStamp
    func moveToTrash(_ url: URL) throws -> URL
    func restore(from trash: URL, to original: URL) throws
}

/// Reads only filesystem metadata, never file contents. A bounded exact metadata inventory
/// avoids relying on directory mtime (which misses edits to existing descendants).
public struct LocalCleanupFileSystem: CleanupFileSystem {
    public let maximumEntries: Int
    public init(maximumEntries: Int = 20_000) { self.maximumEntries = max(1, maximumEntries) }

    public func stamp(_ url: URL) throws -> FileStamp {
        let fm = FileManager.default
        let root = url.standardizedFileURL
        // Reject symlinked ancestors before using a path-based macOS Trash API.
        var ancestor = root
        while ancestor.path != "/" {
            let attributes = try fm.attributesOfItem(atPath: ancestor.path)
            guard attributes[.type] as? FileAttributeType != .typeSymbolicLink else { throw CleanupError.unsafeFile }
            ancestor.deleteLastPathComponent()
        }
        var entries = [try entry(root, relativePath: "")]
        let device = entries[0].device
        if (entries[0].mode & UInt32(S_IFMT)) == UInt32(S_IFDIR) {
            var incomplete = false
            guard let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: nil,
                options: [], errorHandler: { _, _ in incomplete = true; return false }) else { throw CleanupError.unreadableFile }
            for case let child as URL in enumerator {
                try Task.checkCancellation()
                guard entries.count < maximumEntries else { throw CleanupError.tooManyEntries }
                let relative = String(child.path.dropFirst(root.path.count + 1))
                let item = try entry(child, relativePath: relative)
                guard item.device == device else { throw CleanupError.unsafeFile }
                entries.append(item)
            }
            guard !incomplete else { throw CleanupError.unreadableFile }
        }
        // Recheck the root after enumeration. Execution compares the complete stamp again.
        guard try entry(root, relativePath: "") == entries[0] else { throw CleanupError.changedFile }
        return FileStamp(entries: entries.sorted { $0.relativePath < $1.relativePath })
    }

    public func rootIdentity(_ url: URL) throws -> FileStamp.Entry { try entry(url, relativePath: "") }

    private func entry(_ url: URL, relativePath: String) throws -> FileStamp.Entry {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { throw CleanupError.unreadableFile }
        let type = info.st_mode & mode_t(S_IFMT)
        guard type == mode_t(S_IFREG) || type == mode_t(S_IFDIR) else { throw CleanupError.unsafeFile }
        // Sharing makes additive estimates ambiguous; keep these in manual review.
        if type == mode_t(S_IFREG), info.st_nlink > 1 { throw CleanupError.unsafeFile }
        #if os(macOS)
        let values = try url.resourceValues(forKeys: [.isUbiquitousItemKey, .isAliasFileKey, .volumeIsLocalKey])
        guard values.isUbiquitousItem != true, values.isAliasFile != true, values.volumeIsLocal != false else { throw CleanupError.unsafeFile }
        let modified = info.st_mtimespec, changed = info.st_ctimespec
        #else
        let modified = info.st_mtim, changed = info.st_ctim
        #endif
        return FileStamp.Entry(relativePath: relativePath, device: UInt64(bitPattern: Int64(info.st_dev)), inode: UInt64(info.st_ino),
            mode: UInt32(info.st_mode), size: Int64(info.st_size), modifiedSeconds: Int64(modified.tv_sec),
            modifiedNanos: Int64(modified.tv_nsec), changedSeconds: Int64(changed.tv_sec), changedNanos: Int64(changed.tv_nsec), allocatedBytes: Int64(info.st_blocks) * 512)
    }

    public func moveToTrash(_ url: URL) throws -> URL {
        #if os(macOS)
        var destination: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &destination)
        guard let destination else { throw CleanupError.unreadableFile }
        return destination as URL
        #else
        throw CleanupError.unsupportedPlatform
        #endif
    }

    public func restore(from trash: URL, to original: URL) throws {
        // Validate destination ancestors too: restore must not follow a substituted link.
        var parent = original.deletingLastPathComponent().standardizedFileURL
        while parent.path != "/" {
            let attributes = try FileManager.default.attributesOfItem(atPath: parent.path)
            guard attributes[.type] as? FileAttributeType == .typeDirectory else { throw CleanupError.unsafeFile }
            parent.deleteLastPathComponent()
        }
        // FileManager.moveItem fails when the destination exists; never remove it first.
        guard !FileManager.default.fileExists(atPath: original.path) else { throw CleanupError.destinationExists }
        try FileManager.default.moveItem(at: trash, to: original)
    }
}
