use crate::model::NodeSnapshot;
use std::path::PathBuf;

#[derive(Debug, Clone)]
pub enum Patch {
    UpsertNode(NodeSnapshot),
}

#[derive(Debug, Clone, Default)]
pub struct ProgressStats {
    pub directories_seen: u64,
    pub files_seen: u64,
    pub bytes_seen: u64,
    pub occupied_bytes: u64,
    pub total_bytes: u64,
    pub target_bytes: u64,
    pub queued_jobs: usize,
    pub active_workers: usize,
    pub elapsed_ms: u128,
}

#[derive(Debug, Clone)]
pub struct ScanError {
    pub message: String,
}

#[derive(Debug, Clone)]
pub enum ScanEvent {
    Batch(Vec<Patch>),
    Progress(ProgressStats),
    Completed,
    Cancelled,
    Error(ScanError),
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ScanProfile {
    Conservative,
    Balanced,
    Aggressive,
}

impl ScanProfile {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Conservative => "Conservative",
            Self::Balanced => "Balanced",
            Self::Aggressive => "Aggressive",
        }
    }
}

#[derive(Debug, Clone)]
pub struct ScanTuning {
    pub profile: ScanProfile,
    pub worker_override: Option<usize>,
    pub queue_limit: usize,
    pub threshold_override: Option<u64>,
}

impl Default for ScanTuning {
    fn default() -> Self {
        Self {
            profile: ScanProfile::Balanced,
            worker_override: None,
            queue_limit: 64,
            threshold_override: None,
        }
    }
}

#[derive(Debug, Clone)]
pub struct RealtimeScanRequest {
    pub root: PathBuf,
    pub include_hidden: bool,
    pub follow_symlinks: bool,
    pub one_filesystem: bool,
    pub ignore_patterns: Vec<String>,
    pub tuning: ScanTuning,
}

impl RealtimeScanRequest {
    pub fn with_root(root: PathBuf) -> Self {
        Self {
            root,
            include_hidden: false,
            follow_symlinks: false,
            one_filesystem: true,
            ignore_patterns: Vec::new(),
            tuning: ScanTuning::default(),
        }
    }
}
