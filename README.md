# diskscope

A low-memory disk scanner inspired by Disk Inventory X, implemented in Rust.

## What is implemented

- Native desktop app (`egui`) via `diskscope ui`.
- CLI scanner via `diskscope scan ...`.
- Backward-compatible CLI invocation (`diskscope [PATH] [options]`) still works.
- Real-time scan pipeline with worker threads + incremental UI patch updates.
- Stable node IDs across updates (selection/zoom continuity).
- Disk Inventory X-style structural treemap semantics:
  - area proportional to byte size
  - hierarchical grouping
  - directories + file leaves
- Threshold-based collapsed subtrees to bound persisted memory:
  - default threshold = `max(0.1% of volume size, 64 MiB)`
  - collapsed nodes are terminal in v1
  - TODO hooks are in code for future expand-on-click

## Build

```bash
cargo build --release
```

## Native UI (no localhost)

```bash
./target/release/diskscope ui
```

In the native app you get:

- path input
- Start / Cancel / Rescan
- profile selector (Conservative / Balanced / Aggressive)
- advanced controls (worker override, queue limit, threshold override)
- real-time progress and incremental treemap updates

## CLI scanner

Subcommand form:

```bash
./target/release/diskscope scan /Users/me --top 30 --min-size 1G --one-file-system
```

Backward-compatible form:

```bash
./target/release/diskscope /Users/me --top 30 --min-size 1G --one-file-system
```

### Useful output formats

Binary snapshot:

```bash
./target/release/diskscope scan /Users/me --snapshot /tmp/scan.bin
```

JSON tree:

```bash
./target/release/diskscope scan /Users/me --json-tree > /tmp/scan.json
```

## Help

Top-level:

```bash
./target/release/diskscope --help
```

Scan options:

```bash
./target/release/diskscope scan --help
```

## Status

- `cargo test`: passing
- `cargo build --release`: passing

Legacy static web prototype files still exist under `ui/`, but the primary interface is now native (`diskscope ui`).
