# FFI Contract (`crates/diskscope-ffi`)

## ABI version

- Constant: `DS_FFI_ABI_VERSION = 2`
- Runtime check symbol:
  - `uint32_t ds_ffi_abi_version(void)`

Consumers should validate ABI version before using session APIs.

## Exported symbols

- `ds_ffi_abi_version`
- `ds_scan_start`
- `ds_scan_cancel`
- `ds_scan_join`
- `ds_scan_free`

Swift-friendly wrappers in header:

- `ds_scan_start_ref`
- `ds_scan_cancel_ref`
- `ds_scan_join_ref`
- `ds_scan_free_ref`

## Event kinds

- `DS_EVENT_BATCH = 1`
- `DS_EVENT_PROGRESS = 2`
- `DS_EVENT_COMPLETED = 3`
- `DS_EVENT_CANCELLED = 4`
- `DS_EVENT_ERROR = 5`

## Node/state enums

Node kinds:

- `DS_NODE_KIND_DIRECTORY = 0`
- `DS_NODE_KIND_FILE = 1`
- `DS_NODE_KIND_COLLAPSED_DIRECTORY = 2`

Size states:

- `DS_SIZE_STATE_UNKNOWN = 0`
- `DS_SIZE_STATE_PARTIAL = 1`
- `DS_SIZE_STATE_FINAL = 2`

Children states:

- `DS_CHILDREN_STATE_UNKNOWN = 0`
- `DS_CHILDREN_STATE_PARTIAL = 1`
- `DS_CHILDREN_STATE_FINAL = 2`
- `DS_CHILDREN_STATE_COLLAPSED_BY_THRESHOLD = 3`

## Data structures

### `DsScanRequest`

Input request for a scan session.

Fields:

- `root_path`: UTF-8 C string, required.
- `include_hidden`: `0/1`
- `follow_symlinks`: `0/1`
- `one_filesystem`: `0/1`
- `profile`: `0=Conservative`, `1=Balanced`, `2=Aggressive`
- `worker_override`: optional (`0` means unset)
- `queue_limit`: bounded queue size (`0` means default)
- `threshold_override`: optional bytes (`0` means default)

### `DsProgressStats`

- `directories_seen`
- `files_seen`
- `bytes_seen`
- `occupied_bytes`
- `total_bytes`
- `target_bytes`
- `queued_jobs`
- `active_workers`
- `elapsed_ms`

### `DsNodePatch`

POD node update payload.

- identity/parent:
  - `id`, `parent_id`, `parent_present`
- state:
  - `kind`, `size_state`, `children_state`
- metadata:
  - `error_flag`, `is_hidden`, `is_symlink`
- size/detail:
  - `size_bytes`, `child_count`
- name indirection:
  - `name_offset`, `name_len` into event string table

### `DsScanEvent`

Tagged union-like event envelope.

- `kind`
- `progress`
- batch payload:
  - `patches_ptr`, `patch_count`
  - `string_table_ptr`, `string_table_len`
- error payload:
  - `message_ptr`, `message_len`

## Callback rules

Type:

```c
typedef void (*DsScanEventCallback)(const DsScanEvent *event, void *user_data);
```

Rules:

- callback may be invoked from non-main thread.
- pointers inside `DsScanEvent` are only valid during callback execution.
- consumer must copy any required data before callback returns.
- do not call UI APIs directly from callback thread; dispatch to main thread.

## Session lifecycle

1. `ds_scan_start(...)` -> returns session handle or null.
2. optional `ds_scan_cancel(handle)` to request cancellation.
3. `ds_scan_join(handle)` waits for completion.
4. `ds_scan_free(handle)` releases resources (calls join semantics internally).

Terminal events are one of:

- `Completed`
- `Cancelled`
- `Error`

## Error semantics

- `ds_scan_start` returns null on invalid request or startup failure.
- runtime scan errors are delivered as `DS_EVENT_ERROR` with UTF-8 message bytes.
