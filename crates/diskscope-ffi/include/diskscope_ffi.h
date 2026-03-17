#ifndef DISKSCOPE_FFI_H
#define DISKSCOPE_FFI_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define DS_FFI_ABI_VERSION 2u
#define DS_EVENT_BATCH 1u
#define DS_EVENT_PROGRESS 2u
#define DS_EVENT_COMPLETED 3u
#define DS_EVENT_CANCELLED 4u
#define DS_EVENT_ERROR 5u

#define DS_NODE_KIND_DIRECTORY 0u
#define DS_NODE_KIND_FILE 1u
#define DS_NODE_KIND_COLLAPSED_DIRECTORY 2u

#define DS_SIZE_STATE_UNKNOWN 0u
#define DS_SIZE_STATE_PARTIAL 1u
#define DS_SIZE_STATE_FINAL 2u

#define DS_CHILDREN_STATE_UNKNOWN 0u
#define DS_CHILDREN_STATE_PARTIAL 1u
#define DS_CHILDREN_STATE_FINAL 2u
#define DS_CHILDREN_STATE_COLLAPSED_BY_THRESHOLD 3u

typedef enum DsPurchaseState {
  DS_PURCHASE_UNAVAILABLE = 0u,
  DS_PURCHASE_LOCKED = 1u,
  DS_PURCHASE_UNLOCKED = 2u,
} DsPurchaseState;

typedef enum DsUpgradeCtaTarget {
  DS_UPGRADE_CTA_APP_STORE_APP_PAGE = 0u,
  DS_UPGRADE_CTA_IN_APP_PURCHASE = 1u,
} DsUpgradeCtaTarget;

typedef struct DsProCapabilities {
  uint8_t pro_available;
  uint8_t pro_enabled;
  DsPurchaseState purchase_state;
  DsUpgradeCtaTarget upgrade_cta_target;
} DsProCapabilities;

typedef struct DsScanRequest {
  const char *root_path;
  uint8_t include_hidden;
  uint8_t follow_symlinks;
  uint8_t one_filesystem;
  uint32_t profile;
  uint32_t worker_override;
  uint32_t queue_limit;
  uint64_t threshold_override;
} DsScanRequest;

typedef struct DsProgressStats {
  uint64_t directories_seen;
  uint64_t files_seen;
  uint64_t bytes_seen;
  uint64_t occupied_bytes;
  uint64_t total_bytes;
  uint64_t target_bytes;
  uint64_t queued_jobs;
  uint64_t active_workers;
  uint64_t elapsed_ms;
} DsProgressStats;

typedef struct DsNodePatch {
  uint64_t id;
  uint64_t parent_id;
  uint8_t parent_present;
  uint8_t kind;
  uint8_t size_state;
  uint8_t children_state;
  uint8_t error_flag;
  uint8_t is_hidden;
  uint8_t is_symlink;
  uint8_t _reserved;
  uint64_t size_bytes;
  uint32_t child_count;
  uint32_t name_offset;
  uint32_t name_len;
} DsNodePatch;

typedef struct DsScanEvent {
  uint32_t kind;
  DsProgressStats progress;
  const DsNodePatch *patches_ptr;
  uint32_t patch_count;
  const uint8_t *string_table_ptr;
  uint32_t string_table_len;
  const uint8_t *message_ptr;
  uint32_t message_len;
} DsScanEvent;

typedef void (*DsScanEventCallback)(const DsScanEvent *event, void *user_data);

typedef void DsSessionHandle;
typedef void *DsSessionHandleRef;

uint32_t ds_ffi_abi_version(void);
DsSessionHandle *ds_scan_start(const DsScanRequest *request, DsScanEventCallback callback, void *user_data);
void ds_scan_cancel(DsSessionHandle *handle);
void ds_scan_join(DsSessionHandle *handle);
void ds_scan_free(DsSessionHandle *handle);
DsProCapabilities ds_pro_capabilities(void);

static inline DsSessionHandleRef ds_scan_start_ref(
    const DsScanRequest *request,
    DsScanEventCallback callback,
    void *user_data
) {
    return (DsSessionHandleRef)ds_scan_start(request, callback, user_data);
}

static inline void ds_scan_cancel_ref(DsSessionHandleRef handle) {
    ds_scan_cancel((DsSessionHandle *)handle);
}

static inline void ds_scan_join_ref(DsSessionHandleRef handle) {
    ds_scan_join((DsSessionHandle *)handle);
}

static inline void ds_scan_free_ref(DsSessionHandleRef handle) {
    ds_scan_free((DsSessionHandle *)handle);
}

#ifdef __cplusplus
}
#endif

#endif
