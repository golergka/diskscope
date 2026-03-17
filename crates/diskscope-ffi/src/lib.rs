use diskscope_core::events::{ProgressStats, RealtimeScanRequest, ScanEvent, ScanProfile};
use diskscope_core::model::{ChildrenState, NodeKind, SizeState};
use diskscope_core::pro_monitor::{NoProMonitor, ProMonitorApi, PurchaseState, UpgradeCtaTarget};
use diskscope_core::scanner::{spawn_realtime_scan, ScanHandle};
use std::ffi::{c_char, c_void, CStr};
use std::path::PathBuf;
use std::sync::Mutex;
use std::thread::{self, JoinHandle};

const DS_FFI_ABI_VERSION: u32 = 2;
const DS_EVENT_BATCH: u32 = 1;
const DS_EVENT_PROGRESS: u32 = 2;
const DS_EVENT_COMPLETED: u32 = 3;
const DS_EVENT_CANCELLED: u32 = 4;
const DS_EVENT_ERROR: u32 = 5;

#[repr(C)]
#[derive(Clone, Copy)]
pub enum DsPurchaseState {
    Unavailable = 0,
    Locked = 1,
    Unlocked = 2,
}

#[repr(C)]
#[derive(Clone, Copy)]
pub enum DsUpgradeCtaTarget {
    AppStoreAppPage = 0,
    InAppPurchase = 1,
}

#[repr(C)]
#[derive(Clone, Copy)]
pub struct DsProCapabilities {
    pub pro_available: u8,
    pub pro_enabled: u8,
    pub purchase_state: DsPurchaseState,
    pub upgrade_cta_target: DsUpgradeCtaTarget,
}

#[repr(C)]
#[derive(Clone, Copy)]
pub struct DsScanRequest {
    pub root_path: *const c_char,
    pub include_hidden: u8,
    pub follow_symlinks: u8,
    pub one_filesystem: u8,
    pub profile: u32,
    pub worker_override: u32,
    pub queue_limit: u32,
    pub threshold_override: u64,
}

#[repr(C)]
#[derive(Clone, Copy, Debug, Default)]
pub struct DsProgressStats {
    pub directories_seen: u64,
    pub files_seen: u64,
    pub bytes_seen: u64,
    pub occupied_bytes: u64,
    pub total_bytes: u64,
    pub target_bytes: u64,
    pub queued_jobs: u64,
    pub active_workers: u64,
    pub elapsed_ms: u64,
}

#[repr(C)]
#[derive(Clone, Copy, Debug)]
pub struct DsNodePatch {
    pub id: u64,
    pub parent_id: u64,
    pub parent_present: u8,
    pub kind: u8,
    pub size_state: u8,
    pub children_state: u8,
    pub error_flag: u8,
    pub is_hidden: u8,
    pub is_symlink: u8,
    pub _reserved: u8,
    pub size_bytes: u64,
    pub child_count: u32,
    pub name_offset: u32,
    pub name_len: u32,
}

#[repr(C)]
#[derive(Clone, Copy)]
pub struct DsScanEvent {
    pub kind: u32,
    pub progress: DsProgressStats,
    pub patches_ptr: *const DsNodePatch,
    pub patch_count: u32,
    pub string_table_ptr: *const u8,
    pub string_table_len: u32,
    pub message_ptr: *const u8,
    pub message_len: u32,
}

pub type DsScanEventCallback = extern "C" fn(event: *const DsScanEvent, user_data: *mut c_void);

pub struct DsSessionHandle {
    scan_handle: Mutex<Option<ScanHandle>>,
    bridge_thread: Mutex<Option<JoinHandle<()>>>,
}

#[no_mangle]
pub extern "C" fn ds_ffi_abi_version() -> u32 {
    DS_FFI_ABI_VERSION
}

#[no_mangle]
pub extern "C" fn ds_scan_start(
    request: *const DsScanRequest,
    callback: DsScanEventCallback,
    user_data: *mut c_void,
) -> *mut DsSessionHandle {
    let Some(request_ref) = (unsafe { request.as_ref() }) else {
        return std::ptr::null_mut();
    };

    let root = match c_path_to_pathbuf(request_ref.root_path) {
        Some(path) => path,
        None => return std::ptr::null_mut(),
    };

    let mut scan_request = RealtimeScanRequest::with_root(root);
    scan_request.include_hidden = request_ref.include_hidden != 0;
    scan_request.follow_symlinks = request_ref.follow_symlinks != 0;
    scan_request.one_filesystem = request_ref.one_filesystem != 0;
    scan_request.tuning.profile = match request_ref.profile {
        0 => ScanProfile::Conservative,
        2 => ScanProfile::Aggressive,
        _ => ScanProfile::Balanced,
    };
    scan_request.tuning.worker_override =
        (request_ref.worker_override > 0).then_some(request_ref.worker_override as usize);
    if request_ref.queue_limit > 0 {
        scan_request.tuning.queue_limit = request_ref.queue_limit as usize;
    }
    scan_request.tuning.threshold_override =
        (request_ref.threshold_override > 0).then_some(request_ref.threshold_override);

    let (scan_handle, rx) = match spawn_realtime_scan(scan_request) {
        Ok(result) => result,
        Err(_) => return std::ptr::null_mut(),
    };

    let user_data_raw = user_data as usize;
    let bridge_thread = thread::spawn(move || {
        while let Ok(event) = rx.recv() {
            dispatch_event(&event, callback, user_data_raw as *mut c_void);
            if matches!(
                event,
                ScanEvent::Completed | ScanEvent::Cancelled | ScanEvent::Error(_)
            ) {
                break;
            }
        }
    });

    Box::into_raw(Box::new(DsSessionHandle {
        scan_handle: Mutex::new(Some(scan_handle)),
        bridge_thread: Mutex::new(Some(bridge_thread)),
    }))
}

#[no_mangle]
pub extern "C" fn ds_scan_cancel(handle: *mut DsSessionHandle) {
    let Some(handle_ref) = (unsafe { handle.as_ref() }) else {
        return;
    };

    if let Ok(guard) = handle_ref.scan_handle.lock() {
        if let Some(scan) = guard.as_ref() {
            scan.cancel();
        }
    }
}

#[no_mangle]
pub extern "C" fn ds_scan_join(handle: *mut DsSessionHandle) {
    let Some(handle_ref) = (unsafe { handle.as_ref() }) else {
        return;
    };

    if let Ok(mut guard) = handle_ref.scan_handle.lock() {
        if let Some(scan) = guard.as_mut() {
            scan.join();
        }
    }

    if let Ok(mut guard) = handle_ref.bridge_thread.lock() {
        if let Some(thread) = guard.take() {
            let _ = thread.join();
        }
    }
}

#[no_mangle]
pub extern "C" fn ds_scan_free(handle: *mut DsSessionHandle) {
    if handle.is_null() {
        return;
    }

    ds_scan_join(handle);
    unsafe {
        drop(Box::from_raw(handle));
    }
}

#[no_mangle]
pub extern "C" fn ds_pro_capabilities() -> DsProCapabilities {
    let monitor = NoProMonitor;
    let caps = monitor.capabilities();
    DsProCapabilities {
        pro_available: caps.pro_available as u8,
        pro_enabled: caps.pro_enabled as u8,
        purchase_state: match caps.purchase_state {
            PurchaseState::Unavailable => DsPurchaseState::Unavailable,
            PurchaseState::Locked => DsPurchaseState::Locked,
            PurchaseState::Unlocked => DsPurchaseState::Unlocked,
        },
        upgrade_cta_target: match caps.upgrade_cta_target {
            UpgradeCtaTarget::AppStoreAppPage => DsUpgradeCtaTarget::AppStoreAppPage,
            UpgradeCtaTarget::InAppPurchase => DsUpgradeCtaTarget::InAppPurchase,
        },
    }
}

fn c_path_to_pathbuf(path: *const c_char) -> Option<PathBuf> {
    let cstr = unsafe { path.as_ref() }?;
    let value = unsafe { CStr::from_ptr(cstr) }.to_str().ok()?;
    Some(PathBuf::from(value))
}

fn dispatch_event(event: &ScanEvent, callback: DsScanEventCallback, user_data: *mut c_void) {
    match event {
        ScanEvent::Batch(patches) => {
            let mut string_table = Vec::<u8>::new();
            let mut out = Vec::<DsNodePatch>::with_capacity(patches.len());

            for patch in patches {
                let diskscope_core::events::Patch::UpsertNode(node) = patch;
                let name_bytes = node.name.as_bytes();
                let name_offset = string_table.len() as u32;
                string_table.extend_from_slice(name_bytes);

                out.push(DsNodePatch {
                    id: node.id,
                    parent_id: node.parent_id.unwrap_or_default(),
                    parent_present: node.parent_id.is_some() as u8,
                    kind: encode_kind(node.kind),
                    size_state: encode_size_state(node.size_state),
                    children_state: encode_children_state(node.children_state),
                    error_flag: node.error_flag as u8,
                    is_hidden: node.is_hidden as u8,
                    is_symlink: node.is_symlink as u8,
                    _reserved: 0,
                    size_bytes: node.size_bytes,
                    child_count: node.children.len() as u32,
                    name_offset,
                    name_len: name_bytes.len() as u32,
                });
            }

            let ffi_event = DsScanEvent {
                kind: DS_EVENT_BATCH,
                progress: DsProgressStats::default(),
                patches_ptr: out.as_ptr(),
                patch_count: out.len() as u32,
                string_table_ptr: string_table.as_ptr(),
                string_table_len: string_table.len() as u32,
                message_ptr: std::ptr::null(),
                message_len: 0,
            };
            callback(&ffi_event, user_data);
        }
        ScanEvent::Progress(progress) => {
            let ffi_event = DsScanEvent {
                kind: DS_EVENT_PROGRESS,
                progress: encode_progress(progress),
                patches_ptr: std::ptr::null(),
                patch_count: 0,
                string_table_ptr: std::ptr::null(),
                string_table_len: 0,
                message_ptr: std::ptr::null(),
                message_len: 0,
            };
            callback(&ffi_event, user_data);
        }
        ScanEvent::Completed => {
            let ffi_event = DsScanEvent {
                kind: DS_EVENT_COMPLETED,
                progress: DsProgressStats::default(),
                patches_ptr: std::ptr::null(),
                patch_count: 0,
                string_table_ptr: std::ptr::null(),
                string_table_len: 0,
                message_ptr: std::ptr::null(),
                message_len: 0,
            };
            callback(&ffi_event, user_data);
        }
        ScanEvent::Cancelled => {
            let ffi_event = DsScanEvent {
                kind: DS_EVENT_CANCELLED,
                progress: DsProgressStats::default(),
                patches_ptr: std::ptr::null(),
                patch_count: 0,
                string_table_ptr: std::ptr::null(),
                string_table_len: 0,
                message_ptr: std::ptr::null(),
                message_len: 0,
            };
            callback(&ffi_event, user_data);
        }
        ScanEvent::Error(error) => {
            let bytes = error.message.as_bytes();
            let ffi_event = DsScanEvent {
                kind: DS_EVENT_ERROR,
                progress: DsProgressStats::default(),
                patches_ptr: std::ptr::null(),
                patch_count: 0,
                string_table_ptr: std::ptr::null(),
                string_table_len: 0,
                message_ptr: bytes.as_ptr(),
                message_len: bytes.len() as u32,
            };
            callback(&ffi_event, user_data);
        }
    }
}

fn encode_progress(progress: &ProgressStats) -> DsProgressStats {
    DsProgressStats {
        directories_seen: progress.directories_seen,
        files_seen: progress.files_seen,
        bytes_seen: progress.bytes_seen,
        occupied_bytes: progress.occupied_bytes,
        total_bytes: progress.total_bytes,
        target_bytes: progress.target_bytes,
        queued_jobs: progress.queued_jobs as u64,
        active_workers: progress.active_workers as u64,
        elapsed_ms: progress.elapsed_ms as u64,
    }
}

fn encode_kind(kind: NodeKind) -> u8 {
    match kind {
        NodeKind::Directory => 0,
        NodeKind::File => 1,
        NodeKind::CollapsedDirectory => 2,
    }
}

fn encode_size_state(state: SizeState) -> u8 {
    match state {
        SizeState::Unknown => 0,
        SizeState::Partial => 1,
        SizeState::Final => 2,
    }
}

fn encode_children_state(state: ChildrenState) -> u8 {
    match state {
        ChildrenState::Unknown => 0,
        ChildrenState::Partial => 1,
        ChildrenState::Final => 2,
        ChildrenState::CollapsedByThreshold => 3,
    }
}

#[cfg(test)]
mod tests {
    use super::{ds_ffi_abi_version, ds_scan_free, ds_scan_join, ds_scan_start, DsScanRequest};
    use super::{ds_pro_capabilities, DsPurchaseState};
    use std::ffi::CString;
    use std::fs;
    use std::sync::atomic::{AtomicUsize, Ordering};
    use tempfile::tempdir;

    extern "C" fn callback(_event: *const super::DsScanEvent, user_data: *mut std::ffi::c_void) {
        let counter = user_data as *const AtomicUsize;
        if let Some(counter) = unsafe { counter.as_ref() } {
            counter.fetch_add(1, Ordering::Relaxed);
        }
    }

    #[test]
    fn abi_version_is_stable() {
        assert_eq!(ds_ffi_abi_version(), 2);
    }

    #[test]
    fn scan_session_lifecycle_works() {
        let temp = tempdir().unwrap();
        let root_path = temp.path().to_path_buf();
        fs::write(root_path.join("a.bin"), vec![1_u8; 1024]).unwrap();
        fs::create_dir(root_path.join("nested")).unwrap();
        fs::write(root_path.join("nested").join("b.bin"), vec![2_u8; 2048]).unwrap();

        let root = CString::new(root_path.to_string_lossy().to_string()).unwrap();
        let counter = AtomicUsize::new(0);
        let request = DsScanRequest {
            root_path: root.as_ptr(),
            include_hidden: 0,
            follow_symlinks: 0,
            one_filesystem: 1,
            profile: 1,
            worker_override: 1,
            queue_limit: 8,
            threshold_override: 0,
        };

        let handle = ds_scan_start(
            &request,
            callback,
            (&counter as *const AtomicUsize).cast_mut().cast(),
        );
        assert!(!handle.is_null());

        ds_scan_join(handle);
        ds_scan_free(handle);

        assert!(counter.load(Ordering::Relaxed) > 0);
    }

    #[test]
    fn default_pro_capabilities_are_unavailable() {
        let caps = ds_pro_capabilities();
        assert_eq!(caps.pro_available, 0);
        assert_eq!(caps.pro_enabled, 0);
        assert_eq!(
            caps.purchase_state as u32,
            DsPurchaseState::Unavailable as u32
        );
        assert_eq!(
            caps.upgrade_cta_target as u32,
            super::DsUpgradeCtaTarget::AppStoreAppPage as u32
        );
    }
}
