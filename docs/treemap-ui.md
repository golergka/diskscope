# Native Treemap Architecture (egui)

## Current direction

Diskscope now uses a native Rust desktop UI (`eframe/egui`) instead of a localhost-served web app.

## Runtime model

- UI thread:
  - read-only mirrored scan state
  - consumes incremental `ScanEvent`s
  - preserves selection/zoom by stable `NodeId`
- Coordinator thread:
  - authoritative `ScanModel` writer
  - merges worker results
  - emits `ScanEvent::Batch` + `ScanEvent::Progress` (10 Hz)
- Worker threads:
  - bounded queue
  - parallel subtree scanning
  - cancellable

## Data model highlights

Node schema includes explicit known/unknown semantics:

- `size_state`: `Unknown | Partial | Final`
- `children_state`: `Unknown | Partial | Final | CollapsedByThreshold`

Collapsed nodes are terminal in v1 and marked as deferred detail.

## Threshold policy

Default collapse threshold:

- `max(0.1% of volume size, 64 MiB)`

Workers compute exact totals, then persist either:

- full subtree (if above threshold), or
- one collapsed directory node (if below threshold)

## TODOs intentionally left for next iteration

- On-demand expansion of collapsed nodes when user clicks a deferred node.
- Preset calibration benchmarking for worker constants (currently conservative provisional defaults).
