# FastCleanup

A native macOS **menu-bar** app for scanning and reclaiming disk space — fast,
private, and built entirely in Swift. It lives in the top-right menu bar (no Dock
icon), finds gigabytes of safe-to-remove caches, build artifacts, and junk, and
shows it all as charts before you clean a thing.

<p align="center">
  <img src="docs/screenshot.png" alt="FastCleanup menu-bar panel" width="430">
</p>

> Real scan above: **247 GB reclaimable** surfaced across 15 categories.

## Download

Grab the latest signed & notarized installer from
**[Releases](https://github.com/layatai/fastcleanup/releases/latest)** →
`FastCleanup-1.0.dmg`. Drag **FastCleanup** to Applications, launch it, and the
✨ icon appears in your menu bar. It's notarized by Apple, so it opens
warning-free. Requires **macOS 14+**.

## Features

- **🔍 Concurrent scan engine** — parallel directory enumeration (`TaskGroup`)
  with allocated-size accounting; cancellable, with live per-category progress.
- **📊 Charts & statistics** — a disk-usage **ring gauge** (free/used, color-coded
  by pressure: green → orange → red) and a Swift Charts **donut** of reclaimable
  space broken down by category.
- **🧮 15 disjoint categories** — no double-counting; see the table below.
- **✅ Safe by default** — only safe, regenerable categories are pre-selected.
  Caution items (AI models, messaging caches, container VMs) are unchecked until
  you opt in.
- **🗑️ Reversible cleanup** — everything **moves to the Trash** by default and can
  be recovered. Permanent delete is an opt-in toggle in Settings.
- **🌿 Git-aware** — large `.git` repos are compacted with `git gc` (repacks
  history, reclaims loose objects) **without losing a single commit** — never
  deleted.
- **🖱️ Right-click context menus** — on any file or category:
  **Open** · **Reveal in Finder** · **Copy Path / Name / Size** ·
  **Move to Trash** (per item) · **Clean / Compact** (per category).
  Double-click a file to reveal it in Finder.
- **🔒 Private & native** — pure Swift/SwiftUI, no telemetry, no Electron, no
  network calls. The whole signed app is ~640 KB.

## What it scans

| Category | What it targets | Default |
|---|---|---|
| **Application Caches** | `~/Library/Caches` (pnpm, Playwright, JetBrains, browsers…) | ✅ |
| **App Data Caches** | Electron caches inside Cursor, Claude, VS Code, etc. | ✅ |
| **Xcode DerivedData** | Build intermediates & indexes | ✅ |
| **Xcode Device Support** | Device support, archives, simulator caches | ⚠️ |
| **node_modules** | All `node_modules` under your home tree | ✅ |
| **Build Artifacts** | `target`, `.next`, `dist`, `.turbo`, `.parcel-cache` | ✅ |
| **Package Manager Stores** | pnpm, npm, cargo, gradle stores | ✅ |
| **Git Repositories** | Large `.git` dirs → `git gc` (keeps every commit) | ⚠️ |
| **Local AI Models** | GPT4All, Ollama, LM Studio, HuggingFace cache | ⚠️ |
| **Messaging Caches** | Zalo, Telegram, Slack media | ⚠️ |
| **Container VM Disks** | Docker / Rancher VM images (quit the app first) | ⚠️ |
| **Trash** | `~/.Trash` | ✅ |
| **Logs** | `~/Library/Logs` | ✅ |
| **Old Downloads** | `~/Downloads` not modified in 90+ days | ⚠️ |
| **Large Files** | Files over 500 MB in Desktop / Documents / Movies | ⚠️ |

✅ = pre-selected (safe, regenerates) · ⚠️ = opt-in (review first)

## Build & run

```bash
./build.sh                # native (arm64) release build, ad-hoc signed
./build.sh --universal    # universal (arm64 + x86_64)
open dist/FastCleanup.app
```

Requires the Swift toolchain (`xcode-select --install`).

## Ship a signed, notarized DMG

`dmg.sh` does build → Developer ID sign → DMG → notarize → staple → verify.
Provide notary credentials via a gitignored env file (never committed). Create
`scripts/.ship.env` (or point `SHIP_ENV` at an existing one) exporting:

```bash
APPLE_ID="you@example.com"
APPLE_PASSWORD="xxxx-xxxx-xxxx-xxxx"   # app-specific password
APPLE_TEAM_ID="XXXXXXXXXX"
# (or App Store Connect API key: APPLE_API_KEY_PATH / APPLE_API_KEY / APPLE_API_ISSUER)
```

```bash
./dmg.sh                                            # uses scripts/.ship.env
SHIP_ENV=~/path/to/.ship.env ./dmg.sh              # reuse creds without copying them
```

The signing identity is auto-detected (first *Developer ID Application*); override
with `APPLE_SIGNING_IDENTITY`. Output: a notarized, stapled
`dist/FastCleanup-<version>.dmg`.

## Architecture

Pure Swift Package Manager executable assembled into a `MenuBarExtra`
(`LSUIElement`) app bundle.

| File | Role |
|------|------|
| `Models.swift` | `ScanItem`, `CategoryDefinition`, strategies, `CleanupAction` |
| `DiskScanner.swift` | Concurrent filesystem scan engine |
| `DiskSpace.swift` | Volume capacity stats |
| `Catalog.swift` | The 15 category definitions (paths + strategy + tint) |
| `AppState.swift` | `@MainActor` view-model: scan / select / clean / trash |
| `GitMaintenance.swift` | `git gc` runner |
| `Donut.swift` | Swift Charts donut |
| `Views.swift` | Menu-bar panel UI + context menus |
| `App.swift` | `MenuBarExtra` entry point |

## License

MIT
