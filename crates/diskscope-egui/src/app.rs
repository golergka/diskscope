use crate::state::UiState;
use crate::treemap;
use crossbeam_channel::Receiver;
use diskscope_core::events::{ProgressStats, RealtimeScanRequest, ScanEvent, ScanProfile};
use diskscope_core::model::{ChildrenState, NodeKind, SizeState};
use diskscope_core::scanner::{self, ScanHandle};
use diskscope_core::volume::volume_size_bytes;
use eframe::egui::{self, Align, Color32, FontId, Layout, RichText, Sense};
use std::collections::HashSet;
use std::path::PathBuf;

#[derive(Debug, Clone, Default)]
pub struct UiLaunchOptions {
    pub auto_start: bool,
    pub root_override: Option<PathBuf>,
}

pub fn run_native_app(launch: UiLaunchOptions) -> Result<(), String> {
    let options = eframe::NativeOptions {
        viewport: egui::ViewportBuilder::default()
            .with_title("Diskscope")
            .with_inner_size([1320.0, 860.0]),
        ..Default::default()
    };

    let app_launch = launch.clone();
    eframe::run_native(
        "Diskscope",
        options,
        Box::new(move |_cc| {
            Ok(Box::new(DiskscopeApp::with_launch_options(
                app_launch.clone(),
            )))
        }),
    )
    .map_err(|error| format!("failed to launch UI: {error}"))
}

pub struct DiskscopeApp {
    path_input: String,
    drives: Vec<PathBuf>,
    selected_drive_idx: usize,
    use_custom_path: bool,
    status_line: String,
    progress: ProgressStats,
    ui_state: Option<UiState>,
    event_rx: Option<Receiver<ScanEvent>>,
    scan_handle: Option<ScanHandle>,
    last_request: Option<RealtimeScanRequest>,
    profile: ScanProfile,
    show_advanced: bool,
    worker_override_input: String,
    queue_limit_input: String,
    threshold_override_input: String,
    aggressive_warning_open: bool,
    pending_aggressive_request: Option<RealtimeScanRequest>,
    hovered_node: Option<u64>,
    layout_items: Vec<treemap::TreemapItem>,
    layout_dirty: bool,
    layout_zoom_root: u64,
    layout_rect: Option<egui::Rect>,
    expanded_nodes: HashSet<u64>,
    show_secondary_views: bool,
}

impl Default for DiskscopeApp {
    fn default() -> Self {
        let drives = discover_drives();
        let default_path = std::env::current_dir()
            .unwrap_or_else(|_| PathBuf::from("."))
            .display()
            .to_string();

        Self {
            path_input: default_path,
            status_line: "Ready".to_owned(),
            progress: ProgressStats::default(),
            ui_state: None,
            event_rx: None,
            scan_handle: None,
            last_request: None,
            profile: ScanProfile::Balanced,
            show_advanced: false,
            worker_override_input: String::new(),
            queue_limit_input: "64".to_owned(),
            threshold_override_input: String::new(),
            aggressive_warning_open: false,
            pending_aggressive_request: None,
            hovered_node: None,
            drives,
            selected_drive_idx: 0,
            use_custom_path: false,
            layout_items: Vec::new(),
            layout_dirty: true,
            layout_zoom_root: 0,
            layout_rect: None,
            expanded_nodes: HashSet::from([0]),
            show_secondary_views: false,
        }
    }
}

fn discover_drives() -> Vec<PathBuf> {
    let mut drives = Vec::<PathBuf>::new();

    let data_volume = PathBuf::from("/System/Volumes/Data");
    if data_volume.is_dir() {
        drives.push(data_volume);
    }
    drives.push(PathBuf::from("/"));

    let volumes = PathBuf::from("/Volumes");
    if let Ok(entries) = std::fs::read_dir(&volumes) {
        for entry in entries.flatten() {
            let path = entry.path();
            if path.is_dir() {
                drives.push(path);
            }
        }
    }

    let mut seen = HashSet::new();
    drives.retain(|path| seen.insert(path.clone()));
    drives
}

impl DiskscopeApp {
    fn with_launch_options(launch: UiLaunchOptions) -> Self {
        let mut app = Self::default();

        if let Some(path) = launch.root_override {
            app.use_custom_path = true;
            app.path_input = path.display().to_string();
            if let Some(idx) = app.drives.iter().position(|drive| *drive == path) {
                app.selected_drive_idx = idx;
            }
        }

        if launch.auto_start {
            app.start_from_controls();
        }

        app
    }

    fn human_size(bytes: u64) -> String {
        const UNITS: [&str; 6] = ["B", "KiB", "MiB", "GiB", "TiB", "PiB"];
        if bytes < 1024 {
            return format!("{bytes} B");
        }

        let mut value = bytes as f64;
        let mut unit_idx = 0;
        while value >= 1024.0 && unit_idx < UNITS.len() - 1 {
            value /= 1024.0;
            unit_idx += 1;
        }
        format!("{value:.2} {}", UNITS[unit_idx])
    }

    fn sorted_children(ui_state: &UiState, node_id: u64) -> Vec<u64> {
        let mut children = ui_state
            .node(node_id)
            .map(|node| node.children.clone())
            .unwrap_or_default();

        children.sort_unstable_by(|left, right| {
            let left_size = ui_state
                .node(*left)
                .map(|node| node.size_bytes)
                .unwrap_or(0);
            let right_size = ui_state
                .node(*right)
                .map(|node| node.size_bytes)
                .unwrap_or(0);
            right_size.cmp(&left_size)
        });
        children
    }

    fn ancestor_chain(ui_state: &UiState, node_id: u64) -> Vec<u64> {
        let mut chain = Vec::new();
        let mut cursor = Some(node_id);

        while let Some(id) = cursor {
            chain.push(id);
            cursor = ui_state.node(id).and_then(|node| node.parent_id);
        }

        chain
    }

    fn selected_drive_path(&self) -> PathBuf {
        self.drives
            .get(self.selected_drive_idx)
            .cloned()
            .unwrap_or_else(|| PathBuf::from("/"))
    }

    fn render_hierarchy_row(
        ui: &mut egui::Ui,
        ui_state: &UiState,
        node_id: u64,
        depth: usize,
        selected_id: u64,
        expanded_nodes: &HashSet<u64>,
        toggled_nodes: &mut Vec<u64>,
        clicked_select: &mut Option<u64>,
        clicked_zoom: &mut Option<u64>,
    ) {
        let Some(node) = ui_state.node(node_id) else {
            return;
        };

        let name = node.name.clone();
        let kind = node.kind;
        let children_state = node.children_state;
        let size_state = node.size_state;
        let has_children = !node.children.is_empty();
        let size_bytes = node.size_bytes;
        let can_expand = kind == NodeKind::Directory
            && has_children
            && children_state != ChildrenState::CollapsedByThreshold;
        let is_expanded = can_expand && expanded_nodes.contains(&node_id);

        ui.horizontal(|ui| {
            ui.add_space((depth as f32) * 14.0);
            if can_expand {
                let toggle = if is_expanded { "▾" } else { "▸" };
                if ui
                    .add_sized([18.0, 18.0], egui::Button::new(toggle).frame(false))
                    .clicked()
                {
                    toggled_nodes.push(node_id);
                }
            } else {
                ui.add_space(20.0);
            }

            let marker = match kind {
                NodeKind::Directory => "D",
                NodeKind::File => "F",
                NodeKind::CollapsedDirectory => "C",
            };
            let size_label = match size_state {
                SizeState::Unknown => "unknown".to_owned(),
                SizeState::Partial => {
                    if size_bytes == 0 {
                        "estimating...".to_owned()
                    } else {
                        format!("{} (partial)", Self::human_size(size_bytes))
                    }
                }
                SizeState::Final => Self::human_size(size_bytes),
            };
            let mut label = format!("[{marker}] {name}  ({size_label})");
            if children_state == ChildrenState::CollapsedByThreshold {
                label.push_str("  [deferred]");
            }

            let response = ui.selectable_label(selected_id == node_id, label);
            if response.clicked() {
                *clicked_select = Some(node_id);
            }
            if response.double_clicked() {
                *clicked_zoom = Some(node_id);
            }
        });

        if children_state == ChildrenState::CollapsedByThreshold || !is_expanded {
            return;
        }

        for child_id in Self::sorted_children(ui_state, node_id) {
            Self::render_hierarchy_row(
                ui,
                ui_state,
                child_id,
                depth + 1,
                selected_id,
                expanded_nodes,
                toggled_nodes,
                clicked_select,
                clicked_zoom,
            );
        }
    }

    fn render_hierarchy_panel(&mut self, ui: &mut egui::Ui) {
        let Some(ui_state) = &mut self.ui_state else {
            ui.label("No hierarchy yet.");
            return;
        };

        ui.heading("Hierarchy (sorted by size)");
        ui.label("Click to select. Double-click to zoom. Use arrows to expand/collapse.");
        ui.separator();

        let mut clicked_select = None;
        let mut clicked_zoom = None;
        let mut toggled_nodes = Vec::new();
        let zoom_root_id = ui_state.zoom_root_id;
        let selected_id = ui_state.selected_id;
        let expanded_snapshot = self.expanded_nodes.clone();

        egui::ScrollArea::vertical()
            .id_salt("hierarchy-scroll")
            .auto_shrink([false, false])
            .show(ui, |ui| {
                Self::render_hierarchy_row(
                    ui,
                    ui_state,
                    zoom_root_id,
                    0,
                    selected_id,
                    &expanded_snapshot,
                    &mut toggled_nodes,
                    &mut clicked_select,
                    &mut clicked_zoom,
                );
            });

        if let Some(node_id) = clicked_select {
            if ui_state.node(node_id).is_some() {
                ui_state.selected_id = node_id;
            }
        }

        if let Some(node_id) = clicked_zoom {
            if let Some(node) = ui_state.node(node_id) {
                if node.kind == NodeKind::Directory
                    && node.children_state != ChildrenState::CollapsedByThreshold
                {
                    ui_state.zoom_root_id = node_id;
                    ui_state.selected_id = node_id;
                    self.layout_dirty = true;
                    self.expanded_nodes.insert(node_id);
                } else if node.children_state == ChildrenState::CollapsedByThreshold {
                    // TODO(diskscope): Expand collapsed node from hierarchy interaction.
                }
            }
        }

        for node_id in toggled_nodes {
            if !self.expanded_nodes.insert(node_id) {
                self.expanded_nodes.remove(&node_id);
            }
        }
    }

    fn is_scanning(&self) -> bool {
        self.scan_handle.is_some()
    }

    fn poll_events(&mut self) {
        let mut completed = false;

        if let Some(receiver) = &self.event_rx {
            while let Ok(event) = receiver.try_recv() {
                match event {
                    ScanEvent::Batch(patches) => {
                        if let Some(ui_state) = &mut self.ui_state {
                            ui_state.apply_batch(patches);
                            self.layout_dirty = true;
                        }
                    }
                    ScanEvent::Progress(progress) => {
                        self.progress = progress;
                    }
                    ScanEvent::Completed => {
                        self.status_line = "Completed".to_owned();
                        completed = true;
                    }
                    ScanEvent::Cancelled => {
                        self.status_line = "Cancelled".to_owned();
                        completed = true;
                    }
                    ScanEvent::Error(error) => {
                        self.status_line = format!("Error: {}", error.message);
                        completed = true;
                    }
                }
            }
        }

        if completed {
            if let Some(handle) = self.scan_handle.as_mut() {
                handle.join();
            }
            self.scan_handle = None;
            self.event_rx = None;
        }
    }

    fn parse_worker_override(&self) -> Result<Option<usize>, String> {
        let trimmed = self.worker_override_input.trim();
        if trimmed.is_empty() {
            return Ok(None);
        }

        let parsed = trimmed
            .parse::<usize>()
            .map_err(|_| "worker override must be a positive integer".to_owned())?;
        if parsed == 0 {
            return Err("worker override must be >= 1".to_owned());
        }
        Ok(Some(parsed))
    }

    fn parse_queue_limit(&self) -> Result<usize, String> {
        let parsed = self
            .queue_limit_input
            .trim()
            .parse::<usize>()
            .map_err(|_| "queue limit must be a positive integer".to_owned())?;
        if parsed == 0 {
            return Err("queue limit must be >= 1".to_owned());
        }
        Ok(parsed)
    }

    fn parse_threshold_override(&self) -> Result<Option<u64>, String> {
        let trimmed = self.threshold_override_input.trim();
        if trimmed.is_empty() {
            return Ok(None);
        }
        let parsed = trimmed
            .parse::<u64>()
            .map_err(|_| "threshold override must be bytes (u64)".to_owned())?;
        if parsed == 0 {
            return Err("threshold override must be > 0".to_owned());
        }
        Ok(Some(parsed))
    }

    fn build_request(&self) -> Result<RealtimeScanRequest, String> {
        let root = if self.use_custom_path {
            PathBuf::from(self.path_input.trim())
        } else {
            self.drives
                .get(self.selected_drive_idx)
                .cloned()
                .unwrap_or_else(|| PathBuf::from("/"))
        };
        if !root.exists() {
            return Err(format!("path does not exist: {}", root.display()));
        }
        if !root.is_dir() {
            return Err(format!("path is not a directory: {}", root.display()));
        }

        let mut request = RealtimeScanRequest::with_root(root);
        request.tuning.profile = self.profile;
        request.tuning.worker_override = self.parse_worker_override()?;
        request.tuning.queue_limit = self.parse_queue_limit()?;
        request.tuning.threshold_override = self.parse_threshold_override()?;

        Ok(request)
    }

    fn start_scan(&mut self, request: RealtimeScanRequest) {
        if self.is_scanning() {
            return;
        }

        let root_display = request.root.display().to_string();
        let root_name = request
            .root
            .file_name()
            .map(|name| name.to_string_lossy().into_owned())
            .unwrap_or_else(|| root_display.clone());

        match scanner::spawn_realtime_scan(request.clone()) {
            Ok((handle, rx)) => {
                self.status_line = format!("Scanning {}", root_display);
                self.progress = ProgressStats::default();
                self.ui_state = Some(UiState::new(request.root.clone(), root_name));
                self.event_rx = Some(rx);
                self.scan_handle = Some(handle);
                self.last_request = Some(request);
                self.layout_dirty = true;
                self.layout_items.clear();
                self.expanded_nodes.clear();
                self.expanded_nodes.insert(0);
                self.path_input = root_display;
            }
            Err(error) => {
                self.status_line = format!("Failed to start scan: {error}");
            }
        }
    }

    fn start_from_controls(&mut self) {
        match self.build_request() {
            Ok(request) => {
                if request.tuning.profile == ScanProfile::Aggressive {
                    self.pending_aggressive_request = Some(request);
                    self.aggressive_warning_open = true;
                    return;
                }
                self.start_scan(request);
            }
            Err(error) => {
                self.status_line = format!("Invalid controls: {error}");
            }
        }
    }

    fn cancel_scan(&mut self) {
        if let Some(handle) = &self.scan_handle {
            handle.cancel();
            self.status_line = "Cancelling...".to_owned();
        }
    }

    fn rescan(&mut self) {
        if self.is_scanning() {
            return;
        }

        if let Some(request) = self.last_request.clone() {
            self.start_scan(request);
        }
    }

    fn profile_combo(ui: &mut egui::Ui, profile: &mut ScanProfile) {
        egui::ComboBox::from_label("Profile")
            .selected_text(profile.as_str())
            .show_ui(ui, |ui| {
                ui.selectable_value(profile, ScanProfile::Conservative, "Conservative");
                ui.selectable_value(profile, ScanProfile::Balanced, "Balanced");
                ui.selectable_value(profile, ScanProfile::Aggressive, "Aggressive");
            });
    }

    fn render_controls(&mut self, ui: &mut egui::Ui) {
        ui.horizontal(|ui| {
            ui.label("Drive");
            let selected_drive_text = self.selected_drive_path().display().to_string();
            egui::ComboBox::from_id_salt("drive-selector")
                .selected_text(selected_drive_text)
                .width(300.0)
                .show_ui(ui, |ui| {
                    for (idx, drive) in self.drives.iter().enumerate() {
                        let label = drive.display().to_string();
                        ui.selectable_value(&mut self.selected_drive_idx, idx, label);
                    }
                });

            if ui.button("Refresh drives").clicked() {
                self.drives = discover_drives();
                if self.selected_drive_idx >= self.drives.len() {
                    self.selected_drive_idx = 0;
                }
            }

            let start_clicked = ui
                .add_enabled(!self.is_scanning(), egui::Button::new("Start"))
                .clicked();
            if start_clicked {
                self.start_from_controls();
            }

            if ui
                .add_enabled(self.is_scanning(), egui::Button::new("Cancel"))
                .clicked()
            {
                self.cancel_scan();
            }

            if ui
                .add_enabled(!self.is_scanning(), egui::Button::new("Rescan"))
                .clicked()
            {
                self.rescan();
            }

            if let Some(ui_state) = &mut self.ui_state {
                if ui.button("Zoom Out").clicked() {
                    if let Some(node) = ui_state.node(ui_state.zoom_root_id) {
                        if let Some(parent_id) = node.parent_id {
                            ui_state.zoom_root_id = parent_id;
                            ui_state.selected_id = parent_id;
                            self.layout_dirty = true;
                        }
                    }
                }
                if ui.button("Reset View").clicked() {
                    ui_state.zoom_root_id = 0;
                    ui_state.selected_id = 0;
                    self.layout_dirty = true;
                }
            }
        });

        ui.horizontal(|ui| {
            Self::profile_combo(ui, &mut self.profile);
            ui.checkbox(&mut self.show_advanced, "Advanced tuning");
            ui.toggle_value(&mut self.show_secondary_views, "Secondary views");

            let workers_preview = scanner::preview_worker_count(self.profile, None);
            ui.label(format!("Default workers: {workers_preview}"));
        });

        ui.horizontal(|ui| {
            ui.label(format!("State: {}", self.status_line));
            if self.progress.target_bytes > 0 {
                let is_completed = self.status_line == "Completed";
                let shown_seen = self.progress.bytes_seen.min(self.progress.target_bytes);
                let fraction = if is_completed {
                    1.0
                } else {
                    (shown_seen as f64 / self.progress.target_bytes as f64) as f32
                };
                let clamped = fraction.clamp(0.0, 1.0);
                let progress_text = if is_completed {
                    "Completed".to_owned()
                } else {
                    format!(
                        "{} / {} capacity",
                        Self::human_size(shown_seen),
                        Self::human_size(self.progress.target_bytes),
                    )
                };
                ui.add(
                    egui::ProgressBar::new(clamped)
                        .desired_width(360.0)
                        .text(progress_text),
                );
            } else {
                ui.label(format!(
                    "Scanned: {}",
                    Self::human_size(self.progress.bytes_seen)
                ));
            }
        });

        if self.show_advanced {
            ui.separator();
            ui.horizontal(|ui| {
                ui.checkbox(&mut self.use_custom_path, "Use custom path");
                if self.use_custom_path {
                    ui.label("Path");
                    ui.add_sized(
                        [340.0, 22.0],
                        egui::TextEdit::singleline(&mut self.path_input).hint_text("/path/to/scan"),
                    );
                }

                ui.label("Worker override");
                ui.add_sized(
                    [90.0, 22.0],
                    egui::TextEdit::singleline(&mut self.worker_override_input).hint_text("auto"),
                );

                ui.label("Queue limit");
                ui.add_sized(
                    [90.0, 22.0],
                    egui::TextEdit::singleline(&mut self.queue_limit_input),
                );

                ui.label("Threshold override (bytes)");
                ui.add_sized(
                    [150.0, 22.0],
                    egui::TextEdit::singleline(&mut self.threshold_override_input)
                        .hint_text("auto"),
                );
            });

            let selected_drive = self.selected_drive_path();
            match volume_size_bytes(&selected_drive) {
                Ok(bytes) => ui.label(format!(
                    "Selected drive size: {} ({})",
                    selected_drive.display(),
                    Self::human_size(bytes)
                )),
                Err(_) => ui.label(format!(
                    "Selected drive size: {} (unavailable)",
                    selected_drive.display()
                )),
            };
        }
    }

    fn render_sidebar(&mut self, ui: &mut egui::Ui) {
        self.render_hierarchy_panel(ui);
    }

    fn render_selection_details(&self, ui: &mut egui::Ui) {
        if let Some(ui_state) = &self.ui_state {
            if let Some(node) = ui_state.node(ui_state.selected_id) {
                ui.label(format!("Name: {}", node.name));
                ui.label(format!("Kind: {:?}", node.kind));
                ui.label(format!("Size: {}", node.size_bytes));
                ui.label(format!("Size state: {:?}", node.size_state));
                ui.label(format!("Children state: {:?}", node.children_state));
                ui.label(format!("Children: {}", node.children.len()));
                ui.label(format!("Path: {}", ui_state.path_for_node(node.id)));
                ui.label(format!("Hidden: {}", node.is_hidden));
                ui.label(format!("Symlink: {}", node.is_symlink));
                ui.label(format!("Error: {}", node.error_flag));

                if node.children_state == ChildrenState::CollapsedByThreshold {
                    ui.colored_label(
                        Color32::YELLOW,
                        "Details deferred for this subtree (threshold collapse).",
                    );
                    ui.label(RichText::new("TODO: expand-on-click for collapsed nodes").italics());
                    // TODO(diskscope): Implement on-demand expansion for collapsed nodes.
                }
            } else {
                ui.label("No node selected.");
            }
        } else {
            ui.label("No scan model available.");
        }
    }

    fn render_scan_status(&self, ui: &mut egui::Ui) {
        ui.label(format!("State: {}", self.status_line));
        ui.label(format!(
            "Directories seen: {}",
            self.progress.directories_seen
        ));
        ui.label(format!("Files seen: {}", self.progress.files_seen));
        ui.label(format!("Bytes seen: {}", self.progress.bytes_seen));
        ui.label(format!("Target bytes: {}", self.progress.target_bytes));
        ui.label(format!("Queued jobs: {}", self.progress.queued_jobs));
        ui.label(format!("Active workers: {}", self.progress.active_workers));
        ui.label(format!("Elapsed: {} ms", self.progress.elapsed_ms));

        if let Some(hovered) = self.hovered_node {
            ui.label(format!("Hover node id: {hovered}"));
        } else {
            ui.label("Hover node id: none");
        }
    }

    fn render_secondary_views_window(&mut self, ctx: &egui::Context) {
        if !self.show_secondary_views {
            return;
        }

        let mut open = self.show_secondary_views;
        egui::Window::new("Secondary Views")
            .open(&mut open)
            .default_size([360.0, 420.0])
            .resizable(true)
            .show(ctx, |ui| {
                egui::CollapsingHeader::new("Selection details")
                    .default_open(true)
                    .show(ui, |ui| {
                        self.render_selection_details(ui);
                    });

                ui.separator();
                egui::CollapsingHeader::new("Scan status")
                    .default_open(true)
                    .show(ui, |ui| {
                        self.render_scan_status(ui);
                    });
            });
        self.show_secondary_views = open;
    }

    fn render_treemap(&mut self, ui: &mut egui::Ui) {
        let Some(ui_state) = self.ui_state.as_ref() else {
            ui.centered_and_justified(|ui| {
                ui.label("Start a scan to render treemap");
            });
            return;
        };

        let available = ui.available_size();
        let (response, painter) = ui.allocate_painter(available, Sense::click());
        let rect = response.rect;

        if rect.width() < 8.0 || rect.height() < 8.0 {
            painter.text(
                rect.center(),
                egui::Align2::CENTER_CENTER,
                "Treemap area too small (resize panels)",
                FontId::proportional(13.0),
                Color32::LIGHT_GRAY,
            );
            return;
        }

        let should_recompute = self.layout_dirty
            || self.layout_zoom_root != ui_state.zoom_root_id
            || self.layout_rect != Some(rect)
            || (self.layout_items.is_empty()
                && ui_state
                    .node(ui_state.zoom_root_id)
                    .map(|node| !node.children.is_empty())
                    .unwrap_or(false));
        if should_recompute {
            self.layout_items =
                treemap::compute_treemap(&ui_state.model, ui_state.zoom_root_id, rect, 10);
            self.layout_zoom_root = ui_state.zoom_root_id;
            self.layout_rect = Some(rect);
            self.layout_dirty = false;
        }

        if self.layout_items.is_empty() {
            painter.text(
                rect.center(),
                egui::Align2::CENTER_CENTER,
                "No visible nodes yet for this zoom level.",
                FontId::proportional(13.0),
                Color32::LIGHT_GRAY,
            );
        }

        let visuals = ui.visuals().clone();
        let dark_mode = visuals.dark_mode;

        for item in &self.layout_items {
            if let Some(node) = ui_state.node(item.node_id) {
                let is_selected = ui_state.selected_id == item.node_id;
                let fill = treemap::color_for_node(node, item.depth, dark_mode);
                let text_color = treemap::text_color_for_fill(fill, dark_mode);
                painter.rect_filled(item.rect, 0.0, fill);
                painter.rect_stroke(
                    item.rect,
                    0.0,
                    treemap::border_for_node(is_selected, &visuals),
                );

                if item.rect.width() > 80.0 && item.rect.height() > 18.0 {
                    painter.text(
                        item.rect.left_top() + egui::vec2(4.0, 3.0),
                        egui::Align2::LEFT_TOP,
                        &node.name,
                        FontId::proportional(12.0),
                        text_color,
                    );
                }
            }
        }

        self.hovered_node = None;
        if let Some(pointer) = response.hover_pos() {
            for item in self.layout_items.iter().rev() {
                if item.rect.contains(pointer) {
                    self.hovered_node = Some(item.node_id);
                    break;
                }
            }
        }

        let mut clicked_select = None;
        if response.clicked() {
            if let Some(pointer) = response.interact_pointer_pos() {
                for item in self.layout_items.iter().rev() {
                    if item.rect.contains(pointer) {
                        clicked_select = Some(item.node_id);
                        break;
                    }
                }
            }
        }

        let mut clicked_zoom = None;
        if response.double_clicked() {
            if let Some(pointer) = response.interact_pointer_pos() {
                for item in self.layout_items.iter().rev() {
                    if !item.rect.contains(pointer) {
                        continue;
                    }
                    if let Some(node) = ui_state.node(item.node_id) {
                        if node.kind == NodeKind::Directory
                            && node.children_state != ChildrenState::CollapsedByThreshold
                        {
                            clicked_zoom = Some(item.node_id);
                        } else if node.children_state == ChildrenState::CollapsedByThreshold {
                            // TODO(diskscope): Expand collapsed node on click/double-click.
                        }
                    }
                    break;
                }
            }
        }

        let mut expand_nodes = Vec::new();
        if clicked_select.is_some() || clicked_zoom.is_some() {
            if let Some(ui_state) = self.ui_state.as_mut() {
                if let Some(node_id) = clicked_select {
                    ui_state.selected_id = node_id;
                    expand_nodes.extend(Self::ancestor_chain(ui_state, node_id));
                }

                if let Some(node_id) = clicked_zoom {
                    if let Some(node) = ui_state.node(node_id) {
                        if node.kind == NodeKind::Directory
                            && node.children_state != ChildrenState::CollapsedByThreshold
                        {
                            ui_state.zoom_root_id = node_id;
                            ui_state.selected_id = node_id;
                            self.layout_dirty = true;
                            expand_nodes.extend(Self::ancestor_chain(ui_state, node_id));
                        } else if node.children_state == ChildrenState::CollapsedByThreshold {
                            // TODO(diskscope): Expand collapsed node on click/double-click.
                        }
                    }
                }
            }
        }

        for node_id in expand_nodes {
            self.expanded_nodes.insert(node_id);
        }
    }

    fn render_aggressive_warning(&mut self, ctx: &egui::Context) {
        if !self.aggressive_warning_open {
            return;
        }

        egui::Window::new("Aggressive profile warning")
            .collapsible(false)
            .resizable(false)
            .show(ctx, |ui| {
                ui.label(
                    "Aggressive profile may increase disk I/O and can affect responsiveness.\nProceed only if you want this experiment.",
                );
                ui.horizontal(|ui| {
                    if ui.button("Proceed").clicked() {
                        self.aggressive_warning_open = false;
                        if let Some(request) = self.pending_aggressive_request.take() {
                            self.start_scan(request);
                        }
                    }
                    if ui.button("Cancel").clicked() {
                        self.aggressive_warning_open = false;
                        self.pending_aggressive_request = None;
                    }
                });
            });
    }
}

impl eframe::App for DiskscopeApp {
    fn update(&mut self, ctx: &egui::Context, _frame: &mut eframe::Frame) {
        self.poll_events();

        egui::TopBottomPanel::top("controls").show(ctx, |ui| {
            self.render_controls(ui);
        });

        egui::SidePanel::right("sidebar")
            .resizable(true)
            .default_width(310.0)
            .min_width(230.0)
            .max_width(520.0)
            .show(ctx, |ui| {
                self.render_sidebar(ui);
            });

        egui::CentralPanel::default().show(ctx, |ui| {
            ui.with_layout(Layout::top_down(Align::Min), |ui| {
                self.render_treemap(ui);
            });
        });

        self.render_secondary_views_window(ctx);
        self.render_aggressive_warning(ctx);
        ctx.request_repaint_after(std::time::Duration::from_millis(33));
    }
}
