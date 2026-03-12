use diskscope_core::events::Patch;
use diskscope_core::model::{NodeId, NodeSnapshot, ScanModel};
use std::path::PathBuf;

#[derive(Debug, Clone)]
pub struct UiState {
    pub model: ScanModel,
    pub selected_id: NodeId,
    pub zoom_root_id: NodeId,
}

impl UiState {
    pub fn new(root_path: PathBuf, root_name: String) -> Self {
        let model = ScanModel::new(root_path, root_name);
        Self {
            model,
            selected_id: 0,
            zoom_root_id: 0,
        }
    }

    pub fn apply_patch(&mut self, patch: Patch) {
        match patch {
            Patch::UpsertNode(node) => {
                self.model.upsert_node(node);
            }
        }

        if self.model.get(self.selected_id).is_none() {
            self.selected_id = self.model.root_id();
        }
        if self.model.get(self.zoom_root_id).is_none() {
            self.zoom_root_id = self.model.root_id();
        }
    }

    pub fn apply_batch(&mut self, patches: Vec<Patch>) {
        for patch in patches {
            self.apply_patch(patch);
        }
    }

    pub fn node(&self, node_id: NodeId) -> Option<&NodeSnapshot> {
        self.model.get(node_id)
    }

    pub fn path_for_node(&self, node_id: NodeId) -> String {
        let mut segments = Vec::new();
        let mut cursor = Some(node_id);

        while let Some(id) = cursor {
            if let Some(node) = self.model.get(id) {
                segments.push(node.name.clone());
                cursor = node.parent_id;
            } else {
                break;
            }
        }

        if segments.is_empty() {
            return self.model.root_path.display().to_string();
        }

        segments.reverse();
        let mut path = self.model.root_path.clone();
        for segment in segments.into_iter().skip(1) {
            path.push(segment);
        }
        path.display().to_string()
    }
}

#[cfg(test)]
mod tests {
    use super::UiState;
    use diskscope_core::events::Patch;
    use diskscope_core::model::{ChildrenState, NodeKind, NodeSnapshot, SizeState};
    use std::path::PathBuf;

    #[test]
    fn selection_survives_unrelated_patch_updates() {
        let mut state = UiState::new(PathBuf::from("/tmp"), "tmp".to_owned());

        let child_a = NodeSnapshot {
            id: 1,
            parent_id: Some(0),
            name: "a".to_owned(),
            kind: NodeKind::Directory,
            size_bytes: 10,
            size_state: SizeState::Final,
            children_state: ChildrenState::Final,
            error_flag: false,
            is_hidden: false,
            is_symlink: false,
            children: Vec::new(),
        };
        let child_b = NodeSnapshot {
            id: 2,
            parent_id: Some(0),
            name: "b".to_owned(),
            kind: NodeKind::Directory,
            size_bytes: 20,
            size_state: SizeState::Final,
            children_state: ChildrenState::Final,
            error_flag: false,
            is_hidden: false,
            is_symlink: false,
            children: Vec::new(),
        };

        state.apply_patch(Patch::UpsertNode(child_a.clone()));
        state.apply_patch(Patch::UpsertNode(child_b.clone()));
        state.selected_id = 1;
        state.zoom_root_id = 1;

        let updated_b = NodeSnapshot {
            size_bytes: 999,
            ..child_b
        };
        state.apply_patch(Patch::UpsertNode(updated_b));

        assert_eq!(state.selected_id, 1);
        assert_eq!(state.zoom_root_id, 1);
    }
}
