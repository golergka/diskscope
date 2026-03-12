use std::collections::HashMap;
use std::path::PathBuf;

pub type NodeId = u64;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum NodeKind {
    Directory,
    File,
    CollapsedDirectory,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SizeState {
    Unknown,
    Partial,
    Final,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ChildrenState {
    Unknown,
    Partial,
    Final,
    CollapsedByThreshold,
}

#[derive(Debug, Clone)]
pub struct NodeSnapshot {
    pub id: NodeId,
    pub parent_id: Option<NodeId>,
    pub name: String,
    pub kind: NodeKind,
    pub size_bytes: u64,
    pub size_state: SizeState,
    pub children_state: ChildrenState,
    pub error_flag: bool,
    pub is_hidden: bool,
    pub is_symlink: bool,
    pub children: Vec<NodeId>,
}

impl NodeSnapshot {
    pub fn root(name: String) -> Self {
        Self {
            id: 0,
            parent_id: None,
            name,
            kind: NodeKind::Directory,
            size_bytes: 0,
            size_state: SizeState::Unknown,
            children_state: ChildrenState::Partial,
            error_flag: false,
            is_hidden: false,
            is_symlink: false,
            children: Vec::new(),
        }
    }
}

#[derive(Debug, Clone)]
pub struct ScanModel {
    pub root_path: PathBuf,
    nodes: HashMap<NodeId, NodeSnapshot>,
}

impl ScanModel {
    pub fn new(root_path: PathBuf, root_name: String) -> Self {
        let mut nodes = HashMap::new();
        nodes.insert(0, NodeSnapshot::root(root_name));
        Self { root_path, nodes }
    }

    pub fn upsert_node(&mut self, node: NodeSnapshot) {
        if let Some(parent_id) = node.parent_id {
            if let Some(parent) = self.nodes.get_mut(&parent_id) {
                if !parent.children.contains(&node.id) {
                    parent.children.push(node.id);
                }
            }
        }

        self.nodes.insert(node.id, node);
    }

    pub fn get(&self, node_id: NodeId) -> Option<&NodeSnapshot> {
        self.nodes.get(&node_id)
    }

    pub fn get_mut(&mut self, node_id: NodeId) -> Option<&mut NodeSnapshot> {
        self.nodes.get_mut(&node_id)
    }

    pub fn root_id(&self) -> NodeId {
        0
    }
}
