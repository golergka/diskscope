use crate::events::{Patch, ProgressStats, RealtimeScanRequest, ScanError, ScanEvent, ScanProfile};
use crate::model::{ChildrenState, NodeId, NodeKind, NodeSnapshot, ScanModel, SizeState};
use crate::volume::{collapse_threshold_bytes, volume_size_bytes};
use crossbeam_channel::{bounded, unbounded, Receiver, Sender};
use globset::{Glob, GlobSet, GlobSetBuilder};
use std::cmp::Ordering;
use std::collections::HashSet;
use std::ffi::{OsStr, OsString};
use std::fs::{self, File, ReadDir};
use std::io::{self, BufWriter, Write};
#[cfg(unix)]
use std::os::unix::fs::MetadataExt;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering as AtomicOrdering};
use std::sync::{Arc, Mutex};
use std::thread::{self, JoinHandle};
use std::time::{Duration, Instant};

const DEFAULT_TOP: usize = 25;
const MAX_ERROR_SAMPLES: usize = 24;
const SNAPSHOT_MAGIC: [u8; 8] = *b"DSCPBIN1";
const SNAPSHOT_VERSION: u32 = 1;
const SNAPSHOT_NODE_RECORD_SIZE: u32 = 44;
const LIVE_UPDATE_INTERVAL_MS: u64 = 100;
const MAX_PENDING_PATCHES: usize = 8_192;
const COORDINATOR_STACK_SIZE_BYTES: usize = 8 * 1024 * 1024;
const WORKER_STACK_SIZE_BYTES: usize = 16 * 1024 * 1024;
const DEFAULT_IGNORE_PATTERNS: [&str; 11] = [
    ".git",
    "node_modules",
    "target",
    "__pycache__",
    ".venv",
    "venv",
    ".cache",
    ".pytest_cache",
    ".mypy_cache",
    ".next",
    "System/Volumes/Data",
];

#[derive(Debug)]
enum ArgError {
    Help,
    Message(String),
}

#[derive(Debug)]
struct Config {
    root: PathBuf,
    top: usize,
    min_size: u64,
    json: bool,
    json_tree: bool,
    snapshot_path: Option<PathBuf>,
    include_hidden: bool,
    follow_symlinks: bool,
    one_filesystem: bool,
    ignore_matcher: IgnoreMatcher,
}

#[derive(Debug, Default)]
struct IgnoreMatcher {
    exact_names: HashSet<OsString>,
    glob_set: Option<GlobSet>,
}

#[derive(Debug, Default)]
struct Stats {
    files: u64,
    dirs: u64,
    skipped_hidden: u64,
    skipped_symlink: u64,
    skipped_other: u64,
    ignored: u64,
    errors: u64,
}

impl Stats {
    fn skipped_total(&self) -> u64 {
        self.skipped_hidden + self.skipped_symlink + self.skipped_other + self.ignored
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
struct FileIdentity {
    dev: u64,
    ino: u64,
}

#[derive(Debug, Default)]
struct SeenEntries {
    dirs: Mutex<HashSet<FileIdentity>>,
    files: Mutex<HashSet<FileIdentity>>,
}

impl SeenEntries {
    fn mark_dir_seen(&self, metadata: &fs::Metadata) -> bool {
        self.mark_seen(&self.dirs, metadata)
    }

    fn mark_file_seen(&self, metadata: &fs::Metadata) -> bool {
        self.mark_seen(&self.files, metadata)
    }

    fn mark_seen(&self, set: &Mutex<HashSet<FileIdentity>>, metadata: &fs::Metadata) -> bool {
        let Some(identity) = metadata_file_identity(metadata) else {
            return true;
        };

        match set.lock() {
            Ok(mut guard) => guard.insert(identity),
            // If the lock is poisoned, continue scanning rather than panic.
            Err(_) => true,
        }
    }
}

#[derive(Debug)]
struct DirNode {
    name: Box<str>,
    parent: Option<usize>,
    size_bytes: u64,
    file_count: u64,
    dir_count: u64,
}

impl DirNode {
    fn new(name: Box<str>, parent: Option<usize>) -> Self {
        Self {
            name,
            parent,
            size_bytes: 0,
            file_count: 0,
            dir_count: 0,
        }
    }
}

#[derive(Debug)]
struct ErrorSample {
    path: PathBuf,
    message: String,
}

#[derive(Debug)]
struct ScanResult {
    root_path: PathBuf,
    nodes: Vec<DirNode>,
    stats: Stats,
    error_samples: Vec<ErrorSample>,
    elapsed_ms: u128,
}

#[derive(Debug)]
struct Frame {
    node_idx: usize,
    entries: ReadDir,
    absolute_path: PathBuf,
    relative_path: PathBuf,
    accumulated_size: u64,
    accumulated_files: u64,
    accumulated_dirs: u64,
}

impl Frame {
    fn new(
        node_idx: usize,
        entries: ReadDir,
        absolute_path: PathBuf,
        relative_path: PathBuf,
    ) -> Self {
        Self {
            node_idx,
            entries,
            absolute_path,
            relative_path,
            accumulated_size: 0,
            accumulated_files: 0,
            accumulated_dirs: 0,
        }
    }
}

pub fn run_legacy_from_iter<I, S>(args: I) -> i32
where
    I: IntoIterator<Item = S>,
    S: Into<String>,
{
    let config = match Config::from_iter(args) {
        Ok(config) => config,
        Err(ArgError::Help) => {
            print_usage();
            return 0;
        }
        Err(ArgError::Message(message)) => {
            eprintln!("error: {message}\n");
            print_usage();
            return 2;
        }
    };

    let scan_result = match scan(&config) {
        Ok(result) => result,
        Err(error) => {
            eprintln!("scan failed: {error}");
            return 1;
        }
    };

    if let Some(snapshot_path) = &config.snapshot_path {
        if let Err(error) = write_binary_snapshot(&scan_result, &config, snapshot_path) {
            eprintln!(
                "failed to write snapshot to {}: {error}",
                snapshot_path.display()
            );
            return 1;
        }
    }

    if config.json {
        print_json(&scan_result, &config);
    } else {
        print_text(&scan_result, &config);
    }

    0
}

pub fn print_legacy_usage() {
    print_usage();
}

pub struct ScanHandle {
    cancel_flag: Arc<AtomicBool>,
    join_handle: Option<JoinHandle<()>>,
}

impl ScanHandle {
    pub fn cancel(&self) {
        self.cancel_flag.store(true, AtomicOrdering::Relaxed);
    }

    pub fn join(&mut self) {
        if let Some(handle) = self.join_handle.take() {
            let _ = handle.join();
        }
    }
}

impl Drop for ScanHandle {
    fn drop(&mut self) {
        self.cancel();
        self.join();
    }
}

#[derive(Clone)]
struct LiveScanConfig {
    include_hidden: bool,
    follow_symlinks: bool,
    one_filesystem: bool,
    threshold_bytes: u64,
    root_dev: Option<u64>,
    ignore_matcher: Arc<IgnoreMatcher>,
    seen_entries: Arc<SeenEntries>,
}

#[derive(Clone)]
struct DirJob {
    node_id: NodeId,
    parent_id: NodeId,
    path: PathBuf,
    relative_path: PathBuf,
    name: String,
}

struct SubtreeResult {
    nodes: Vec<NodeSnapshot>,
    total_size_bytes: u64,
}

#[derive(Default, Clone, Copy)]
struct ProgressDelta {
    directories: u64,
    files: u64,
    bytes: u64,
}

enum WorkerMessage {
    JobStarted,
    JobFinished,
    Progress(ProgressDelta),
    Subtree(SubtreeResult),
    Error(String),
}

struct WorkerProgressEmitter {
    tx: Sender<WorkerMessage>,
    pending: ProgressDelta,
    last_emit: Instant,
}

impl WorkerProgressEmitter {
    fn new(tx: Sender<WorkerMessage>) -> Self {
        Self {
            tx,
            pending: ProgressDelta::default(),
            last_emit: Instant::now(),
        }
    }

    fn bump_directory(&mut self) {
        self.pending.directories += 1;
        self.maybe_emit();
    }

    fn bump_file(&mut self, bytes: u64) {
        self.pending.files += 1;
        self.pending.bytes = self.pending.bytes.saturating_add(bytes);
        self.maybe_emit();
    }

    fn maybe_emit(&mut self) {
        let operations = self.pending.directories + self.pending.files;
        if operations < 256 && self.last_emit.elapsed() < Duration::from_millis(200) {
            return;
        }
        self.flush();
    }

    fn flush(&mut self) {
        if self.pending.directories == 0 && self.pending.files == 0 && self.pending.bytes == 0 {
            return;
        }
        let delta = self.pending;
        self.pending = ProgressDelta::default();
        self.last_emit = Instant::now();
        let _ = self.tx.send(WorkerMessage::Progress(delta));
    }
}

pub fn preview_worker_count(profile: ScanProfile, worker_override: Option<usize>) -> usize {
    if let Some(override_count) = worker_override.filter(|count| *count > 0) {
        return override_count;
    }

    let cpu_count = thread::available_parallelism()
        .map(|count| count.get())
        .unwrap_or(1);

    match profile {
        ScanProfile::Conservative => 1,
        ScanProfile::Balanced => cpu_count.min(2),
        ScanProfile::Aggressive => cpu_count.min(4),
    }
}

pub fn spawn_realtime_scan(
    request: RealtimeScanRequest,
) -> io::Result<(ScanHandle, Receiver<ScanEvent>)> {
    let root = request.root.canonicalize()?;
    if !root.is_dir() {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            format!("{} is not a directory", root.display()),
        ));
    }

    let mut normalized_request = request.clone();
    normalized_request.root = root;

    let (event_tx, event_rx) = unbounded::<ScanEvent>();
    let cancel_flag = Arc::new(AtomicBool::new(false));
    let thread_cancel = Arc::clone(&cancel_flag);

    let join_handle = thread::Builder::new()
        .name("diskscope-scan-coordinator".to_owned())
        .stack_size(COORDINATOR_STACK_SIZE_BYTES)
        .spawn(move || {
            run_realtime_scan(normalized_request, thread_cancel, event_tx);
        })?;

    Ok((
        ScanHandle {
            cancel_flag,
            join_handle: Some(join_handle),
        },
        event_rx,
    ))
}

fn run_realtime_scan(
    request: RealtimeScanRequest,
    cancel_flag: Arc<AtomicBool>,
    event_tx: Sender<ScanEvent>,
) {
    let started_at = Instant::now();
    let threshold_bytes = match request.tuning.threshold_override {
        Some(override_threshold) => override_threshold,
        None => {
            let volume_size = volume_size_bytes(&request.root).unwrap_or(0);
            collapse_threshold_bytes(volume_size)
        }
    };

    let ignore_matcher = match build_live_ignore_matcher(&request.ignore_patterns) {
        Ok(matcher) => matcher,
        Err(error) => {
            let _ = event_tx.send(ScanEvent::Error(ScanError {
                message: error.to_string(),
            }));
            return;
        }
    };

    let root_dev = if request.one_filesystem {
        match path_device_id(&request.root) {
            Ok(device_id) => Some(device_id),
            Err(error) => {
                let _ = event_tx.send(ScanEvent::Error(ScanError {
                    message: format!("failed to query root device id: {error}"),
                }));
                return;
            }
        }
    } else {
        None
    };

    let worker_count = preview_worker_count(request.tuning.profile, request.tuning.worker_override);
    let queue_limit = request.tuning.queue_limit.max(worker_count.max(1));

    let live_config = LiveScanConfig {
        include_hidden: request.include_hidden,
        follow_symlinks: request.follow_symlinks,
        one_filesystem: request.one_filesystem,
        threshold_bytes,
        root_dev,
        ignore_matcher: Arc::new(ignore_matcher),
        seen_entries: Arc::new(SeenEntries::default()),
    };

    if let Ok(root_metadata) = fs::metadata(&request.root) {
        let _ = live_config.seen_entries.mark_dir_seen(&root_metadata);
    }

    let root_name = request
        .root
        .file_name()
        .map(|name| name.to_string_lossy().into_owned())
        .unwrap_or_else(|| request.root.display().to_string());

    let mut model = ScanModel::new(request.root.clone(), root_name);
    let root_id = model.root_id();
    let id_alloc = Arc::new(AtomicU64::new(1));

    let (job_tx, job_rx) = bounded::<DirJob>(queue_limit);
    let (worker_tx, worker_rx) = unbounded::<WorkerMessage>();

    let mut workers = Vec::with_capacity(worker_count);
    for worker_idx in 0..worker_count {
        let worker_jobs = job_rx.clone();
        let worker_events = worker_tx.clone();
        let worker_cancel = Arc::clone(&cancel_flag);
        let worker_alloc = Arc::clone(&id_alloc);
        let worker_config = live_config.clone();
        let worker_name = format!("diskscope-worker-{worker_idx}");
        let spawned = thread::Builder::new()
            .name(worker_name)
            .stack_size(WORKER_STACK_SIZE_BYTES)
            .spawn(move || {
                worker_loop(
                    worker_jobs,
                    worker_events,
                    worker_cancel,
                    worker_alloc,
                    worker_config,
                );
            });

        match spawned {
            Ok(handle) => workers.push(handle),
            Err(error) => {
                cancel_flag.store(true, AtomicOrdering::Relaxed);
                let _ = event_tx.send(ScanEvent::Error(ScanError {
                    message: format!("failed to spawn worker thread: {error}"),
                }));
                drop(worker_tx);
                drop(job_tx);
                for worker in workers {
                    let _ = worker.join();
                }
                return;
            }
        }
    }
    drop(worker_tx);

    let mut root_children = Vec::<NodeId>::new();
    let mut root_size = 0_u64;
    let mut pending_subtrees = 0_usize;
    let mut pending_patches = Vec::<Patch>::new();
    let mut progress = ProgressStats::default();
    progress.target_bytes = volume_size_bytes(&request.root).unwrap_or(0);
    let mut active_workers = 0_usize;

    let root_entries = match fs::read_dir(&request.root) {
        Ok(entries) => entries,
        Err(error) => {
            let _ = event_tx.send(ScanEvent::Error(ScanError {
                message: format!("failed to read root directory: {error}"),
            }));
            return;
        }
    };

    for entry_result in root_entries {
        if cancel_flag.load(AtomicOrdering::Relaxed) {
            let _ = event_tx.send(ScanEvent::Cancelled);
            drop(job_tx);
            for worker in workers {
                let _ = worker.join();
            }
            return;
        }

        let entry = match entry_result {
            Ok(entry) => entry,
            Err(_) => continue,
        };

        let file_name = entry.file_name();
        if should_skip_hidden(&file_name, request.include_hidden) {
            continue;
        }
        if live_config
            .ignore_matcher
            .is_ignored(&file_name, Some(Path::new(&file_name)))
        {
            continue;
        }

        let file_type = match entry.file_type() {
            Ok(file_type) => file_type,
            Err(_) => continue,
        };
        let path = entry.path();
        let is_hidden = file_name
            .to_str()
            .map(|name| name.starts_with('.'))
            .unwrap_or(false);
        let name = file_name.to_string_lossy().into_owned();

        if file_type.is_symlink() {
            if !request.follow_symlinks {
                continue;
            }

            let metadata = match fs::metadata(&path) {
                Ok(metadata) => metadata,
                Err(_) => continue,
            };

            if metadata.is_file() {
                if !live_config.seen_entries.mark_file_seen(&metadata) {
                    continue;
                }

                let size = metadata.len();
                let id = id_alloc.fetch_add(1, AtomicOrdering::Relaxed);
                root_children.push(id);
                root_size = root_size.saturating_add(size);
                progress.files_seen = progress.files_seen.saturating_add(1);
                progress.bytes_seen = progress
                    .bytes_seen
                    .saturating_add(metadata_progress_bytes(&metadata));

                let snapshot = NodeSnapshot {
                    id,
                    parent_id: Some(root_id),
                    name,
                    kind: NodeKind::File,
                    size_bytes: size,
                    size_state: SizeState::Final,
                    children_state: ChildrenState::Final,
                    error_flag: false,
                    is_hidden,
                    is_symlink: true,
                    children: Vec::new(),
                };
                model.upsert_node(snapshot.clone());
                pending_patches.push(Patch::UpsertNode(snapshot));
                if pending_patches.len() >= MAX_PENDING_PATCHES {
                    let batch = std::mem::take(&mut pending_patches);
                    let _ = event_tx.send(ScanEvent::Batch(batch));
                }
                continue;
            }

            if metadata.is_dir() {
                if request.one_filesystem {
                    if let Some(root_device) = live_config.root_dev {
                        if metadata_device_id(&metadata) != root_device {
                            continue;
                        }
                    }
                }
                if !live_config.seen_entries.mark_dir_seen(&metadata) {
                    continue;
                }

                let node_id = id_alloc.fetch_add(1, AtomicOrdering::Relaxed);
                root_children.push(node_id);
                pending_subtrees += 1;

                let placeholder = NodeSnapshot {
                    id: node_id,
                    parent_id: Some(root_id),
                    name: name.clone(),
                    kind: NodeKind::Directory,
                    size_bytes: 0,
                    size_state: SizeState::Unknown,
                    children_state: ChildrenState::Unknown,
                    error_flag: false,
                    is_hidden,
                    is_symlink: true,
                    children: Vec::new(),
                };
                model.upsert_node(placeholder.clone());
                pending_patches.push(Patch::UpsertNode(placeholder));
                if pending_patches.len() >= MAX_PENDING_PATCHES {
                    let batch = std::mem::take(&mut pending_patches);
                    let _ = event_tx.send(ScanEvent::Batch(batch));
                }

                let job = DirJob {
                    node_id,
                    parent_id: root_id,
                    path: path.clone(),
                    relative_path: PathBuf::from(name.clone()),
                    name,
                };
                if job_tx.send(job).is_err() {
                    break;
                }
            }

            continue;
        }

        if file_type.is_file() {
            let metadata = match entry.metadata() {
                Ok(metadata) => metadata,
                Err(_) => continue,
            };
            if !live_config.seen_entries.mark_file_seen(&metadata) {
                continue;
            }

            let size = metadata.len();
            let id = id_alloc.fetch_add(1, AtomicOrdering::Relaxed);
            root_children.push(id);
            root_size = root_size.saturating_add(size);
            progress.files_seen = progress.files_seen.saturating_add(1);
            progress.bytes_seen = progress
                .bytes_seen
                .saturating_add(metadata_progress_bytes(&metadata));

            let snapshot = NodeSnapshot {
                id,
                parent_id: Some(root_id),
                name,
                kind: NodeKind::File,
                size_bytes: size,
                size_state: SizeState::Final,
                children_state: ChildrenState::Final,
                error_flag: false,
                is_hidden,
                is_symlink: false,
                children: Vec::new(),
            };
            model.upsert_node(snapshot.clone());
            pending_patches.push(Patch::UpsertNode(snapshot));
            if pending_patches.len() >= MAX_PENDING_PATCHES {
                let batch = std::mem::take(&mut pending_patches);
                let _ = event_tx.send(ScanEvent::Batch(batch));
            }
            continue;
        }

        if file_type.is_dir() {
            let metadata = match entry.metadata() {
                Ok(metadata) => metadata,
                Err(_) => continue,
            };
            if request.one_filesystem {
                if let Some(root_device) = live_config.root_dev {
                    if metadata_device_id(&metadata) != root_device {
                        continue;
                    }
                }
            }
            if !live_config.seen_entries.mark_dir_seen(&metadata) {
                continue;
            }

            let node_id = id_alloc.fetch_add(1, AtomicOrdering::Relaxed);
            root_children.push(node_id);
            pending_subtrees += 1;

            let placeholder = NodeSnapshot {
                id: node_id,
                parent_id: Some(root_id),
                name: name.clone(),
                kind: NodeKind::Directory,
                size_bytes: 0,
                size_state: SizeState::Unknown,
                children_state: ChildrenState::Unknown,
                error_flag: false,
                is_hidden,
                is_symlink: false,
                children: Vec::new(),
            };
            model.upsert_node(placeholder.clone());
            pending_patches.push(Patch::UpsertNode(placeholder));
            if pending_patches.len() >= MAX_PENDING_PATCHES {
                let batch = std::mem::take(&mut pending_patches);
                let _ = event_tx.send(ScanEvent::Batch(batch));
            }

            let job = DirJob {
                node_id,
                parent_id: root_id,
                path: path.clone(),
                relative_path: PathBuf::from(name.clone()),
                name,
            };
            if job_tx.send(job).is_err() {
                break;
            }
        }
    }

    if let Some(root_node) = model.get_mut(root_id) {
        root_node.size_bytes = root_size;
        root_node.size_state = SizeState::Partial;
        root_node.children_state = ChildrenState::Partial;
        root_node.children = root_children.clone();
        pending_patches.push(Patch::UpsertNode(root_node.clone()));
        if pending_patches.len() >= MAX_PENDING_PATCHES {
            let batch = std::mem::take(&mut pending_patches);
            let _ = event_tx.send(ScanEvent::Batch(batch));
        }
    }

    drop(job_tx);

    let mut last_flush = Instant::now();
    while pending_subtrees > 0 {
        if cancel_flag.load(AtomicOrdering::Relaxed) {
            let _ = event_tx.send(ScanEvent::Cancelled);
            for worker in workers {
                let _ = worker.join();
            }
            return;
        }

        match worker_rx.recv_timeout(Duration::from_millis(30)) {
            Ok(message) => match message {
                WorkerMessage::JobStarted => {
                    active_workers = active_workers.saturating_add(1);
                }
                WorkerMessage::JobFinished => {
                    active_workers = active_workers.saturating_sub(1);
                }
                WorkerMessage::Progress(delta) => {
                    progress.directories_seen =
                        progress.directories_seen.saturating_add(delta.directories);
                    progress.files_seen = progress.files_seen.saturating_add(delta.files);
                    progress.bytes_seen = progress.bytes_seen.saturating_add(delta.bytes);
                }
                WorkerMessage::Subtree(result) => {
                    pending_subtrees = pending_subtrees.saturating_sub(1);
                    root_size = root_size.saturating_add(result.total_size_bytes);
                    for node in result.nodes {
                        model.upsert_node(node.clone());
                        pending_patches.push(Patch::UpsertNode(node));
                        if pending_patches.len() >= MAX_PENDING_PATCHES {
                            let batch = std::mem::take(&mut pending_patches);
                            let _ = event_tx.send(ScanEvent::Batch(batch));
                        }
                    }
                }
                WorkerMessage::Error(message) => {
                    let _ = event_tx.send(ScanEvent::Error(ScanError { message }));
                    for worker in workers {
                        let _ = worker.join();
                    }
                    return;
                }
            },
            Err(crossbeam_channel::RecvTimeoutError::Timeout) => {}
            Err(crossbeam_channel::RecvTimeoutError::Disconnected) => break,
        }

        if last_flush.elapsed() >= Duration::from_millis(LIVE_UPDATE_INTERVAL_MS) {
            progress.queued_jobs = pending_subtrees;
            progress.active_workers = active_workers;
            progress.elapsed_ms = started_at.elapsed().as_millis();
            let _ = event_tx.send(ScanEvent::Progress(progress.clone()));

            if !pending_patches.is_empty() {
                let batch = std::mem::take(&mut pending_patches);
                let _ = event_tx.send(ScanEvent::Batch(batch));
            }
            last_flush = Instant::now();
        }
    }

    for worker in workers {
        let _ = worker.join();
    }

    if let Some(root_node) = model.get_mut(root_id) {
        root_node.size_bytes = root_size;
        root_node.size_state = SizeState::Final;
        root_node.children_state = ChildrenState::Final;
        root_node.children = root_children;
        pending_patches.push(Patch::UpsertNode(root_node.clone()));
        if pending_patches.len() >= MAX_PENDING_PATCHES {
            let batch = std::mem::take(&mut pending_patches);
            let _ = event_tx.send(ScanEvent::Batch(batch));
        }
    }

    progress.queued_jobs = 0;
    progress.active_workers = 0;
    progress.elapsed_ms = started_at.elapsed().as_millis();
    let _ = event_tx.send(ScanEvent::Progress(progress));

    if !pending_patches.is_empty() {
        let _ = event_tx.send(ScanEvent::Batch(pending_patches));
    }

    let _ = event_tx.send(ScanEvent::Completed);
}

fn worker_loop(
    jobs: Receiver<DirJob>,
    tx: Sender<WorkerMessage>,
    cancel_flag: Arc<AtomicBool>,
    id_alloc: Arc<AtomicU64>,
    config: LiveScanConfig,
) {
    while let Ok(job) = jobs.recv() {
        if cancel_flag.load(AtomicOrdering::Relaxed) {
            break;
        }

        let _ = tx.send(WorkerMessage::JobStarted);
        let mut emitter = WorkerProgressEmitter::new(tx.clone());
        let result = scan_directory_subtree(
            &job.path,
            &job.relative_path,
            job.node_id,
            job.parent_id,
            &job.name,
            &config,
            &id_alloc,
            &cancel_flag,
            &mut emitter,
        );
        emitter.flush();
        let _ = tx.send(WorkerMessage::JobFinished);

        match result {
            Ok(subtree) => {
                let _ = tx.send(WorkerMessage::Subtree(subtree));
            }
            Err(error) if error.kind() == io::ErrorKind::Interrupted => break,
            Err(error) => {
                let _ = tx.send(WorkerMessage::Error(format!(
                    "worker failed on {}: {error}",
                    job.path.display()
                )));
                break;
            }
        }
    }
}

fn scan_directory_subtree(
    path: &Path,
    relative_path: &Path,
    node_id: NodeId,
    parent_id: NodeId,
    name: &str,
    config: &LiveScanConfig,
    id_alloc: &AtomicU64,
    cancel_flag: &AtomicBool,
    progress: &mut WorkerProgressEmitter,
) -> io::Result<SubtreeResult> {
    if cancel_flag.load(AtomicOrdering::Relaxed) {
        return Err(io::Error::new(io::ErrorKind::Interrupted, "scan cancelled"));
    }

    progress.bump_directory();

    let mut child_nodes = Vec::<NodeSnapshot>::new();
    let mut child_ids = Vec::<NodeId>::new();
    let mut total_size = 0_u64;
    let mut error_flag = false;
    let mut is_symlink_dir = false;

    let entries = match fs::read_dir(path) {
        Ok(entries) => entries,
        Err(_) => {
            let node = NodeSnapshot {
                id: node_id,
                parent_id: Some(parent_id),
                name: name.to_owned(),
                kind: NodeKind::Directory,
                size_bytes: 0,
                size_state: SizeState::Final,
                children_state: ChildrenState::Final,
                error_flag: true,
                is_hidden: name.starts_with('.'),
                is_symlink: false,
                children: Vec::new(),
            };
            return Ok(SubtreeResult {
                nodes: vec![node],
                total_size_bytes: 0,
            });
        }
    };

    for entry_result in entries {
        if cancel_flag.load(AtomicOrdering::Relaxed) {
            return Err(io::Error::new(io::ErrorKind::Interrupted, "scan cancelled"));
        }

        let entry = match entry_result {
            Ok(entry) => entry,
            Err(_) => {
                error_flag = true;
                continue;
            }
        };

        let file_name = entry.file_name();
        if should_skip_hidden(&file_name, config.include_hidden) {
            continue;
        }

        let mut child_relative = relative_path.to_path_buf();
        child_relative.push(&file_name);
        if config
            .ignore_matcher
            .is_ignored(&file_name, Some(child_relative.as_path()))
        {
            continue;
        }

        let entry_path = path.join(&file_name);
        let file_type = match entry.file_type() {
            Ok(file_type) => file_type,
            Err(_) => {
                error_flag = true;
                continue;
            }
        };

        if file_type.is_symlink() && !config.follow_symlinks {
            continue;
        }

        let child_name = file_name.to_string_lossy().into_owned();
        let child_hidden = child_name.starts_with('.');

        if file_type.is_dir() {
            let metadata = match entry.metadata() {
                Ok(metadata) => metadata,
                Err(_) => {
                    error_flag = true;
                    continue;
                }
            };
            if config.one_filesystem {
                if let Some(root_dev) = config.root_dev {
                    if metadata_device_id(&metadata) != root_dev {
                        continue;
                    }
                }
            }
            if !config.seen_entries.mark_dir_seen(&metadata) {
                continue;
            }

            let child_id = id_alloc.fetch_add(1, AtomicOrdering::Relaxed);
            let child_result = scan_directory_subtree(
                &entry_path,
                &child_relative,
                child_id,
                node_id,
                &child_name,
                config,
                id_alloc,
                cancel_flag,
                progress,
            )?;

            total_size = total_size.saturating_add(child_result.total_size_bytes);
            child_ids.push(child_id);
            child_nodes.extend(child_result.nodes);
            continue;
        }

        if file_type.is_file() {
            let metadata = match entry.metadata() {
                Ok(metadata) => metadata,
                Err(_) => {
                    error_flag = true;
                    continue;
                }
            };
            if !config.seen_entries.mark_file_seen(&metadata) {
                continue;
            }
            let size = metadata.len();
            progress.bump_file(metadata_progress_bytes(&metadata));
            total_size = total_size.saturating_add(size);

            let child_id = id_alloc.fetch_add(1, AtomicOrdering::Relaxed);
            let file_node = NodeSnapshot {
                id: child_id,
                parent_id: Some(node_id),
                name: child_name,
                kind: NodeKind::File,
                size_bytes: size,
                size_state: SizeState::Final,
                children_state: ChildrenState::Final,
                error_flag: false,
                is_hidden: child_hidden,
                is_symlink: false,
                children: Vec::new(),
            };
            child_ids.push(child_id);
            child_nodes.push(file_node);
            continue;
        }

        if file_type.is_symlink() && config.follow_symlinks {
            let metadata = match fs::metadata(&entry_path) {
                Ok(metadata) => metadata,
                Err(_) => {
                    error_flag = true;
                    continue;
                }
            };

            if metadata.is_dir() {
                if config.one_filesystem {
                    if let Some(root_dev) = config.root_dev {
                        if metadata_device_id(&metadata) != root_dev {
                            continue;
                        }
                    }
                }
                if !config.seen_entries.mark_dir_seen(&metadata) {
                    continue;
                }
                is_symlink_dir = true;
                let child_id = id_alloc.fetch_add(1, AtomicOrdering::Relaxed);
                let child_result = scan_directory_subtree(
                    &entry_path,
                    &child_relative,
                    child_id,
                    node_id,
                    &child_name,
                    config,
                    id_alloc,
                    cancel_flag,
                    progress,
                )?;
                total_size = total_size.saturating_add(child_result.total_size_bytes);
                child_ids.push(child_id);
                child_nodes.extend(child_result.nodes);
                continue;
            }

            if metadata.is_file() {
                if !config.seen_entries.mark_file_seen(&metadata) {
                    continue;
                }
                let size = metadata.len();
                progress.bump_file(metadata_progress_bytes(&metadata));
                total_size = total_size.saturating_add(size);

                let child_id = id_alloc.fetch_add(1, AtomicOrdering::Relaxed);
                let file_node = NodeSnapshot {
                    id: child_id,
                    parent_id: Some(node_id),
                    name: child_name,
                    kind: NodeKind::File,
                    size_bytes: size,
                    size_state: SizeState::Final,
                    children_state: ChildrenState::Final,
                    error_flag: false,
                    is_hidden: child_hidden,
                    is_symlink: true,
                    children: Vec::new(),
                };
                child_ids.push(child_id);
                child_nodes.push(file_node);
                continue;
            }
        }
    }

    let should_collapse = node_id != 0 && total_size < config.threshold_bytes;
    if should_collapse {
        // TODO(diskscope): Expand collapsed node on click without rebuilding full scan state.
        let collapsed_node = NodeSnapshot {
            id: node_id,
            parent_id: Some(parent_id),
            name: name.to_owned(),
            kind: NodeKind::CollapsedDirectory,
            size_bytes: total_size,
            size_state: SizeState::Final,
            children_state: ChildrenState::CollapsedByThreshold,
            error_flag,
            is_hidden: name.starts_with('.'),
            is_symlink: is_symlink_dir,
            children: Vec::new(),
        };
        return Ok(SubtreeResult {
            nodes: vec![collapsed_node],
            total_size_bytes: total_size,
        });
    }

    let directory_node = NodeSnapshot {
        id: node_id,
        parent_id: Some(parent_id),
        name: name.to_owned(),
        kind: NodeKind::Directory,
        size_bytes: total_size,
        size_state: SizeState::Final,
        children_state: ChildrenState::Final,
        error_flag,
        is_hidden: name.starts_with('.'),
        is_symlink: is_symlink_dir,
        children: child_ids,
    };

    let mut nodes = Vec::with_capacity(child_nodes.len() + 1);
    nodes.push(directory_node);
    nodes.extend(child_nodes);

    Ok(SubtreeResult {
        nodes,
        total_size_bytes: total_size,
    })
}

fn build_live_ignore_matcher(extra_patterns: &[String]) -> io::Result<IgnoreMatcher> {
    let mut patterns: Vec<String> = DEFAULT_IGNORE_PATTERNS
        .iter()
        .map(|pattern| pattern.to_string())
        .collect();
    patterns.extend(extra_patterns.iter().cloned());
    IgnoreMatcher::from_patterns(&patterns).map_err(|message| {
        io::Error::new(
            io::ErrorKind::InvalidInput,
            format!("invalid ignore pattern: {message}"),
        )
    })
}

impl Config {
    fn from_iter<I, S>(args: I) -> Result<Self, ArgError>
    where
        I: IntoIterator<Item = S>,
        S: Into<String>,
    {
        let mut root: Option<PathBuf> = None;
        let mut top = DEFAULT_TOP;
        let mut min_size = 0_u64;
        let mut json = false;
        let mut json_tree = false;
        let mut snapshot_path: Option<PathBuf> = None;
        let mut include_hidden = false;
        let mut follow_symlinks = false;
        let mut one_filesystem = false;
        let mut use_default_ignores = true;
        let mut ignore_patterns: Vec<String> = Vec::new();
        let mut ignore_files: Vec<PathBuf> = Vec::new();

        let mut iter = args.into_iter().map(Into::into);
        while let Some(arg) = iter.next() {
            match arg.as_str() {
                "-h" | "--help" => return Err(ArgError::Help),
                "--top" => {
                    let value = iter
                        .next()
                        .ok_or_else(|| ArgError::Message("missing value for --top".to_owned()))?;
                    top = value.parse::<usize>().map_err(|_| {
                        ArgError::Message(format!("invalid value for --top: {value}"))
                    })?;
                }
                "--min-size" => {
                    let value = iter.next().ok_or_else(|| {
                        ArgError::Message("missing value for --min-size".to_owned())
                    })?;
                    min_size = parse_size(&value).map_err(|message| {
                        ArgError::Message(format!("invalid --min-size: {message}"))
                    })?;
                }
                "--json" => json = true,
                "--json-tree" => {
                    json_tree = true;
                    json = true;
                }
                "--snapshot" | "--bin" => {
                    let value = iter.next().ok_or_else(|| {
                        ArgError::Message("missing value for --snapshot/--bin".to_owned())
                    })?;
                    snapshot_path = Some(PathBuf::from(value));
                }
                "--include-hidden" => include_hidden = true,
                "--follow-symlinks" => follow_symlinks = true,
                "--one-file-system" | "--xdev" => one_filesystem = true,
                "--ignore" => {
                    let value = iter.next().ok_or_else(|| {
                        ArgError::Message("missing value for --ignore".to_owned())
                    })?;
                    ignore_patterns.push(value);
                }
                "--ignore-from" => {
                    let value = iter.next().ok_or_else(|| {
                        ArgError::Message("missing value for --ignore-from".to_owned())
                    })?;
                    ignore_files.push(PathBuf::from(value));
                }
                "--no-default-ignores" => use_default_ignores = false,
                _ if arg.starts_with('-') => {
                    return Err(ArgError::Message(format!("unknown flag: {arg}")));
                }
                _ => {
                    if root.is_some() {
                        return Err(ArgError::Message(
                            "only one positional path is allowed".to_owned(),
                        ));
                    }
                    root = Some(PathBuf::from(arg));
                }
            }
        }

        if use_default_ignores {
            ignore_patterns.extend(
                DEFAULT_IGNORE_PATTERNS
                    .iter()
                    .map(|pattern| pattern.to_string()),
            );
        }

        for ignore_file in ignore_files {
            ignore_patterns.extend(load_ignore_file(&ignore_file)?);
        }

        let ignore_matcher = IgnoreMatcher::from_patterns(&ignore_patterns)
            .map_err(|message| ArgError::Message(format!("invalid ignore pattern: {message}")))?;

        let root = root.unwrap_or_else(|| PathBuf::from("."));

        Ok(Self {
            root,
            top,
            min_size,
            json,
            json_tree,
            snapshot_path,
            include_hidden,
            follow_symlinks,
            one_filesystem,
            ignore_matcher,
        })
    }
}

impl IgnoreMatcher {
    fn from_patterns(patterns: &[String]) -> Result<Self, String> {
        let mut exact_names = HashSet::new();
        let mut builder = GlobSetBuilder::new();
        let mut has_globs = false;

        for raw_pattern in patterns {
            let pattern = raw_pattern.trim();
            if pattern.is_empty() {
                continue;
            }

            if is_simple_name_pattern(pattern) {
                exact_names.insert(OsString::from(pattern));
                continue;
            }

            if has_path_separator(pattern) {
                add_glob_pattern(&mut builder, pattern)?;
                has_globs = true;
                continue;
            }

            add_glob_pattern(&mut builder, pattern)?;
            add_glob_pattern(&mut builder, &format!("**/{pattern}"))?;
            has_globs = true;
        }

        let glob_set = if has_globs {
            Some(
                builder
                    .build()
                    .map_err(|error| format!("failed to build ignore patterns: {error}"))?,
            )
        } else {
            None
        };

        Ok(Self {
            exact_names,
            glob_set,
        })
    }

    fn needs_rel_path(&self) -> bool {
        self.glob_set.is_some()
    }

    fn is_ignored(&self, file_name: &OsStr, relative_path: Option<&Path>) -> bool {
        if self.exact_names.contains(file_name) {
            return true;
        }

        match (&self.glob_set, relative_path) {
            (Some(glob_set), Some(path)) => glob_set.is_match(path),
            _ => false,
        }
    }
}

fn has_path_separator(pattern: &str) -> bool {
    pattern.contains('/') || pattern.contains('\\')
}

fn has_glob_meta(pattern: &str) -> bool {
    pattern
        .chars()
        .any(|ch| matches!(ch, '*' | '?' | '[' | ']' | '{' | '}' | '!'))
}

fn is_simple_name_pattern(pattern: &str) -> bool {
    !has_path_separator(pattern) && !has_glob_meta(pattern)
}

fn add_glob_pattern(builder: &mut GlobSetBuilder, pattern: &str) -> Result<(), String> {
    let glob =
        Glob::new(pattern).map_err(|error| format!("pattern '{pattern}' is invalid: {error}"))?;
    builder.add(glob);
    Ok(())
}

fn load_ignore_file(path: &Path) -> Result<Vec<String>, ArgError> {
    let content = fs::read_to_string(path).map_err(|error| {
        ArgError::Message(format!(
            "failed to read ignore file {}: {error}",
            path.display()
        ))
    })?;

    let mut patterns = Vec::new();
    for line in content.lines() {
        let trimmed = line.trim();
        if trimmed.is_empty() || trimmed.starts_with('#') {
            continue;
        }
        patterns.push(trimmed.to_owned());
    }

    Ok(patterns)
}

fn scan(config: &Config) -> io::Result<ScanResult> {
    let started_at = Instant::now();

    let root_path = config.root.canonicalize()?;
    if !root_path.is_dir() {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            format!("{} is not a directory", root_path.display()),
        ));
    }

    let root_name = root_path
        .file_name()
        .map(|name| name.to_string_lossy().into_owned())
        .unwrap_or_else(|| root_path.to_string_lossy().into_owned());

    let mut nodes = Vec::with_capacity(4096);
    nodes.push(DirNode::new(root_name.into_boxed_str(), None));

    let mut stats = Stats {
        dirs: 1,
        ..Stats::default()
    };
    let mut error_samples = Vec::new();

    let root_dev = if config.one_filesystem {
        Some(path_device_id(&root_path)?)
    } else {
        None
    };

    let root_entries = fs::read_dir(&root_path)?;
    let seen_entries = SeenEntries::default();
    if let Ok(root_metadata) = fs::metadata(&root_path) {
        let _ = seen_entries.mark_dir_seen(&root_metadata);
    }
    let mut stack = vec![Frame::new(
        0,
        root_entries,
        root_path.clone(),
        PathBuf::new(),
    )];

    while let Some(current_frame) = stack.last_mut() {
        match current_frame.entries.next() {
            Some(Ok(entry)) => {
                let file_name = entry.file_name();

                if should_skip_hidden(&file_name, config.include_hidden) {
                    stats.skipped_hidden += 1;
                    continue;
                }

                let rel_path_for_match = if config.ignore_matcher.needs_rel_path() {
                    let mut rel_path = current_frame.relative_path.clone();
                    rel_path.push(&file_name);
                    Some(rel_path)
                } else {
                    None
                };

                if config
                    .ignore_matcher
                    .is_ignored(&file_name, rel_path_for_match.as_deref())
                {
                    stats.ignored += 1;
                    continue;
                }

                let entry_path = current_frame.absolute_path.join(&file_name);
                let file_type = match entry.file_type() {
                    Ok(file_type) => file_type,
                    Err(error) => {
                        record_error(
                            &mut stats,
                            &mut error_samples,
                            entry_path,
                            format!("file type: {error}"),
                        );
                        continue;
                    }
                };

                if file_type.is_symlink() && !config.follow_symlinks {
                    stats.skipped_symlink += 1;
                    continue;
                }

                if file_type.is_dir() {
                    let metadata = match entry.metadata() {
                        Ok(metadata) => metadata,
                        Err(error) => {
                            record_error(
                                &mut stats,
                                &mut error_samples,
                                entry_path,
                                format!("metadata: {error}"),
                            );
                            continue;
                        }
                    };
                    if let Some(root_dev) = root_dev {
                        if metadata_device_id(&metadata) != root_dev {
                            stats.skipped_other += 1;
                            continue;
                        }
                    }
                    if !seen_entries.mark_dir_seen(&metadata) {
                        stats.skipped_other += 1;
                        continue;
                    }

                    let child_idx = nodes.len();
                    nodes.push(DirNode::new(
                        file_name.to_string_lossy().into_owned().into_boxed_str(),
                        Some(current_frame.node_idx),
                    ));
                    stats.dirs += 1;

                    let mut child_rel_path = current_frame.relative_path.clone();
                    child_rel_path.push(&file_name);

                    match fs::read_dir(&entry_path) {
                        Ok(entries) => {
                            stack.push(Frame::new(child_idx, entries, entry_path, child_rel_path));
                        }
                        Err(error) => {
                            // Keep an empty node for visibility, but continue scanning.
                            record_error(
                                &mut stats,
                                &mut error_samples,
                                entry_path,
                                format!("read_dir: {error}"),
                            );
                            current_frame.accumulated_dirs += 1;
                        }
                    }
                    continue;
                }

                if file_type.is_file() {
                    let metadata = match entry.metadata() {
                        Ok(metadata) => metadata,
                        Err(error) => {
                            record_error(
                                &mut stats,
                                &mut error_samples,
                                entry_path,
                                format!("metadata: {error}"),
                            );
                            continue;
                        }
                    };
                    if !seen_entries.mark_file_seen(&metadata) {
                        stats.skipped_other += 1;
                        continue;
                    }

                    current_frame.accumulated_size = current_frame
                        .accumulated_size
                        .saturating_add(metadata.len());
                    current_frame.accumulated_files += 1;
                    stats.files += 1;
                    continue;
                }

                if file_type.is_symlink() {
                    let metadata = match fs::metadata(&entry_path) {
                        Ok(metadata) => metadata,
                        Err(error) => {
                            record_error(
                                &mut stats,
                                &mut error_samples,
                                entry_path,
                                format!("metadata (follow symlink): {error}"),
                            );
                            continue;
                        }
                    };

                    if metadata.is_dir() {
                        if let Some(root_dev) = root_dev {
                            if metadata_device_id(&metadata) != root_dev {
                                stats.skipped_other += 1;
                                continue;
                            }
                        }
                        if !seen_entries.mark_dir_seen(&metadata) {
                            stats.skipped_other += 1;
                            continue;
                        }

                        let child_idx = nodes.len();
                        nodes.push(DirNode::new(
                            file_name.to_string_lossy().into_owned().into_boxed_str(),
                            Some(current_frame.node_idx),
                        ));
                        stats.dirs += 1;

                        let mut child_rel_path = current_frame.relative_path.clone();
                        child_rel_path.push(&file_name);

                        match fs::read_dir(&entry_path) {
                            Ok(entries) => {
                                stack.push(Frame::new(
                                    child_idx,
                                    entries,
                                    entry_path,
                                    child_rel_path,
                                ));
                            }
                            Err(error) => {
                                record_error(
                                    &mut stats,
                                    &mut error_samples,
                                    entry_path,
                                    format!("read_dir: {error}"),
                                );
                                current_frame.accumulated_dirs += 1;
                            }
                        }
                        continue;
                    }

                    if metadata.is_file() {
                        if !seen_entries.mark_file_seen(&metadata) {
                            stats.skipped_other += 1;
                            continue;
                        }
                        current_frame.accumulated_size = current_frame
                            .accumulated_size
                            .saturating_add(metadata.len());
                        current_frame.accumulated_files += 1;
                        stats.files += 1;
                        continue;
                    }
                }

                stats.skipped_other += 1;
            }
            Some(Err(error)) => {
                record_error(
                    &mut stats,
                    &mut error_samples,
                    current_frame.absolute_path.clone(),
                    format!("read_dir entry: {error}"),
                );
            }
            None => {
                let finished = stack.pop().expect("stack is not empty");

                nodes[finished.node_idx].size_bytes = finished.accumulated_size;
                nodes[finished.node_idx].file_count = finished.accumulated_files;
                nodes[finished.node_idx].dir_count = finished.accumulated_dirs;

                if let Some(parent_frame) = stack.last_mut() {
                    parent_frame.accumulated_size = parent_frame
                        .accumulated_size
                        .saturating_add(finished.accumulated_size);
                    parent_frame.accumulated_files = parent_frame
                        .accumulated_files
                        .saturating_add(finished.accumulated_files);
                    parent_frame.accumulated_dirs = parent_frame
                        .accumulated_dirs
                        .saturating_add(finished.accumulated_dirs.saturating_add(1));
                }
            }
        }
    }

    Ok(ScanResult {
        root_path,
        nodes,
        stats,
        error_samples,
        elapsed_ms: started_at.elapsed().as_millis(),
    })
}

fn write_binary_snapshot(
    result: &ScanResult,
    config: &Config,
    output_path: &Path,
) -> io::Result<()> {
    let ranked = rank_directories(result, config);
    let (first_child, child_count, child_index) = build_child_index(&result.nodes)?;

    let mut name_offsets = Vec::with_capacity(result.nodes.len());
    let mut name_lengths = Vec::with_capacity(result.nodes.len());
    let mut name_blob = Vec::<u8>::new();
    for node in &result.nodes {
        let offset = usize_to_u32(name_blob.len(), "name blob offset")?;
        let length = usize_to_u32(node.name.len(), "name length")?;
        name_offsets.push(offset);
        name_lengths.push(length);
        name_blob.extend_from_slice(node.name.as_bytes());
    }

    let root_path = result.root_path.to_string_lossy().into_owned();
    let root_path_bytes = root_path.as_bytes();

    let file = File::create(output_path)?;
    let mut writer = BufWriter::new(file);

    writer.write_all(&SNAPSHOT_MAGIC)?;
    write_u32_le(&mut writer, SNAPSHOT_VERSION)?;
    write_u32_le(&mut writer, SNAPSHOT_NODE_RECORD_SIZE)?;
    write_u64_le(&mut writer, usize_to_u64(result.nodes.len(), "node count")?)?;
    write_u64_le(
        &mut writer,
        usize_to_u64(child_index.len(), "child index count")?,
    )?;
    write_u64_le(&mut writer, usize_to_u64(ranked.len(), "top index count")?)?;
    write_u64_le(
        &mut writer,
        usize_to_u64(result.error_samples.len(), "error sample count")?,
    )?;
    write_u64_le(
        &mut writer,
        usize_to_u64(name_blob.len(), "name blob size in bytes")?,
    )?;
    write_u64_le(
        &mut writer,
        usize_to_u64(root_path_bytes.len(), "root path size in bytes")?,
    )?;
    write_u64_le(&mut writer, result.nodes[0].size_bytes)?;
    write_u64_le(&mut writer, result.stats.dirs)?;
    write_u64_le(&mut writer, result.stats.files)?;
    write_u64_le(
        &mut writer,
        u128_to_u64(result.elapsed_ms, "elapsed milliseconds")?,
    )?;
    write_u64_le(&mut writer, result.stats.errors)?;
    write_u64_le(&mut writer, result.stats.ignored)?;
    write_u64_le(&mut writer, result.stats.skipped_hidden)?;
    write_u64_le(&mut writer, result.stats.skipped_symlink)?;
    write_u64_le(&mut writer, result.stats.skipped_other)?;

    writer.write_all(root_path_bytes)?;

    for (idx, node) in result.nodes.iter().enumerate() {
        let parent = match node.parent {
            Some(parent_idx) => usize_to_u32(parent_idx, "parent index")?,
            None => u32::MAX,
        };
        write_u32_le(&mut writer, parent)?;
        write_u32_le(&mut writer, first_child[idx])?;
        write_u32_le(&mut writer, child_count[idx])?;
        write_u32_le(&mut writer, name_offsets[idx])?;
        write_u32_le(&mut writer, name_lengths[idx])?;
        write_u64_le(&mut writer, node.size_bytes)?;
        write_u64_le(&mut writer, node.file_count)?;
        write_u64_le(&mut writer, node.dir_count)?;
    }

    for child_idx in &child_index {
        write_u32_le(&mut writer, *child_idx)?;
    }

    for top_idx in ranked {
        write_u32_le(&mut writer, usize_to_u32(top_idx, "top directory index")?)?;
    }

    writer.write_all(&name_blob)?;

    for sample in &result.error_samples {
        let path = sample.path.display().to_string();
        let message = sample.message.as_str();
        let path_bytes = path.as_bytes();
        let message_bytes = message.as_bytes();
        write_u32_le(
            &mut writer,
            usize_to_u32(path_bytes.len(), "error sample path length")?,
        )?;
        write_u32_le(
            &mut writer,
            usize_to_u32(message_bytes.len(), "error sample message length")?,
        )?;
        writer.write_all(path_bytes)?;
        writer.write_all(message_bytes)?;
    }

    writer.flush()
}

fn build_child_index(nodes: &[DirNode]) -> io::Result<(Vec<u32>, Vec<u32>, Vec<u32>)> {
    let mut child_count = vec![0u32; nodes.len()];
    for node in nodes.iter().skip(1) {
        let parent = node
            .parent
            .expect("all non-root nodes must have a parent index");
        child_count[parent] = child_count[parent]
            .checked_add(1)
            .ok_or_else(|| io::Error::new(io::ErrorKind::InvalidData, "too many child nodes"))?;
    }

    let mut first_child = vec![0u32; nodes.len()];
    let mut cursor = 0u32;
    for idx in 0..nodes.len() {
        first_child[idx] = cursor;
        cursor = cursor
            .checked_add(child_count[idx])
            .ok_or_else(|| io::Error::new(io::ErrorKind::InvalidData, "child index overflow"))?;
    }

    let child_index_len = u32_to_usize(cursor, "child index length")?;
    let mut child_index = vec![0u32; child_index_len];
    let mut write_offsets = first_child.clone();

    for (idx, node) in nodes.iter().enumerate().skip(1) {
        let parent = node
            .parent
            .expect("all non-root nodes must have a parent index");
        let write_at = u32_to_usize(write_offsets[parent], "child index write offset")?;
        child_index[write_at] = usize_to_u32(idx, "child index value")?;
        write_offsets[parent] = write_offsets[parent]
            .checked_add(1)
            .ok_or_else(|| io::Error::new(io::ErrorKind::InvalidData, "child write overflow"))?;
    }

    Ok((first_child, child_count, child_index))
}

fn write_u32_le(writer: &mut BufWriter<File>, value: u32) -> io::Result<()> {
    writer.write_all(&value.to_le_bytes())
}

fn write_u64_le(writer: &mut BufWriter<File>, value: u64) -> io::Result<()> {
    writer.write_all(&value.to_le_bytes())
}

fn usize_to_u32(value: usize, field: &str) -> io::Result<u32> {
    u32::try_from(value).map_err(|_| {
        io::Error::new(
            io::ErrorKind::InvalidData,
            format!("{field} exceeds u32 range"),
        )
    })
}

fn usize_to_u64(value: usize, field: &str) -> io::Result<u64> {
    u64::try_from(value).map_err(|_| {
        io::Error::new(
            io::ErrorKind::InvalidData,
            format!("{field} exceeds u64 range"),
        )
    })
}

fn u32_to_usize(value: u32, field: &str) -> io::Result<usize> {
    usize::try_from(value).map_err(|_| {
        io::Error::new(
            io::ErrorKind::InvalidData,
            format!("{field} exceeds usize range"),
        )
    })
}

fn u128_to_u64(value: u128, field: &str) -> io::Result<u64> {
    u64::try_from(value).map_err(|_| {
        io::Error::new(
            io::ErrorKind::InvalidData,
            format!("{field} exceeds u64 range"),
        )
    })
}

#[cfg(unix)]
fn should_skip_hidden(file_name: &OsStr, include_hidden: bool) -> bool {
    use std::os::unix::ffi::OsStrExt;

    if include_hidden {
        return false;
    }

    file_name.as_bytes().first() == Some(&b'.')
}

#[cfg(not(unix))]
fn should_skip_hidden(file_name: &OsStr, include_hidden: bool) -> bool {
    if include_hidden {
        return false;
    }

    file_name
        .to_str()
        .map(|name| name.starts_with('.'))
        .unwrap_or(false)
}

fn record_error(stats: &mut Stats, samples: &mut Vec<ErrorSample>, path: PathBuf, message: String) {
    stats.errors += 1;
    if samples.len() < MAX_ERROR_SAMPLES {
        samples.push(ErrorSample { path, message });
    }
}

#[cfg(unix)]
fn path_device_id(path: &Path) -> io::Result<u64> {
    Ok(fs::metadata(path)?.dev())
}

#[cfg(not(unix))]
fn path_device_id(path: &Path) -> io::Result<u64> {
    let _ = path;
    Ok(0)
}

#[cfg(unix)]
fn metadata_device_id(metadata: &fs::Metadata) -> u64 {
    metadata.dev()
}

#[cfg(not(unix))]
fn metadata_device_id(metadata: &fs::Metadata) -> u64 {
    let _ = metadata;
    0
}

#[cfg(unix)]
fn metadata_file_identity(metadata: &fs::Metadata) -> Option<FileIdentity> {
    Some(FileIdentity {
        dev: metadata.dev(),
        ino: metadata.ino(),
    })
}

#[cfg(not(unix))]
fn metadata_file_identity(_metadata: &fs::Metadata) -> Option<FileIdentity> {
    None
}

#[cfg(unix)]
fn metadata_progress_bytes(metadata: &fs::Metadata) -> u64 {
    let blocks = metadata.blocks() as u64;
    let allocated = blocks.saturating_mul(512);
    if allocated > 0 {
        allocated
    } else {
        metadata.len()
    }
}

#[cfg(not(unix))]
fn metadata_progress_bytes(metadata: &fs::Metadata) -> u64 {
    metadata.len()
}

fn parse_size(raw: &str) -> Result<u64, String> {
    let trimmed = raw.trim();
    if trimmed.is_empty() {
        return Err("empty size string".to_owned());
    }

    let split_at = trimmed
        .find(|ch: char| !ch.is_ascii_digit())
        .unwrap_or(trimmed.len());

    let (number_part, suffix_part) = trimmed.split_at(split_at);
    if number_part.is_empty() {
        return Err(format!("missing number in '{raw}'"));
    }

    let number = number_part
        .parse::<u64>()
        .map_err(|_| format!("could not parse '{number_part}' as integer"))?;

    let multiplier = match suffix_part.trim().to_ascii_lowercase().as_str() {
        "" | "b" => 1,
        "k" | "kb" => 1024,
        "m" | "mb" => 1024_u64.pow(2),
        "g" | "gb" => 1024_u64.pow(3),
        "t" | "tb" => 1024_u64.pow(4),
        other => {
            return Err(format!("unsupported size suffix '{other}'"));
        }
    };

    number
        .checked_mul(multiplier)
        .ok_or_else(|| "size overflows u64".to_owned())
}

fn human_size(bytes: u64) -> String {
    const UNITS: [&str; 5] = ["B", "KiB", "MiB", "GiB", "TiB"];

    if bytes < 1024 {
        return format!("{bytes} B");
    }

    let mut value = bytes as f64;
    let mut unit_idx = 0_usize;

    while value >= 1024.0 && unit_idx < UNITS.len() - 1 {
        value /= 1024.0;
        unit_idx += 1;
    }

    format!("{value:.2} {}", UNITS[unit_idx])
}

fn directory_size_cmp(nodes: &[DirNode], left: usize, right: usize) -> Ordering {
    nodes[right]
        .size_bytes
        .cmp(&nodes[left].size_bytes)
        .then_with(|| left.cmp(&right))
}

fn rank_directories(result: &ScanResult, config: &Config) -> Vec<usize> {
    if config.top == 0 {
        return Vec::new();
    }

    let mut ranked: Vec<usize> = (1..result.nodes.len())
        .filter(|idx| result.nodes[*idx].size_bytes >= config.min_size)
        .collect();

    if ranked.len() > config.top {
        ranked.select_nth_unstable_by(config.top, |left, right| {
            directory_size_cmp(&result.nodes, *left, *right)
        });
        ranked.truncate(config.top);
    }

    ranked.sort_unstable_by(|left, right| directory_size_cmp(&result.nodes, *left, *right));
    ranked
}

fn reconstruct_path(nodes: &[DirNode], root_path: &Path, node_idx: usize) -> PathBuf {
    if node_idx == 0 {
        return root_path.to_path_buf();
    }

    let mut pieces = Vec::new();
    let mut cursor = node_idx;

    while cursor != 0 {
        pieces.push(nodes[cursor].name.as_ref());
        cursor = nodes[cursor]
            .parent
            .expect("non-root nodes must always have a parent");
    }

    let mut path = root_path.to_path_buf();
    for piece in pieces.iter().rev() {
        path.push(piece);
    }

    path
}

fn print_text(result: &ScanResult, config: &Config) {
    let root = &result.nodes[0];

    println!("Root: {}", result.root_path.display());
    println!(
        "Size: {} ({})",
        human_size(root.size_bytes),
        root.size_bytes
    );
    println!(
        "Scanned: {} directories, {} files",
        result.stats.dirs, result.stats.files
    );
    println!(
        "Skipped: {} entries (hidden: {}, symlink: {}, ignored: {}, other: {})",
        result.stats.skipped_total(),
        result.stats.skipped_hidden,
        result.stats.skipped_symlink,
        result.stats.ignored,
        result.stats.skipped_other
    );
    println!("Elapsed: {} ms", result.elapsed_ms);

    let ranked = rank_directories(result, config);

    println!();
    println!(
        "Top {} directories >= {}",
        config.top,
        human_size(config.min_size)
    );

    if ranked.is_empty() {
        println!("(no directories matched)");
    } else {
        for (rank, node_idx) in ranked.iter().enumerate() {
            let node = &result.nodes[*node_idx];
            let path = reconstruct_path(&result.nodes, &result.root_path, *node_idx);
            println!(
                "{:>2}. {:>10}  files: {:>8}  dirs: {:>6}  {}",
                rank + 1,
                human_size(node.size_bytes),
                node.file_count,
                node.dir_count,
                path.display()
            );
        }
    }

    if result.stats.errors > 0 {
        println!();
        println!("Errors: {}", result.stats.errors);
        for sample in &result.error_samples {
            println!("- {} ({})", sample.path.display(), sample.message);
        }
        if result.stats.errors as usize > result.error_samples.len() {
            println!(
                "- ... ({} more errors)",
                result.stats.errors as usize - result.error_samples.len()
            );
        }
    }
}

fn print_json(result: &ScanResult, config: &Config) {
    let root = &result.nodes[0];
    let ranked = rank_directories(result, config);

    println!("{{");
    println!(
        "  \"root\": \"{}\",",
        json_escape(&result.root_path.display().to_string())
    );
    println!("  \"elapsed_ms\": {},", result.elapsed_ms);
    println!("  \"directories\": {},", result.stats.dirs);
    println!("  \"files\": {},", result.stats.files);
    println!("  \"ignored\": {},", result.stats.ignored);
    println!("  \"skipped_total\": {},", result.stats.skipped_total());
    println!("  \"skipped_hidden\": {},", result.stats.skipped_hidden);
    println!("  \"skipped_symlink\": {},", result.stats.skipped_symlink);
    println!("  \"skipped_other\": {},", result.stats.skipped_other);
    println!("  \"errors\": {},", result.stats.errors);
    println!("  \"total_size_bytes\": {},", root.size_bytes);
    println!("  \"top\": [");

    for (idx, node_idx) in ranked.iter().enumerate() {
        let node = &result.nodes[*node_idx];
        let path = reconstruct_path(&result.nodes, &result.root_path, *node_idx);
        let suffix = if idx + 1 == ranked.len() { "" } else { "," };
        println!("    {{");
        println!(
            "      \"path\": \"{}\",",
            json_escape(&path.display().to_string())
        );
        println!("      \"size_bytes\": {},", node.size_bytes);
        println!("      \"file_count\": {},", node.file_count);
        println!("      \"dir_count\": {}", node.dir_count);
        println!("    }}{suffix}");
    }

    println!("  ],");

    if config.json_tree {
        println!("  \"tree\": [");
        for (idx, node) in result.nodes.iter().enumerate() {
            let suffix = if idx + 1 == result.nodes.len() {
                ""
            } else {
                ","
            };
            println!("    {{");
            println!("      \"id\": {idx},");
            match node.parent {
                Some(parent) => println!("      \"parent\": {parent},"),
                None => println!("      \"parent\": null,"),
            }
            println!("      \"name\": \"{}\",", json_escape(node.name.as_ref()));
            println!("      \"size_bytes\": {},", node.size_bytes);
            println!("      \"file_count\": {},", node.file_count);
            println!("      \"dir_count\": {}", node.dir_count);
            println!("    }}{suffix}");
        }
        println!("  ],");
    }

    println!("  \"error_samples\": [");
    for (idx, sample) in result.error_samples.iter().enumerate() {
        let suffix = if idx + 1 == result.error_samples.len() {
            ""
        } else {
            ","
        };
        println!("    {{");
        println!(
            "      \"path\": \"{}\",",
            json_escape(&sample.path.display().to_string())
        );
        println!("      \"message\": \"{}\"", json_escape(&sample.message));
        println!("    }}{suffix}");
    }
    println!("  ]");

    println!("}}");
}

fn json_escape(input: &str) -> String {
    let mut escaped = String::with_capacity(input.len() + 8);
    for ch in input.chars() {
        match ch {
            '"' => escaped.push_str("\\\""),
            '\\' => escaped.push_str("\\\\"),
            '\n' => escaped.push_str("\\n"),
            '\r' => escaped.push_str("\\r"),
            '\t' => escaped.push_str("\\t"),
            c if c.is_control() => escaped.push_str(&format!("\\u{:04x}", c as u32)),
            c => escaped.push(c),
        }
    }
    escaped
}

fn print_usage() {
    println!("Usage: diskscope [PATH] [options]\n");
    println!("Options:");
    println!("  --top N               Show top N largest directories (default: {DEFAULT_TOP})");
    println!("  --min-size SIZE       Filter directory output by size (e.g. 512M, 2G)");
    println!("  --json                Emit JSON summary");
    println!("  --json-tree           Include full directory tree in JSON output (implies --json)");
    println!("  --snapshot PATH       Write binary snapshot for UI");
    println!("  --bin PATH            Alias for --snapshot");
    println!("  --include-hidden      Include dot-files and dot-directories");
    println!("  --follow-symlinks     Follow symlinks (disabled by default)");
    println!("  --one-file-system     Do not cross filesystem boundaries (--xdev alias)");
    println!("  --ignore PATTERN      Ignore pattern (repeatable)");
    println!("  --ignore-from FILE    Load ignore patterns from file");
    println!(
        "  --no-default-ignores  Disable built-in ignores ({})",
        DEFAULT_IGNORE_PATTERNS.join(", ")
    );
    println!("  -h, --help            Show this help");
}

#[cfg(test)]
mod tests {
    use super::{
        build_live_ignore_matcher, parse_size, preview_worker_count, scan_directory_subtree,
        write_binary_snapshot, ChildrenState, Config, DirNode, ErrorSample, IgnoreMatcher,
        LiveScanConfig, NodeKind, ScanProfile, ScanResult, SeenEntries, Stats,
    };
    use crossbeam_channel::unbounded;
    use std::ffi::OsStr;
    use std::path::{Path, PathBuf};
    use std::sync::atomic::{AtomicBool, AtomicU64};
    use std::sync::Arc;
    use std::time::{SystemTime, UNIX_EPOCH};

    #[test]
    fn parse_size_plain_bytes() {
        assert_eq!(parse_size("42").unwrap(), 42);
    }

    #[test]
    fn parse_size_with_suffixes() {
        assert_eq!(parse_size("1k").unwrap(), 1024);
        assert_eq!(parse_size("2MB").unwrap(), 2 * 1024 * 1024);
        assert_eq!(parse_size("3g").unwrap(), 3 * 1024 * 1024 * 1024);
    }

    #[test]
    fn parse_size_rejects_bad_suffix() {
        assert!(parse_size("12XB").is_err());
    }

    #[test]
    fn ignore_matcher_matches_simple_names() {
        let patterns = vec!["node_modules".to_owned()];
        let matcher = IgnoreMatcher::from_patterns(&patterns).unwrap();

        assert!(matcher.is_ignored(OsStr::new("node_modules"), None));
        assert!(!matcher.is_ignored(OsStr::new("src"), None));
    }

    #[test]
    fn ignore_matcher_matches_globs_any_depth() {
        let patterns = vec!["*.log".to_owned()];
        let matcher = IgnoreMatcher::from_patterns(&patterns).unwrap();

        assert!(matcher.is_ignored(OsStr::new("root.log"), Some(Path::new("root.log"))));
        assert!(matcher.is_ignored(
            OsStr::new("service.log"),
            Some(Path::new("var/log/service.log"))
        ));
        assert!(!matcher.is_ignored(
            OsStr::new("service.txt"),
            Some(Path::new("var/log/service.txt"))
        ));
    }

    #[test]
    fn config_json_tree_implies_json() {
        let config = Config::from_iter(vec!["--json-tree"]).unwrap();
        assert!(config.json);
        assert!(config.json_tree);
    }

    #[test]
    fn config_uses_default_ignores_unless_disabled() {
        let with_defaults = Config::from_iter(Vec::<String>::new()).unwrap();
        let without_defaults = Config::from_iter(vec!["--no-default-ignores"]).unwrap();

        assert!(with_defaults
            .ignore_matcher
            .is_ignored(OsStr::new("target"), None));
        assert!(!without_defaults
            .ignore_matcher
            .is_ignored(OsStr::new("target"), None));
    }

    #[test]
    fn config_parses_snapshot_path() {
        let config = Config::from_iter(vec!["--snapshot", "/tmp/snap.bin"]).unwrap();
        assert_eq!(
            config.snapshot_path.as_deref(),
            Some(Path::new("/tmp/snap.bin"))
        );
    }

    #[test]
    fn binary_snapshot_writes_expected_magic() {
        let mut root = DirNode::new("root".into(), None);
        root.size_bytes = 4096;
        root.file_count = 2;
        root.dir_count = 1;

        let mut child = DirNode::new("child".into(), Some(0));
        child.size_bytes = 1024;
        child.file_count = 1;
        child.dir_count = 0;

        let result = ScanResult {
            root_path: PathBuf::from("/tmp/root"),
            nodes: vec![root, child],
            stats: Stats {
                files: 2,
                dirs: 2,
                skipped_hidden: 0,
                skipped_symlink: 0,
                skipped_other: 0,
                ignored: 0,
                errors: 1,
            },
            error_samples: vec![ErrorSample {
                path: PathBuf::from("/tmp/root/child"),
                message: "permission denied".to_owned(),
            }],
            elapsed_ms: 12,
        };

        let config = Config::from_iter(vec!["--top", "5"]).unwrap();
        let stamp = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let snapshot_path = std::env::temp_dir().join(format!("diskscope-{stamp}.bin"));

        write_binary_snapshot(&result, &config, &snapshot_path).unwrap();
        let bytes = std::fs::read(&snapshot_path).unwrap();
        assert!(bytes.len() > 64);
        assert_eq!(&bytes[0..8], b"DSCPBIN1");

        let _ = std::fs::remove_file(snapshot_path);
    }

    #[test]
    fn preview_worker_count_respects_override() {
        assert_eq!(preview_worker_count(ScanProfile::Balanced, Some(7)), 7);
        assert_eq!(preview_worker_count(ScanProfile::Conservative, Some(1)), 1);
    }

    #[test]
    fn preview_worker_count_profiles_are_bounded() {
        let conservative = preview_worker_count(ScanProfile::Conservative, None);
        let balanced = preview_worker_count(ScanProfile::Balanced, None);
        let aggressive = preview_worker_count(ScanProfile::Aggressive, None);

        assert_eq!(conservative, 1);
        assert!(balanced >= 1);
        assert!(aggressive >= balanced);
    }

    #[test]
    fn small_directory_collapses_below_threshold() {
        let stamp = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let root = std::env::temp_dir().join(format!("diskscope-small-{stamp}"));
        let child = root.join("child");
        std::fs::create_dir_all(&child).unwrap();
        std::fs::write(child.join("tiny.txt"), b"hello").unwrap();

        let config = LiveScanConfig {
            include_hidden: true,
            follow_symlinks: false,
            one_filesystem: false,
            threshold_bytes: 1024,
            root_dev: None,
            ignore_matcher: Arc::new(build_live_ignore_matcher(&[]).unwrap()),
            seen_entries: Arc::new(SeenEntries::default()),
        };
        let id_alloc = AtomicU64::new(2);
        let cancel = AtomicBool::new(false);
        let (tx, _rx) = unbounded();
        let mut progress = super::WorkerProgressEmitter::new(tx);

        let result = scan_directory_subtree(
            &child,
            Path::new("child"),
            1,
            0,
            "child",
            &config,
            &id_alloc,
            &cancel,
            &mut progress,
        )
        .unwrap();

        assert_eq!(result.nodes.len(), 1);
        let node = &result.nodes[0];
        assert_eq!(node.kind, NodeKind::CollapsedDirectory);
        assert_eq!(node.children_state, ChildrenState::CollapsedByThreshold);

        let _ = std::fs::remove_dir_all(root);
    }

    #[test]
    fn large_directory_keeps_file_leaves() {
        let stamp = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let root = std::env::temp_dir().join(format!("diskscope-large-{stamp}"));
        let child = root.join("child");
        std::fs::create_dir_all(&child).unwrap();
        let payload = vec![0_u8; 2048];
        std::fs::write(child.join("big.bin"), payload).unwrap();

        let config = LiveScanConfig {
            include_hidden: true,
            follow_symlinks: false,
            one_filesystem: false,
            threshold_bytes: 1024,
            root_dev: None,
            ignore_matcher: Arc::new(build_live_ignore_matcher(&[]).unwrap()),
            seen_entries: Arc::new(SeenEntries::default()),
        };
        let id_alloc = AtomicU64::new(2);
        let cancel = AtomicBool::new(false);
        let (tx, _rx) = unbounded();
        let mut progress = super::WorkerProgressEmitter::new(tx);

        let result = scan_directory_subtree(
            &child,
            Path::new("child"),
            1,
            0,
            "child",
            &config,
            &id_alloc,
            &cancel,
            &mut progress,
        )
        .unwrap();

        assert!(result.nodes.len() >= 2);
        let root_node = &result.nodes[0];
        assert_eq!(root_node.kind, NodeKind::Directory);
        assert_eq!(root_node.children_state, ChildrenState::Final);

        let _ = std::fs::remove_dir_all(root);
    }
}
