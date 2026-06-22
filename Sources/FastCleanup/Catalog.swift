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
        // VS Code-family editors keep a stale `state.vscdb.backup` snapshot next to the
        // live `state.vscdb` in globalStorage — frequently multiple GB, safe to delete
        // (the editor recreates it). The live `state.vscdb` itself is left untouched.
        let editorStateRoots = ["Cursor", "Code", "Code - Insiders", "VSCodium", "Trae", "Windsurf"]
            .map { appSupport.appending(path: "\($0)/User/globalStorage", directoryHint: .isDirectory) }
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

        var defs: [CategoryDefinition] = [
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
                  subtitle: "dist, .next, target, .turbo, __pycache__, .pytest_cache",
                  systemImage: "wrench.and.screwdriver.fill",
                  tintHex: "10B981", safety: .safe, roots: [home],
                  strategy: .namedDirectories([
                    "target", ".next", "dist", ".turbo", ".parcel-cache", ".svelte-kit", "coverage",
                    "__pycache__", ".pytest_cache", ".mypy_cache", ".ruff_cache", ".tox",
                  ])),
            .init(id: "python-envs", title: "Python Environments",
                  subtitle: "Virtualenvs (.venv, venv) — recreate with your tool",
                  systemImage: "cube.transparent", tintHex: "EAB308", safety: .caution,
                  roots: [home], strategy: .namedDirectories([".venv", "venv"])),
            .init(id: "saved-app-state", title: "Saved Application State",
                  subtitle: "~/Library/Saved Application State — window/restore state",
                  systemImage: "macwindow.on.rectangle", tintHex: "0891B2", safety: .safe,
                  roots: [h("Library/Saved Application State")], strategy: .children),
            .init(id: "pkg-stores", title: "Package Manager Stores",
                  subtitle: "pnpm, npm, cargo, gradle", systemImage: "archivebox.fill",
                  tintHex: "14B8A6", safety: .safe, roots: pkgRoots, strategy: .children),
            .init(id: "editor-state-backups", title: "Editor State Backups",
                  subtitle: "Stale *.vscdb.backup in Cursor / VS Code — live DB untouched",
                  systemImage: "externaldrive.badge.xmark", tintHex: "6366F1", safety: .safe,
                  roots: editorStateRoots, strategy: .namedFiles(suffixes: [".vscdb.backup"])),
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

        // ---- Command-based cleanups (new capability) ----------------------------
        // Each is gated on the tool being installed and is opt-in (commands are never
        // auto-selected). They reclaim space by running an external tool rather than
        // trashing files; some have no cheap size estimate (sizingRoots empty).
        func command(_ id: String, _ title: String, _ subtitle: String,
                     image: String, tint: String, safety: Safety,
                     exe: String, args: [String], sizingRoots: [URL] = []) -> CategoryDefinition {
            .init(id: id, title: title, subtitle: subtitle, systemImage: image,
                  tintHex: tint, safety: safety, roots: sizingRoots,
                  strategy: .command(sizingRoots: sizingRoots),
                  action: .command(ShellCommand(executable: exe, arguments: args)))
        }

        if CommandRunner.hasBinary("brew") {
            defs.append(command("brew-cleanup", "Homebrew cleanup",
                                "brew cleanup -s — stale downloads & old versions",
                                image: "mug.fill", tint: "F59E0B", safety: .safe,
                                exe: "brew", args: ["cleanup", "-s"],
                                sizingRoots: [h("Library/Caches/Homebrew")]))
            defs.append(command("brew-autoremove", "Homebrew autoremove",
                                "brew autoremove — unused dependency formulae",
                                image: "mug", tint: "F59E0B", safety: .caution,
                                exe: "brew", args: ["autoremove"]))
        }
        if CommandRunner.hasBinary("docker") {
            let docker: [(String, String, String, [String])] = [
                ("docker-system-prune", "Docker system prune",
                 "docker system prune -f — unused data & build cache", ["system", "prune", "-f"]),
                ("docker-builder-prune", "Docker builder prune",
                 "docker builder prune -f — build cache", ["builder", "prune", "-f"]),
                ("docker-image-prune", "Docker image prune",
                 "docker image prune -f — dangling images", ["image", "prune", "-f"]),
                ("docker-container-prune", "Docker container prune",
                 "docker container prune -f — stopped containers", ["container", "prune", "-f"]),
                ("docker-volume-prune", "Docker volume prune (DESTRUCTIVE)",
                 "docker volume prune -f — may delete database data", ["volume", "prune", "-f"]),
            ]
            for (id, title, subtitle, args) in docker {
                defs.append(command(id, title, subtitle, image: "shippingbox.fill",
                                    tint: "2496ED", safety: .caution, exe: "docker", args: args))
            }
        }
        if CommandRunner.hasBinary("pnpm") {
            defs.append(command("pnpm-store-prune", "pnpm store prune",
                                "pnpm store prune — remove unreferenced packages",
                                image: "archivebox.fill", tint: "F69220", safety: .safe,
                                exe: "pnpm", args: ["store", "prune"],
                                sizingRoots: [h("Library/pnpm"), h(".pnpm-store")]))
        }

        // ---- Non-destructive node_modules optimization (APFS clone dedupe) -------
        if CommandRunner.hasBinary("fclones") && CommandRunner.isAPFS(home) {
            defs.append(.init(
                id: "node-modules-dedupe", title: "Optimize node_modules (dedupe)",
                subtitle: "Share identical files via APFS clones — projects keep working",
                systemImage: "square.on.square.dashed", tintHex: "16A34A", safety: .safe,
                roots: [home], strategy: .command(sizingRoots: []),
                action: .dedupeNodeModules))
        }

        let fm = FileManager.default
        return defs.filter { d in
            switch d.action {
            // Command/dedupe categories are gated by hasBinary above and may have no
            // existing backing path — keep them regardless of the roots check.
            case .command, .dedupeNodeModules: return true
            default: return d.roots.contains { fm.fileExists(atPath: $0.path) }
            }
        }
    }
}
