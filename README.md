# diskscope

`diskscope` is a Rust disk-usage analyzer inspired by Disk Inventory X.

The project now ships as a dual-frontend system over one shared scan core:

- `diskscope scan` for CLI workflows and automation.
- `diskscope ui` for the existing `egui` desktop frontend.
- `diskscope ui-native` for a native macOS frontend (SwiftUI shell + AppKit treemap).

## Frontend model

- Shared source of truth: `crates/diskscope-core`.
- Scanner emits incremental patch/progress events.
- `egui` and native macOS frontends both consume the same core semantics.
- JSON is still available for automation/debug exports, but frontend transport is C ABI callbacks (`diskscope-ffi`), not JSON.

## Workspace layout

- `crates/diskscope-core`: scanner, model, events, volume logic.
- `crates/diskscope-cli`: command dispatch (`scan`, `ui`, `ui-native`, `clean-native`).
- `crates/diskscope-egui`: existing native Rust UI.
- `crates/diskscope-ffi`: C ABI bridge used by native macOS app.
- `native/macos/DiskscopeNative`: Xcode project for native macOS frontend.
- `assets/icon.png`: shared source icon used by frontends (egui/native/web).

## Commands

### `diskscope scan`

Runs the CLI scanner with current flags/output modes.

```bash
cargo run -p diskscope -- scan / --top 30 --min-size 1G --one-file-system
```

Backward-compatible invocation still works:

```bash
cargo run -p diskscope -- / --top 30 --min-size 1G
```

### `diskscope ui`

Launches `egui` frontend.

```bash
cargo run -p diskscope -- ui
cargo run -p diskscope -- ui --path / --start
```

### `diskscope ui-native`

Builds and launches native macOS frontend app bundle.

```bash
cargo run -p diskscope -- ui-native
cargo run -p diskscope -- ui-native --path / --start
```

Behavior:
- default launch opens **Setup** ("What to Scan").
- `--start --path PATH` opens **Results** immediately and starts scanning.
- before launch, CLI runs `xcodebuild` to `native/macos/DiskscopeNative/build` (Debug) so the app is always fresh.

If the app bundle is missing, CLI exits non-zero and prints deterministic build steps.

### `diskscope clean-native`

Removes local native macOS build artifacts so the next Xcode build is guaranteed fresh.

```bash
cargo run -p diskscope -- clean-native
```

## Native macOS setup (`ui-native`)

### Prerequisites

- macOS 13+
- Xcode 16+
- Rust stable toolchain

### Build (manual, optional)

From repo root:

```bash
cargo run -p diskscope -- clean-native
cargo build -p diskscope-ffi --release
xcodebuild \
  -project native/macos/DiskscopeNative/DiskscopeNative.xcodeproj \
  -scheme DiskscopeNative \
  -configuration Release \
  -derivedDataPath native/macos/DiskscopeNative/build \
  build
```

Expected app artifact path:

- `native/macos/DiskscopeNative/build/Build/Products/Release/DiskscopeNative.app`

Then launch through CLI:

```bash
cargo run -p diskscope -- ui-native --path / --start
```

`ui-native` now performs a deterministic native build to `native/macos/DiskscopeNative/build` before launch, then opens:

- `native/macos/DiskscopeNative/build/Build/Products/Debug/DiskscopeNative.app`

Optional app override path:

```bash
DISKSCOPE_NATIVE_APP=/absolute/path/to/DiskscopeNative.app cargo run -p diskscope -- ui-native
```

## Build and test (Rust workspace)

```bash
cargo test
cargo build --release
```

## Feature status (current)

Implemented in shared scan core:

- directory + file nodes with stable `NodeId` per scan session.
- explicit `Unknown/Partial/Final` state semantics.
- background worker scanning with incremental event streaming.
- threshold-based collapsed nodes (`max(0.1% volume, 64 MiB)` default).
- ignore patterns, hidden/symlink/xdev controls.
- binary snapshot output and JSON tree output for tooling.
- progress payload includes scanned bytes + occupied bytes + total capacity bytes.
- root node size is streamed as `Partial` during scan (no long-lived `0 B` root while workers run).

Native macOS frontend currently includes:

- explicit two-screen flow:
  - **Setup**: drive cards with Capacity/Used/Free stats + `Select Folder…` target picker.
  - setup advanced tuning is opened via native `Advanced…` modal sheet (not inline-expanding controls).
  - **Results**: progress/status + hierarchy tree + treemap.
- drive selection and optional custom path.
- start/cancel/rescan and profile/tuning controls.
- real-time progress from core events.
- native `NSOutlineView` hierarchy tree (collapsible, keyboard-navigable) with `Name` and `Size` columns.
- hierarchy refresh is coalesced/throttled and switches to visible-row updates for very large expanded trees.
- AppKit treemap with area proportional to bytes.
- treemap layout is computed off the UI thread with generation-cancelled progressive depth updates.
- layout cadence adapts during scan (`~1-3s`) based on patch backlog to keep UI responsive.
- treemap fill area scaled by explored/occupied ratio (unexplored area remains blank).
- treemap uses glossy shading and single-pass shared borders (no multi-thick nested edges).
- tree/treemap selection + zoom sync by stable node ID.
- top bar shows scanned / occupied / capacity plus live `Error` and `Deferred` counters.
- dedicated native `Scan Errors` window (open from results toolbar or app menu) to review accumulated node/runtime errors.
- native lifecycle behavior:
  - single main window.
  - app stays alive when window closes.
  - Dock reopen restores Setup or Results based on app mode.
  - Dock icon shows a native progress bar overlay while scanning.
- top menu commands for scan actions (`Select Folder`, `Start`, `Cancel`, `Rescan`, `Show Setup/Results`, `Reset Zoom`).
- optional runtime diagnostics via `DISKSCOPE_NATIVE_TRACE=1` (logs slow patch flush, outline refresh/selection sync, treemap relayout/draw FPS to unified macOS logs).

Known limitations:

- native parity hardening is in progress (see `docs/parity-matrix.md`).
- signing/notarization is deferred.
- scanning `/` may show per-folder `Error` badges for macOS-protected paths when permission is denied (for example, if privacy prompts are declined).

## Additional docs

- `docs/native-macos.md`
- `docs/ffi-contract.md`
- `docs/parity-matrix.md`
