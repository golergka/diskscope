# Parity Matrix

Status legend:

- `done`: implemented and validated in current repo.
- `partial`: implemented with known gaps.
- `todo`: not yet implemented.

| Feature | CLI (`scan`) | `egui` (`ui`) | Native macOS (`ui-native`) | Owner | Status |
|---|---|---|---|---|---|
| Select scan root (drive/path) | done | done | done | core/ui | done |
| Two-screen flow (Setup + Results) | n/a | partial | done | native | done |
| Start / cancel / rescan | done | done | done | core/ui | done |
| Real-time progress updates | n/a | done | done | core/ui | done |
| Size-sorted collapsible hierarchy | text top-N | done | done | ui | done |
| Treemap area proportional to bytes | json/debug only | done | done | ui | done |
| Hierarchy grouping (parent contains child rects) | n/a | done | done | ui | done |
| Tree selection sync with treemap | n/a | done | done | ui | done |
| Zoom rooted by stable node id | n/a | done | done | ui | done |
| Collapsed/deferred node semantics | done | done | done | core/ui | done |
| Profile + advanced tuning controls | flags | done | done | core/ui | done |
| App-lifecycle native behavior (stay running, Dock reopen route) | n/a | n/a | done | native | done |
| One-file-system / hidden / symlink policies | done | done | partial (currently fixed defaults) | core/native | partial |
| Native appearance hardening (final visual polish) | n/a | n/a | partial | native | partial |

## Notes

- Shared scan semantics remain in `diskscope-core`; both UIs consume patch/progress events from the same core.
- Native frontend currently prioritizes functional parity; platform polish iteration is ongoing.
