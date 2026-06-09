# FastCleanup

A native macOS **menu-bar** app (SwiftUI + Swift Charts) for scanning and
reclaiming disk space. Runs as an agent (no Dock icon) and lives in the
top-right menu bar.

## Features
- **Concurrent scan engine** — parallel directory enumeration (`TaskGroup`),
  allocated-size accounting, cancellable, with live progress.
- **Charts & stats** — disk-usage ring gauge (free/used, color-coded by
  pressure) and a Swift Charts donut of reclaimable space by category.
- **10 disjoint categories** — Application Caches, Xcode DerivedData, Xcode
  device support, node_modules, build artifacts, package-manager stores,
  Trash, Logs, old Downloads, and large files.
- **Safe cleanup** — per-category selection, expandable item lists, a confirm
  dialog, and **moves to Trash by default** (reversible). Permanent delete is
  opt-in in Settings.

## Build & run
```bash
./build.sh                # native (arm64) release build, ad-hoc signed
./build.sh --universal    # optional universal (arm64 + x86_64)
open dist/FastCleanup.app
```
Look for the ✨ icon in the menu bar → **Scan Now** → review → **Clean**.

Requires macOS 14+ and the Swift toolchain (`xcode-select --install`).

## Ship a signed, notarized DMG
`dmg.sh` does build → Developer ID sign → DMG → notarize → staple → verify.

Provide Apple notary credentials via a gitignored env file (never committed).
Create `scripts/.ship.env` (or point `SHIP_ENV` at an existing one) exporting:
```bash
APPLE_ID="you@example.com"
APPLE_PASSWORD="xxxx-xxxx-xxxx-xxxx"   # app-specific password
APPLE_TEAM_ID="Y69F3DRK44"
# (or App Store Connect API key: APPLE_API_KEY_PATH / APPLE_API_KEY / APPLE_API_ISSUER)
```
Then:
```bash
./dmg.sh                                   # uses scripts/.ship.env
SHIP_ENV=~/projects/other/scripts/.ship.env ./dmg.sh   # reuse another project's creds
```
The signing identity is auto-detected (first "Developer ID Application"); override with
`APPLE_SIGNING_IDENTITY`. Output: `dist/FastCleanup-<version>.dmg`, notarized and stapled
(`spctl` → `accepted, source=Notarized Developer ID`).

## Architecture
| File | Role |
|------|------|
| `Models.swift` | `ScanItem`, `CategoryDefinition`, `CategoryResult`, strategies |
| `DiskScanner.swift` | Concurrent filesystem scan engine |
| `DiskSpace.swift` | Volume capacity stats |
| `Catalog.swift` | Category definitions (paths + strategy + tint) |
| `AppState.swift` | `@MainActor` view-model: scan / select / clean |
| `Donut.swift` | Swift Charts donut |
| `Views.swift` | Menu-bar panel UI |
| `App.swift` | `MenuBarExtra` entry point |
