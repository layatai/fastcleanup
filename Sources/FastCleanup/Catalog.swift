import Foundation

enum CategoryCatalog {
    static func all() -> [CategoryDefinition] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        func h(_ p: String) -> URL { home.appending(path: p, directoryHint: .isDirectory) }

        let xcodeRoots = [
            h("Library/Developer/Xcode/iOS DeviceSupport"),
            h("Library/Developer/Xcode/watchOS DeviceSupport"),
            h("Library/Developer/Xcode/tvOS DeviceSupport"),
            h("Library/Developer/Xcode/Archives"),
            h("Library/Developer/CoreSimulator/Caches"),
        ]
        let pkgRoots = [
            h("Library/pnpm"), h(".npm"), h(".pnpm-store"), h(".cache"),
            h(".gradle/caches"), h(".cargo/registry"), h("Library/Caches/Yarn"),
        ]
        let appSupport = h("Library/Application Support")
        let containers = h("Library/Containers")
        let electronCacheNames = ["Cache", "Caches", "Code Cache", "GPUCache", "CachedData",
            "Service Worker", "Crashpad", "CachedExtensionVSIXs", "DawnCache",
            "DawnGraphiteCache", "ShaderCache", "GrShaderCache", "Cache_Data",
            "Component Crx Cache", "blob_storage"]
        let aiModelRoots = [
            appSupport.appending(path: "nomic.ai/GPT4All", directoryHint: .isDirectory),
            h(".ollama/models"),
            appSupport.appending(path: "lm-studio/models", directoryHint: .isDirectory),
            h(".cache/lm-studio"),
            h(".cache/huggingface"),
        ]
        let messagingRoots = [
            appSupport.appending(path: "ZaloData", directoryHint: .isDirectory),
            appSupport.appending(path: "Telegram Desktop", directoryHint: .isDirectory),
            appSupport.appending(path: "Slack/Cache", directoryHint: .isDirectory),
            appSupport.appending(path: "Slack/Service Worker", directoryHint: .isDirectory),
        ]
        let vmRoots = [
            appSupport.appending(path: "rancher-desktop/lima", directoryHint: .isDirectory),
            containers.appending(path: "com.docker.docker/Data/vms", directoryHint: .isDirectory),
            containers.appending(path: "com.docker.docker/Data/log", directoryHint: .isDirectory),
        ]

        let defs: [CategoryDefinition] = [
            .init(id: "app-caches", title: "Application Caches",
                  subtitle: "~/Library/Caches", systemImage: "shippingbox.fill",
                  tintHex: "3B82F6", safety: .safe, roots: [h("Library/Caches")], strategy: .children),
            .init(id: "xcode-derived", title: "Xcode DerivedData",
                  subtitle: "Build intermediates & indexes", systemImage: "hammer.fill",
                  tintHex: "8B5CF6", safety: .safe,
                  roots: [h("Library/Developer/Xcode/DerivedData")], strategy: .children),
            .init(id: "xcode-support", title: "Xcode Device Support",
                  subtitle: "Device support, archives, simulators", systemImage: "iphone",
                  tintHex: "A855F7", safety: .caution, roots: xcodeRoots, strategy: .children),
            .init(id: "node-modules", title: "node_modules",
                  subtitle: "Reinstall with your package manager", systemImage: "cube.box.fill",
                  tintHex: "22C55E", safety: .safe, roots: [home],
                  strategy: .namedDirectories(["node_modules"])),
            .init(id: "build-artifacts", title: "Build Artifacts",
                  subtitle: "target, .next, dist, .turbo", systemImage: "wrench.and.screwdriver.fill",
                  tintHex: "10B981", safety: .safe, roots: [home],
                  strategy: .namedDirectories(["target", ".next", "dist", ".turbo", ".parcel-cache"])),
            .init(id: "pkg-stores", title: "Package Manager Stores",
                  subtitle: "pnpm, npm, cargo, gradle", systemImage: "archivebox.fill",
                  tintHex: "14B8A6", safety: .safe, roots: pkgRoots, strategy: .children),
            .init(id: "app-data-caches", title: "App Data Caches",
                  subtitle: "Cursor, Claude, VS Code, Electron app caches",
                  systemImage: "app.badge.fill", tintHex: "0EA5E9", safety: .safe,
                  roots: [appSupport, containers],
                  strategy: .cacheDirectories(electronCacheNames)),
            .init(id: "ai-models", title: "Local AI Models",
                  subtitle: "GPT4All, Ollama, LM Studio — clear if unused",
                  systemImage: "brain.head.profile", tintHex: "D946EF", safety: .caution,
                  roots: aiModelRoots, strategy: .paths),
            .init(id: "messaging-caches", title: "Messaging Caches",
                  subtitle: "Zalo, Telegram, Slack media — review first",
                  systemImage: "message.fill", tintHex: "06B6D4", safety: .caution,
                  roots: messagingRoots, strategy: .children),
            .init(id: "container-vms", title: "Container VM Disks",
                  subtitle: "Docker / Rancher — QUIT app first, removes containers",
                  systemImage: "shippingbox.circle.fill", tintHex: "F43F5E", safety: .caution,
                  roots: vmRoots, strategy: .paths),
            .init(id: "git-repos", title: "Git Repositories",
                  subtitle: "git gc repacks history — keeps every commit",
                  systemImage: "arrow.triangle.branch", tintHex: "64748B", safety: .safe,
                  roots: [h("projects")], strategy: .gitRepositories(minBytes: 200 * 1024 * 1024),
                  action: .gitCompact),
            .init(id: "trash", title: "Trash", subtitle: "~/.Trash", systemImage: "trash.fill",
                  tintHex: "EF4444", safety: .safe, roots: [h(".Trash")], strategy: .children),
            .init(id: "logs", title: "Logs", subtitle: "~/Library/Logs", systemImage: "doc.text.fill",
                  tintHex: "F59E0B", safety: .safe, roots: [h("Library/Logs")], strategy: .children),
            .init(id: "old-downloads", title: "Old Downloads",
                  subtitle: "Not modified in 90+ days", systemImage: "arrow.down.circle.fill",
                  tintHex: "F97316", safety: .caution, roots: [h("Downloads")],
                  strategy: .oldFiles(olderThanDays: 90)),
            .init(id: "large-files", title: "Large Files",
                  subtitle: "Files over 500 MB", systemImage: "doc.fill",
                  tintHex: "EC4899", safety: .caution,
                  roots: [h("Desktop"), h("Documents"), h("Movies")],
                  strategy: .largeFiles(minBytes: 500 * 1024 * 1024)),
        ]
        let fm = FileManager.default
        return defs.filter { d in d.roots.contains { fm.fileExists(atPath: $0.path) } }
    }
}
