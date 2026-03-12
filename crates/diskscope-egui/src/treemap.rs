use diskscope_core::model::{ChildrenState, NodeId, NodeKind, NodeSnapshot, ScanModel};
use eframe::egui::{self, Color32, Pos2, Rect, Stroke, Vec2, Visuals};
use std::collections::hash_map::DefaultHasher;
use std::hash::{Hash, Hasher};
use std::path::Path;

const MAX_TREEMAP_ITEMS: usize = 250_000;
const MIN_RECT_EXTENT: f32 = 1.5;
const MIN_RECT_AREA: f32 = 9.0;

#[derive(Debug, Clone)]
pub struct TreemapItem {
    pub node_id: NodeId,
    pub rect: Rect,
    pub depth: usize,
}

pub fn compute_treemap(
    model: &ScanModel,
    root_id: NodeId,
    bounds: Rect,
    max_depth: usize,
) -> Vec<TreemapItem> {
    let mut out = Vec::new();
    out.reserve(4096);
    layout_children(model, root_id, bounds, 0, max_depth, &mut out);
    out
}

fn layout_children(
    model: &ScanModel,
    node_id: NodeId,
    rect: Rect,
    depth: usize,
    max_depth: usize,
    out: &mut Vec<TreemapItem>,
) {
    if depth >= max_depth || out.len() >= MAX_TREEMAP_ITEMS {
        return;
    }

    let Some(node) = model.get(node_id) else {
        return;
    };

    if node.children.is_empty() {
        return;
    }

    let mut children: Vec<NodeId> = node.children.clone();
    children.sort_unstable_by(|left, right| {
        let l_size = model.get(*left).map(|n| n.size_bytes).unwrap_or(0);
        let r_size = model.get(*right).map(|n| n.size_bytes).unwrap_or(0);
        r_size.cmp(&l_size)
    });

    let total: f64 = children
        .iter()
        .map(|id| model.get(*id).map(|n| n.size_bytes.max(1)).unwrap_or(1) as f64)
        .sum();

    if total <= 0.0 {
        return;
    }

    let horizontal = depth % 2 == 0;
    let mut cursor = if horizontal { rect.left() } else { rect.top() };
    let total_extent = if horizontal {
        rect.width()
    } else {
        rect.height()
    };

    for (idx, child_id) in children.iter().enumerate() {
        let child_size = model
            .get(*child_id)
            .map(|n| n.size_bytes.max(1) as f64)
            .unwrap_or(1.0);

        let is_last = idx + 1 == children.len();
        let mut extent = ((child_size / total) as f32) * total_extent;
        if is_last {
            extent = if horizontal {
                rect.right() - cursor
            } else {
                rect.bottom() - cursor
            };
        }

        if extent <= MIN_RECT_EXTENT {
            continue;
        }

        let child_rect = if horizontal {
            Rect::from_min_size(
                Pos2::new(cursor, rect.top()),
                Vec2::new(extent, rect.height()),
            )
        } else {
            Rect::from_min_size(
                Pos2::new(rect.left(), cursor),
                Vec2::new(rect.width(), extent),
            )
        };

        cursor += extent;

        if child_rect.width() * child_rect.height() < MIN_RECT_AREA {
            continue;
        }

        out.push(TreemapItem {
            node_id: *child_id,
            rect: child_rect,
            depth,
        });

        if let Some(child_node) = model.get(*child_id) {
            if child_node.kind == NodeKind::Directory
                && child_node.children_state != ChildrenState::CollapsedByThreshold
            {
                let inset_rect = child_rect.shrink(1.0);
                if inset_rect.width() > 6.0 && inset_rect.height() > 6.0 {
                    layout_children(model, *child_id, inset_rect, depth + 1, max_depth, out);
                }
            }
        }
    }
}

pub fn color_for_node(node: &NodeSnapshot, depth: usize, dark_mode: bool) -> Color32 {
    match node.kind {
        NodeKind::File => {
            let ext = file_extension_key(&node.name);
            let hue = (stable_hash(&ext) % 360) as f32 / 360.0;
            let saturation = if dark_mode { 0.76 } else { 0.66 };
            let value = if dark_mode { 0.86 } else { 0.74 };
            Color32::from(egui::epaint::Hsva::new(hue, saturation, value, 0.96))
        }
        NodeKind::Directory => {
            let hue = (stable_hash(&node.name) % 360) as f32 / 360.0;
            // Keep directory groups visually quiet so file-type colors stay readable.
            let saturation = if dark_mode { 0.12 } else { 0.10 };
            let value = if dark_mode {
                (0.30 + depth as f32 * 0.015).min(0.42)
            } else {
                (0.92 - depth as f32 * 0.015).max(0.78)
            };
            Color32::from(egui::epaint::Hsva::new(hue, saturation, value, 0.95))
        }
        NodeKind::CollapsedDirectory => {
            if dark_mode {
                Color32::from_rgb(136, 112, 52)
            } else {
                Color32::from_rgb(214, 184, 112)
            }
        }
    }
}

pub fn text_color_for_fill(fill: Color32, dark_mode: bool) -> Color32 {
    let luma = perceived_luma(fill);
    if dark_mode {
        if luma > 148.0 {
            Color32::from_rgb(18, 18, 18)
        } else {
            Color32::from_rgb(244, 244, 244)
        }
    } else if luma > 155.0 {
        Color32::from_rgb(18, 18, 18)
    } else {
        Color32::from_rgb(250, 250, 250)
    }
}

pub fn border_for_node(is_selected: bool, visuals: &Visuals) -> Stroke {
    if is_selected {
        Stroke::new(2.0, visuals.selection.stroke.color)
    } else {
        Stroke::new(
            1.0,
            visuals
                .widgets
                .noninteractive
                .bg_stroke
                .color
                .gamma_multiply(if visuals.dark_mode { 1.0 } else { 0.75 }),
        )
    }
}

fn file_extension_key(name: &str) -> String {
    Path::new(name)
        .extension()
        .and_then(|ext| ext.to_str())
        .map(|ext| ext.to_ascii_lowercase())
        .filter(|ext| !ext.is_empty())
        .unwrap_or_else(|| "_no_ext".to_owned())
}

fn stable_hash(value: &str) -> u64 {
    let mut hasher = DefaultHasher::new();
    value.hash(&mut hasher);
    hasher.finish()
}

fn perceived_luma(color: Color32) -> f32 {
    let rgba = color.to_array();
    0.2126 * rgba[0] as f32 + 0.7152 * rgba[1] as f32 + 0.0722 * rgba[2] as f32
}
