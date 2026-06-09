import Foundation

struct DiskSpace: Sendable {
    let total: Int64
    let free: Int64
    var used: Int64 { max(0, total - free) }
    var usedFraction: Double { total > 0 ? Double(used) / Double(total) : 0 }

    static func current() -> DiskSpace {
        let url = URL(fileURLWithPath: NSHomeDirectory())
        let keys: Set<URLResourceKey> = [.volumeTotalCapacityKey,
                                         .volumeAvailableCapacityForImportantUsageKey]
        guard let v = try? url.resourceValues(forKeys: keys),
              let total = v.volumeTotalCapacity else {
            return DiskSpace(total: 0, free: 0)
        }
        return DiskSpace(total: Int64(total),
                         free: Int64(v.volumeAvailableCapacityForImportantUsage ?? 0))
    }
}
