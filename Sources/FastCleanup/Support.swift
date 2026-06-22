import SwiftUI

enum Format {
    static func bytes(_ b: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: b, countStyle: .file)
    }
    static func relativeDate(_ d: Date?) -> String {
        guard let d else { return "never" }
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f.localizedString(for: d, relativeTo: Date())
    }
    /// Full path with the home directory abbreviated to `~` (e.g. `~/projects/app`).
    static func displayPath(_ url: URL) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let p = url.path
        guard p.hasPrefix(home) else { return p }
        let rest = p.dropFirst(home.count)
        return rest.isEmpty ? "~" : "~" + rest
    }
    /// The containing directory, home-abbreviated — what disambiguates same-named
    /// items like many `node_modules` folders.
    static func locationPath(_ url: URL) -> String {
        displayPath(url.deletingLastPathComponent())
    }
}

extension Color {
    init(hex: String) {
        let s = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var v: UInt64 = 0
        Scanner(string: s).scanHexInt64(&v)
        self.init(.sRGB,
                  red: Double((v >> 16) & 0xFF) / 255.0,
                  green: Double((v >> 8) & 0xFF) / 255.0,
                  blue: Double(v & 0xFF) / 255.0,
                  opacity: 1.0)
    }
}

extension CategoryDefinition {
    var tint: Color { Color(hex: tintHex) }
}
