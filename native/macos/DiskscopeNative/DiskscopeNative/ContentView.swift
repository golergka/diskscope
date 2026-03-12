import AppKit
import SwiftUI

struct ContentView: View {
    @EnvironmentObject var store: NativeScanStore

    var body: some View {
        VStack(spacing: 10) {
            controlBar
            progressBar

            HSplitView {
                hierarchyPane
                    .frame(minWidth: 320, idealWidth: 380, maxWidth: 480)
                treemapPane
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(12)
    }

    private var controlBar: some View {
        VStack(spacing: 8) {
            HStack(spacing: 10) {
                Picker("Drive", selection: $store.selectedDrive) {
                    ForEach(store.availableDrives, id: \.self) { drive in
                        Text(drive).tag(drive)
                    }
                }
                .labelsHidden()
                .frame(minWidth: 220)

                Toggle("Custom path", isOn: $store.useCustomPath)
                    .toggleStyle(.checkbox)

                if store.useCustomPath {
                    TextField("Path", text: $store.customPath)
                        .textFieldStyle(.roundedBorder)
                        .frame(minWidth: 260)
                }

                Picker("Profile", selection: $store.profile) {
                    ForEach(NativeProfile.allCases) { profile in
                        Text(profile.title).tag(profile)
                    }
                }
                .pickerStyle(.menu)
                .frame(width: 170)

                Toggle("Advanced", isOn: $store.showAdvanced)
                    .toggleStyle(.checkbox)

                Spacer()

                Button("Start") {
                    store.startScan()
                }
                Button("Cancel") {
                    store.cancelScan()
                }
                .disabled(store.scanState != .running)
                Button("Rescan") {
                    store.rescan()
                }
            }

            if store.showAdvanced {
                HStack(spacing: 10) {
                    TextField("Workers (override)", text: $store.workerOverrideText)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 170)
                    TextField("Queue limit", text: $store.queueLimitText)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 140)
                    TextField("Threshold bytes", text: $store.thresholdOverrideText)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 170)
                    Spacer()
                }
            }
        }
    }

    private var progressBar: some View {
        HStack(spacing: 10) {
            Text("State: \(store.scanState.label)")
                .font(.headline)

            ProgressView(value: store.progressFraction)
                .frame(maxWidth: .infinity)

            Text("\(store.scannedBytesLabel) / \(store.targetBytesLabel)")
                .font(.system(.body, design: .rounded))
        }
        .overlay(alignment: .leading) {
            Text(store.statusLine)
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.top, 28)
        }
        .padding(.bottom, 16)
    }

    private var hierarchyPane: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Hierarchy")
                    .font(.headline)
                Spacer()
                Button("Up") {
                    store.zoomToParent()
                }
                .disabled(store.zoomNodeId == store.rootNodeId)
                Button("Root") {
                    store.resetZoom()
                }
                .disabled(store.zoomNodeId == store.rootNodeId)
            }

            Text(store.path(for: store.selectedNodeId))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)

            if store.zoomNodeId != store.rootNodeId {
                Text("Zoom root: \(store.path(for: store.zoomNodeId))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Divider()

            HierarchyOutlineView(
                store: store,
                rootId: store.zoomNodeId,
                selectedId: store.selectedNodeId,
                version: store.modelVersion,
                onSelect: { nodeId in
                    store.select(nodeId: nodeId)
                },
                onZoom: { nodeId in
                    store.zoom(to: nodeId)
                },
                onExpandedChanged: { nodeId, expanded in
                    store.setExpanded(nodeId: nodeId, expanded: expanded)
                }
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .padding(8)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var treemapPane: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Treemap")
                    .font(.headline)
                Spacer()
                Button("Reset Zoom") {
                    store.resetZoom()
                }
                .disabled(store.zoomNodeId == store.rootNodeId)
            }

            TreemapView(
                store: store,
                rootId: store.zoomNodeId,
                selectedId: store.selectedNodeId,
                version: store.modelVersion,
                exploredFraction: store.exploredFraction,
                onSelect: { nodeId in
                    store.select(nodeId: nodeId)
                },
                onZoom: { nodeId in
                    store.zoom(to: nodeId)
                }
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .windowBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .padding(8)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

private struct HierarchyOutlineView: NSViewRepresentable {
    let store: NativeScanStore
    let rootId: UInt64
    let selectedId: UInt64
    let version: UInt64
    let onSelect: (UInt64) -> Void
    let onZoom: (UInt64) -> Void
    let onExpandedChanged: (UInt64, Bool) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> HierarchyOutlineContainerView {
        let view = HierarchyOutlineContainerView()
        view.attachCoordinator(context.coordinator)
        view.apply(
            store: store,
            rootId: rootId,
            selectedId: selectedId,
            version: version
        )
        return view
    }

    func updateNSView(_ nsView: HierarchyOutlineContainerView, context: Context) {
        context.coordinator.parent = self
        nsView.attachCoordinator(context.coordinator)
        nsView.apply(
            store: store,
            rootId: rootId,
            selectedId: selectedId,
            version: version
        )
    }

    final class Coordinator: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate {
        var parent: HierarchyOutlineView
        private var cachedVersion: UInt64 = UInt64.max
        private var childrenCache: [UInt64: [UInt64]] = [:]
        private var iconCache: [String: NSImage] = [:]

        init(parent: HierarchyOutlineView) {
            self.parent = parent
        }

        private func resetCacheIfNeeded(for version: UInt64) {
            guard cachedVersion != version else {
                return
            }
            cachedVersion = version
            childrenCache.removeAll(keepingCapacity: true)
        }

        func resetAllCaches() {
            cachedVersion = UInt64.max
            childrenCache.removeAll(keepingCapacity: false)
            iconCache.removeAll(keepingCapacity: false)
        }

        func treeItem(for nodeId: UInt64) -> NSNumber {
            NSNumber(value: nodeId)
        }

        func nodeId(from item: Any?) -> UInt64? {
            guard let number = item as? NSNumber else {
                return nil
            }
            return number.uint64Value
        }

        func children(of nodeId: UInt64, version: UInt64) -> [UInt64] {
            resetCacheIfNeeded(for: version)
            if let cached = childrenCache[nodeId] {
                return cached
            }
            let sorted = parent.store.sortedChildren(of: nodeId)
            childrenCache[nodeId] = sorted
            return sorted
        }

        func outlineView(
            _ outlineView: NSOutlineView,
            numberOfChildrenOfItem item: Any?
        ) -> Int {
            if item == nil {
                return parent.store.node(parent.rootId) == nil ? 0 : 1
            }
            guard let nodeId = nodeId(from: item) else {
                return 0
            }
            return children(of: nodeId, version: parent.version).count
        }

        func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
            if item == nil {
                return treeItem(for: parent.rootId)
            }
            guard let nodeId = nodeId(from: item) else {
                return treeItem(for: parent.rootId)
            }
            let children = children(of: nodeId, version: parent.version)
            if index >= 0 && index < children.count {
                return treeItem(for: children[index])
            }
            return treeItem(for: nodeId)
        }

        func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
            guard let nodeId = nodeId(from: item),
                  let node = parent.store.node(nodeId) else {
                return false
            }
            return parent.store.isExpandable(node)
        }

        func outlineView(
            _ outlineView: NSOutlineView,
            viewFor tableColumn: NSTableColumn?,
            item: Any
        ) -> NSView? {
            guard let nodeId = nodeId(from: item),
                  let node = parent.store.node(nodeId) else {
                return nil
            }

            let identifier = NSUserInterfaceItemIdentifier("HierarchyCell")
            let cell: NSTableCellView
            if let reused = outlineView.makeView(withIdentifier: identifier, owner: nil) as? NSTableCellView {
                cell = reused
            } else {
                cell = NSTableCellView(frame: .zero)
                cell.identifier = identifier

                let iconView = NSImageView(frame: NSRect(x: 2, y: 1, width: 16, height: 16))
                iconView.imageScaling = .scaleProportionallyDown
                iconView.translatesAutoresizingMaskIntoConstraints = false

                let label = NSTextField(labelWithString: "")
                label.translatesAutoresizingMaskIntoConstraints = false
                label.lineBreakMode = .byTruncatingTail

                cell.addSubview(iconView)
                cell.addSubview(label)
                cell.imageView = iconView
                cell.textField = label

                NSLayoutConstraint.activate([
                    iconView.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
                    iconView.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                    iconView.widthAnchor.constraint(equalToConstant: 16),
                    iconView.heightAnchor.constraint(equalToConstant: 16),

                    label.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 6),
                    label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -6),
                    label.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
                ])
            }

            let badge = parent.store.nodeBadge(node)
            var label = parent.store.nodeLabel(node)
            if !badge.isEmpty {
                label += " [\(badge)]"
            }

            cell.textField?.stringValue = label
            cell.textField?.textColor = .labelColor
            cell.imageView?.image = icon(for: node)
            return cell
        }

        func outlineViewSelectionDidChange(_ notification: Notification) {
            guard let outlineView = notification.object as? NSOutlineView else {
                return
            }
            let row = outlineView.selectedRow
            guard row >= 0,
                  let item = outlineView.item(atRow: row),
                  let nodeId = nodeId(from: item) else {
                return
            }
            parent.onSelect(nodeId)
        }

        @objc
        func handleDoubleClick(_ sender: Any?) {
            guard let outlineView = sender as? NSOutlineView else {
                return
            }
            let row = outlineView.clickedRow >= 0 ? outlineView.clickedRow : outlineView.selectedRow
            guard row >= 0,
                  let item = outlineView.item(atRow: row),
                  let nodeId = nodeId(from: item),
                  let node = parent.store.node(nodeId) else {
                return
            }

            if node.kind == .directory && node.childrenState != .collapsedByThreshold {
                parent.onZoom(nodeId)
            }
        }

        func outlineViewItemDidExpand(_ notification: Notification) {
            guard let item = notification.userInfo?["NSObject"] else {
                return
            }
            guard let nodeId = nodeId(from: item) else {
                return
            }
            parent.onExpandedChanged(nodeId, true)
        }

        func outlineViewItemDidCollapse(_ notification: Notification) {
            guard let item = notification.userInfo?["NSObject"] else {
                return
            }
            guard let nodeId = nodeId(from: item) else {
                return
            }
            parent.onExpandedChanged(nodeId, false)
        }

        private func icon(for node: NativeNode) -> NSImage {
            let key: String
            switch node.kind {
            case .directory:
                key = "folder.fill"
            case .collapsedDirectory:
                key = "folder.badge.questionmark"
            case .file:
                key = "doc.fill"
            }

            if let cached = iconCache[key] {
                return cached
            }

            let image = NSImage(systemSymbolName: key, accessibilityDescription: nil) ?? NSImage()
            image.isTemplate = true
            iconCache[key] = image
            return image
        }
    }
}

private final class HierarchyOutlineContainerView: NSView {
    private let scrollView = NSScrollView()
    private let outlineView = NSOutlineView()
    private let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("HierarchyColumn"))

    private weak var coordinator: HierarchyOutlineView.Coordinator?
    private weak var store: NativeScanStore?
    private var rootId: UInt64 = 0
    private var selectedId: UInt64 = 0
    private var version: UInt64 = 0
    private var configured = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupViews()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupViews()
    }

    func attachCoordinator(_ coordinator: HierarchyOutlineView.Coordinator) {
        guard self.coordinator !== coordinator else {
            return
        }
        self.coordinator = coordinator
        configureOutlineIfNeeded()
    }

    func apply(store: NativeScanStore, rootId: UInt64, selectedId: UInt64, version: UInt64) {
        self.store = store
        let rootChanged = self.rootId != rootId
        let versionChanged = self.version != version
        self.rootId = rootId
        self.selectedId = selectedId
        self.version = version

        guard let coordinator else {
            return
        }

        if rootChanged {
            coordinator.resetAllCaches()
        }

        if rootChanged || versionChanged {
            outlineView.reloadData()
            applyExpandedState(coordinator: coordinator)
        }

        syncSelection(coordinator: coordinator)
    }

    private func setupViews() {
        wantsLayer = false

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.borderType = .noBorder
        scrollView.backgroundColor = .controlBackgroundColor
        scrollView.drawsBackground = true

        outlineView.headerView = nil
        outlineView.style = .sourceList
        outlineView.rowSizeStyle = .default
        outlineView.floatsGroupRows = false
        outlineView.focusRingType = .default
        outlineView.usesAlternatingRowBackgroundColors = false
        outlineView.allowsTypeSelect = true
        outlineView.allowsMultipleSelection = false
        outlineView.rowHeight = 22
        outlineView.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle

        column.title = "Hierarchy"
        column.resizingMask = .autoresizingMask
        outlineView.addTableColumn(column)
        outlineView.outlineTableColumn = column

        scrollView.documentView = outlineView
        addSubview(scrollView)

        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    private func configureOutlineIfNeeded() {
        guard let coordinator else {
            return
        }
        outlineView.dataSource = coordinator
        outlineView.delegate = coordinator
        outlineView.target = coordinator
        outlineView.doubleAction = #selector(HierarchyOutlineView.Coordinator.handleDoubleClick(_:))
        configured = true
    }

    private func applyExpandedState(coordinator: HierarchyOutlineView.Coordinator) {
        guard configured, store?.node(rootId) != nil else {
            return
        }

        let rootItem = coordinator.treeItem(for: rootId)
        outlineView.expandItem(rootItem)
        expandChildrenRecursively(of: rootId, coordinator: coordinator)
    }

    private func expandChildrenRecursively(
        of nodeId: UInt64,
        coordinator: HierarchyOutlineView.Coordinator
    ) {
        guard let store else {
            return
        }

        for childId in coordinator.children(of: nodeId, version: version) {
            guard store.expandedNodes.contains(childId),
                  let childNode = store.node(childId),
                  childNode.kind == .directory,
                  childNode.childrenState != .collapsedByThreshold,
                  !childNode.children.isEmpty else {
                continue
            }

            let childItem = coordinator.treeItem(for: childId)
            outlineView.expandItem(childItem)
            expandChildrenRecursively(of: childId, coordinator: coordinator)
        }
    }

    private func syncSelection(coordinator: HierarchyOutlineView.Coordinator) {
        guard configured, store != nil else {
            return
        }

        revealAncestors(for: selectedId, coordinator: coordinator)
        let item = coordinator.treeItem(for: selectedId)
        let row = outlineView.row(forItem: item)
        guard row >= 0 else {
            return
        }

        if outlineView.selectedRow != row {
            outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        }
        outlineView.scrollRowToVisible(row)
    }

    private func revealAncestors(
        for nodeId: UInt64,
        coordinator: HierarchyOutlineView.Coordinator
    ) {
        guard let store else {
            return
        }

        var ancestors: [UInt64] = []
        var cursor = store.node(nodeId)?.parentId
        while let id = cursor {
            ancestors.append(id)
            if id == rootId {
                break
            }
            cursor = store.node(id)?.parentId
        }

        for ancestorId in ancestors.reversed() {
            outlineView.expandItem(coordinator.treeItem(for: ancestorId))
        }
    }
}
