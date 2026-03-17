import AppKit
import SwiftUI

struct ContentView: View {
    @EnvironmentObject var store: NativeScanStore
    @Environment(\.openWindow) private var openWindow
    @State private var showingAdvancedSheet = false

    var body: some View {
        Group {
            switch store.currentScreen {
            case .setup:
                setupScreen
            case .results:
                resultsScreen
            }
        }
        .padding(store.currentScreen == .setup ? 10 : 12)
        .alert(item: $store.upgradePrompt) { prompt in
            if prompt.openAppStore {
                return Alert(
                    title: Text(prompt.title),
                    message: Text(prompt.message),
                    primaryButton: .default(Text("Open App Store")) {
                        store.openUpgradeTarget()
                    },
                    secondaryButton: .cancel {
                        store.dismissUpgradePrompt()
                    }
                )
            }
            return Alert(
                title: Text(prompt.title),
                message: Text(prompt.message),
                dismissButton: .default(Text("OK")) {
                    store.dismissUpgradePrompt()
                }
            )
        }
    }

    private var setupScreen: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("What to Scan")
                    .font(.headline)
                Spacer()
                if store.buyFullVersionVisible {
                    Button(store.buyFullVersionLabel) {
                        store.buyFullVersion()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }
                if store.canShowResultsScreen {
                    Button("Show Results") {
                        store.showResultsScreenIfAvailable()
                    }
                }
            }

            GroupBox("Mounted Drives") {
                ScrollView {
                    LazyVStack(spacing: 4) {
                        ForEach(store.availableDrives) { drive in
                            driveRow(for: drive)
                        }
                    }
                    .padding(6)
                }
                .frame(height: setupDriveListHeight)
            }

            HStack(spacing: 10) {
                Button("Select Folder…") {
                    store.selectFolderFromDialog()
                }
                Spacer()
            }

            setupTargetSummary

            HStack(spacing: 10) {
                Text("Profile")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Picker("Profile", selection: $store.profile) {
                    ForEach(NativeProfile.allCases) { profile in
                        Text(profile.title).tag(profile)
                    }
                }
                .pickerStyle(.menu)
                .frame(width: 170)

                Button("Advanced…") {
                    showingAdvancedSheet = true
                }
                .buttonStyle(.bordered)

                Spacer()

                Button("Start Scan") {
                    store.startScan()
                }
                .disabled(!store.canStartScan)
                .keyboardShortcut(.return, modifiers: [])
            }

            if store.proAvailable {
                GroupBox("Pro Monitoring") {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Toggle("Background daemon", isOn: $store.proMonitorEnabled)
                                .disabled(!store.canUseProMonitor)
                            Spacer()
                            Text(store.purchaseState.label)
                                .font(.caption)
                                .foregroundStyle(store.proEnabled ? .green : .secondary)
                        }
                        Text("Uses FSEvents with scheduled reconcile scans for long offline periods.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.top, 2)
                }
            }
        }
        .sheet(isPresented: $showingAdvancedSheet) {
            SetupAdvancedSheetView()
                .environmentObject(store)
                .frame(minWidth: 420, minHeight: 220)
        }
    }

    private func driveRow(for drive: NativeDriveInfo) -> some View {
        let selected = !store.useCustomPath && store.selectedDrive == drive.path
        let usedSummary = store.driveUsedLabel(for: drive)
        let totalSummary = store.driveTotalLabel(for: drive)

        return Button {
            store.setDriveTarget(path: drive.path)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(selected ? Color.accentColor : Color.secondary)

                VStack(alignment: .leading, spacing: 1) {
                    Label(drive.displayName, systemImage: "internaldrive")
                        .font(.body)
                        .lineLimit(1)
                    Text(drive.path)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 1) {
                    Text("\(usedSummary)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text("/ \(totalSummary)")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.vertical, 4)
            .padding(.horizontal, 8)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(selected ? Color.accentColor.opacity(0.16) : Color.clear)
            )
        }
        .buttonStyle(.plain)
    }

    private var setupDriveListHeight: CGFloat {
        let visibleRows = max(2, min(store.availableDrives.count, 4))
        return CGFloat(visibleRows) * 48 + 12
    }

    private var setupTargetSummary: some View {
        HStack(spacing: 8) {
            Text("Target:")
                .font(.caption)
                .foregroundStyle(.secondary)

            if store.useCustomPath {
                Label(store.customPath, systemImage: "folder")
                    .font(.caption)
                    .lineLimit(1)
            } else if let drive = store.selectedDriveInfo {
                Label("\(drive.displayName) (\(drive.path))", systemImage: "internaldrive")
                    .font(.caption)
                    .lineLimit(1)
            } else {
                Text(store.activePath)
                    .font(.caption)
                    .lineLimit(1)
            }

            Spacer()
        }
    }

    private var resultsScreen: some View {
        VStack(spacing: 10) {
            resultsActions
            progressBar

            HSplitView {
                hierarchyPane
                    .frame(minWidth: 320, idealWidth: 380, maxWidth: 480)
                treemapPane
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var resultsActions: some View {
        HStack(spacing: 10) {
            Label(store.activePath, systemImage: store.useCustomPath ? "folder" : "internaldrive")
                .font(.subheadline)
                .lineLimit(1)

            Spacer()

            if store.buyFullVersionVisible {
                Button(store.buyFullVersionLabel) {
                    store.buyFullVersion()
                }
                .buttonStyle(.borderedProminent)
            }

            Button("Change Target") {
                store.changeTarget()
            }
            .disabled(store.scanState == .running)

            Button("Cancel") {
                store.cancelScan()
            }
            .disabled(!store.canCancelScan)

            Button("Rescan") {
                store.rescan()
            }
            .disabled(!store.canRescan)

            Button {
                openWindow(id: "scan-errors")
            } label: {
                Image(systemName: "exclamationmark.bubble")
            }
            .help("Show scan errors")
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
    }

    private var progressBar: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Text("State: \(store.scanState.label)")
                    .font(.headline)

                ProgressView(value: store.progressFraction)
                    .frame(maxWidth: .infinity)

                Text("\(store.scannedBytesLabel) / \(store.occupiedBytesLabel)")
                    .font(.system(.body, design: .rounded))
            }

            HStack(spacing: 14) {
                Text("Scanned: \(store.scannedBytesLabel)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("Occupied: \(store.occupiedBytesLabel)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("Capacity: \(store.totalBytesLabel)")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Button {
                    openWindow(id: "scan-errors")
                } label: {
                    Text("Errors: \(store.totalErrorCount)")
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundStyle(store.totalErrorCount > 0 ? .red : .secondary)
                }
                .buttonStyle(.plain)

                if store.deferredNodeCount > 0 {
                    Text("Deferred: \(store.deferredNodeCount)")
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundStyle(.orange)
                }

                Spacer()
            }
        }
        .overlay(alignment: .leading) {
            Text(store.statusLine)
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.top, 48)
        }
        .padding(.bottom, 16)
    }

    private var hierarchyPane: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Hierarchy")
                    .font(.headline)
                Spacer()
                if store.zoomNodeId != store.rootNodeId {
                    HStack(spacing: 6) {
                        Button {
                            store.zoomToParent()
                        } label: {
                            Image(systemName: "arrow.up.to.line")
                        }
                        .help("Go up one level")

                        Button {
                            store.resetZoom()
                        } label: {
                            Image(systemName: "house")
                        }
                        .help("Return to scan root")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
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

private struct SetupAdvancedSheetView: View {
    @EnvironmentObject var store: NativeScanStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Advanced Tuning")
                .font(.headline)

            Form {
                LabeledContent("Workers override") {
                    TextField("Auto", text: $store.workerOverrideText)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 170)
                }
                LabeledContent("Queue limit") {
                    TextField("64", text: $store.queueLimitText)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 170)
                }
                LabeledContent("Threshold bytes") {
                    TextField("Auto", text: $store.thresholdOverrideText)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 170)
                }
            }
            .formStyle(.grouped)

            HStack {
                Button("Reset Defaults") {
                    store.workerOverrideText = ""
                    store.queueLimitText = "64"
                    store.thresholdOverrideText = ""
                }
                Spacer()
                Button("Done") {
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(14)
    }
}

struct ScanErrorsView: View {
    @EnvironmentObject var store: NativeScanStore

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Scan Errors")
                    .font(.headline)
                Spacer()
                Text("\(store.totalErrorCount) total")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if store.totalErrorCount == 0 {
                VStack(spacing: 8) {
                    Image(systemName: "checkmark.circle")
                        .font(.system(size: 30))
                        .foregroundStyle(.secondary)
                    Text("No Errors")
                        .font(.headline)
                    Text("No scan errors have been reported for the current scan.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(store.errorEntries()) { entry in
                    HStack(alignment: .top, spacing: 10) {
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 6) {
                                Text(entry.kindLabel)
                                    .font(.caption2)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(
                                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                                            .fill(entry.kindLabel == "Runtime" ? Color.orange.opacity(0.18) : Color.red.opacity(0.18))
                                    )
                                Text(entry.location)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            Text(entry.detail)
                                .font(.body)
                                .lineLimit(2)
                        }
                        Spacer()
                        if let nodeId = entry.nodeId {
                            Button("Reveal") {
                                store.focusOnErrorNode(nodeId)
                                focusMainWindow()
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                    }
                    .padding(.vertical, 2)
                }
                .listStyle(.inset)
            }
        }
        .padding(12)
    }

    private func focusMainWindow() {
        if let mainWindow = NSApp.windows.first(where: { $0.title == "Diskscope Native" }) {
            mainWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
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
        private struct ChildCacheEntry {
            let revision: UInt64
            let count: Int
            let children: [UInt64]
        }

        var parent: HierarchyOutlineView
        private var childrenCache: [UInt64: ChildCacheEntry] = [:]
        private var iconCache: [String: NSImage] = [:]

        init(parent: HierarchyOutlineView) {
            self.parent = parent
        }

        func resetAllCaches() {
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

        func children(of nodeId: UInt64) -> [UInt64] {
            guard let node = parent.store.node(nodeId) else {
                childrenCache[nodeId] = ChildCacheEntry(revision: 0, count: 0, children: [])
                return []
            }

            let revision = parent.store.childOrderRevision(of: nodeId)
            if let cached = childrenCache[nodeId],
               cached.revision == revision,
               cached.count == node.children.count {
                return cached.children
            }

            let sorted = parent.store.sortedChildren(of: nodeId)
            childrenCache[nodeId] = ChildCacheEntry(
                revision: revision,
                count: node.children.count,
                children: sorted
            )
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
            return children(of: nodeId).count
        }

        func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
            if item == nil {
                return treeItem(for: parent.rootId)
            }
            guard let nodeId = nodeId(from: item) else {
                return treeItem(for: parent.rootId)
            }
            let children = children(of: nodeId)
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

            if tableColumn?.identifier.rawValue == "HierarchySizeColumn" {
                return sizeCell(outlineView: outlineView, node: node)
            }
            return nameCell(outlineView: outlineView, node: node)
        }

        private func nameCell(outlineView: NSOutlineView, node: NativeNode) -> NSTableCellView {
            let identifier = NSUserInterfaceItemIdentifier("HierarchyNameCell")
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
                label.font = NSFont.systemFont(ofSize: 15)

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

            cell.textField?.stringValue = parent.store.nodeLabel(node)
            cell.textField?.textColor = .labelColor
            cell.imageView?.image = icon(for: node)
            return cell
        }

        private func sizeCell(outlineView: NSOutlineView, node: NativeNode) -> NSTableCellView {
            let identifier = NSUserInterfaceItemIdentifier("HierarchySizeCell")
            let cell: NSTableCellView
            let label: NSTextField
            let deferredIconView: NSImageView
            let errorIconView: NSImageView
            if let reused = outlineView.makeView(withIdentifier: identifier, owner: nil) as? NSTableCellView {
                cell = reused
                label = reused.textField ?? NSTextField(labelWithString: "")
                deferredIconView = (reused.viewWithTag(1001) as? NSImageView) ?? NSImageView()
                errorIconView = (reused.viewWithTag(1002) as? NSImageView) ?? NSImageView()
            } else {
                cell = NSTableCellView(frame: .zero)
                cell.identifier = identifier

                let label = NSTextField(labelWithString: "")
                label.translatesAutoresizingMaskIntoConstraints = false
                label.alignment = .right
                label.lineBreakMode = .byTruncatingHead
                label.font = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .regular)
                label.textColor = .secondaryLabelColor

                let deferredIconView = NSImageView(frame: .zero)
                deferredIconView.translatesAutoresizingMaskIntoConstraints = false
                deferredIconView.imageScaling = .scaleProportionallyDown
                deferredIconView.contentTintColor = .systemOrange
                deferredIconView.tag = 1001
                deferredIconView.isHidden = true
                deferredIconView.image = statusIcon(key: "status.deferred", symbol: "clock.fill")

                let errorIconView = NSImageView(frame: .zero)
                errorIconView.translatesAutoresizingMaskIntoConstraints = false
                errorIconView.imageScaling = .scaleProportionallyDown
                errorIconView.contentTintColor = .systemRed
                errorIconView.tag = 1002
                errorIconView.isHidden = true
                errorIconView.image = statusIcon(key: "status.error", symbol: "exclamationmark.triangle.fill")

                let stack = NSStackView(views: [label, deferredIconView, errorIconView])
                stack.translatesAutoresizingMaskIntoConstraints = false
                stack.orientation = .horizontal
                stack.alignment = .centerY
                stack.spacing = 4
                stack.distribution = .fill

                label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
                deferredIconView.setContentCompressionResistancePriority(.required, for: .horizontal)
                errorIconView.setContentCompressionResistancePriority(.required, for: .horizontal)

                cell.addSubview(stack)
                cell.textField = label

                NSLayoutConstraint.activate([
                    stack.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
                    stack.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -8),
                    stack.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                    deferredIconView.widthAnchor.constraint(equalToConstant: 12),
                    deferredIconView.heightAnchor.constraint(equalToConstant: 12),
                    errorIconView.widthAnchor.constraint(equalToConstant: 12),
                    errorIconView.heightAnchor.constraint(equalToConstant: 12)
                ])

                label.stringValue = parent.store.nodeSizeLabel(node)
                configureSizeStatusIcons(
                    node: node,
                    deferredIconView: deferredIconView,
                    errorIconView: errorIconView
                )
                return cell
            }

            label.stringValue = parent.store.nodeSizeLabel(node)
            label.textColor = .secondaryLabelColor
            configureSizeStatusIcons(
                node: node,
                deferredIconView: deferredIconView,
                errorIconView: errorIconView
            )
            return cell
        }

        private func configureSizeStatusIcons(
            node: NativeNode,
            deferredIconView: NSImageView,
            errorIconView: NSImageView
        ) {
            let showsDeferred = node.childrenState == .collapsedByThreshold
            deferredIconView.isHidden = !showsDeferred
            deferredIconView.toolTip = showsDeferred
                ? "Deferred: details were collapsed by threshold."
                : nil

            let showsError = node.errorFlag
            errorIconView.isHidden = !showsError
            errorIconView.toolTip = showsError
                ? "Error: this path could not be fully read."
                : nil
        }

        private func statusIcon(key: String, symbol: String) -> NSImage {
            if let cached = iconCache[key] {
                return cached
            }

            let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) ?? NSImage()
            image.isTemplate = true
            iconCache[key] = image
            return image
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
            guard parent.selectedId != nodeId else {
                return
            }
            DispatchQueue.main.async { [parent] in
                parent.onSelect(nodeId)
            }
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
            if parent.store.expandedNodes.contains(nodeId) {
                return
            }
            DispatchQueue.main.async { [parent] in
                parent.onExpandedChanged(nodeId, true)
            }
        }

        func outlineViewItemDidCollapse(_ notification: Notification) {
            guard let item = notification.userInfo?["NSObject"] else {
                return
            }
            guard let nodeId = nodeId(from: item) else {
                return
            }
            if !parent.store.expandedNodes.contains(nodeId) {
                return
            }
            DispatchQueue.main.async { [parent] in
                parent.onExpandedChanged(nodeId, false)
            }
        }

        private func icon(for node: NativeNode) -> NSImage {
            let key: String
            switch node.kind {
            case .directory:
                key = "folder.fill"
            case .collapsedDirectory:
                key = "folder.fill"
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
    private let reloadMinIntervalSeconds: CFAbsoluteTime = 0.2
    private let fullReloadRowLimit = 2_000
    private let minSizeColumnWidth: CGFloat = 108
    private let maxSizeColumnWidth: CGFloat = 260
    private let sizeColumnPadding: CGFloat = 16
    private let sizeToStatusGap: CGFloat = 6
    private let statusIconWidth: CGFloat = 12
    private let statusIconSpacing: CGFloat = 4
    private let sizeValueFont = NSFont.monospacedDigitSystemFont(ofSize: 12.5, weight: .regular)

    private let scrollView = NSScrollView()
    private let outlineView = NSOutlineView()
    private let nameColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("HierarchyNameColumn"))
    private let sizeColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("HierarchySizeColumn"))

    private weak var coordinator: HierarchyOutlineView.Coordinator?
    private weak var store: NativeScanStore?
    private var rootId: UInt64 = 0
    private var selectedId: UInt64 = 0
    private var version: UInt64 = 0
    private var configured = false
    private var lastReloadAt: CFAbsoluteTime = 0
    private var reloadScheduled = false
    private var reloadGeneration: UInt64 = 0
    private var lastSyncedSelectionId: UInt64 = UInt64.max
    private var lastSyncedRootId: UInt64 = UInt64.max

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
        let selectionChanged = self.selectedId != selectedId
        let versionChanged = self.version != version
        self.rootId = rootId
        self.selectedId = selectedId
        self.version = version

        guard let coordinator else {
            return
        }

        if rootChanged {
            reloadGeneration &+= 1
            reloadScheduled = false
            lastSyncedSelectionId = UInt64.max
            lastSyncedRootId = UInt64.max
            coordinator.resetAllCaches()
            NativeDiagnostics.debug("outline_root_changed root=\(rootId)")
            outlineView.reloadData()
            applyExpandedState(coordinator: coordinator)
            fitSizeColumnToContent(coordinator: coordinator)
            syncSelection(coordinator: coordinator, forceRevealAncestors: true)
            return
        }

        if versionChanged {
            scheduleVersionRefresh(coordinator: coordinator)
        }

        if selectionChanged {
            syncSelection(coordinator: coordinator, forceRevealAncestors: true)
        }
    }

    private func setupViews() {
        wantsLayer = false

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.borderType = .noBorder
        scrollView.backgroundColor = .controlBackgroundColor
        scrollView.drawsBackground = true

        outlineView.headerView = NSTableHeaderView()
        outlineView.style = .sourceList
        outlineView.rowSizeStyle = .default
        outlineView.floatsGroupRows = false
        outlineView.focusRingType = .default
        outlineView.usesAlternatingRowBackgroundColors = false
        outlineView.allowsTypeSelect = true
        outlineView.allowsMultipleSelection = false
        outlineView.allowsColumnReordering = false
        outlineView.allowsColumnResizing = false
        outlineView.rowHeight = 22
        outlineView.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle

        nameColumn.title = "Name"
        nameColumn.minWidth = 180
        nameColumn.width = 290
        nameColumn.resizingMask = .autoresizingMask

        sizeColumn.title = "Size"
        sizeColumn.minWidth = minSizeColumnWidth
        sizeColumn.maxWidth = maxSizeColumnWidth
        sizeColumn.width = 160
        sizeColumn.resizingMask = []

        outlineView.addTableColumn(nameColumn)
        outlineView.addTableColumn(sizeColumn)
        outlineView.outlineTableColumn = nameColumn

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
        fitSizeColumnToContent(coordinator: coordinator)
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

        for childId in coordinator.children(of: nodeId) {
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

    private func scheduleVersionRefresh(coordinator: HierarchyOutlineView.Coordinator) {
        let now = CFAbsoluteTimeGetCurrent()
        let elapsed = now - lastReloadAt
        if elapsed >= reloadMinIntervalSeconds {
            performVersionRefresh(coordinator: coordinator)
            return
        }

        guard !reloadScheduled else {
            return
        }
        reloadScheduled = true
        let generation = reloadGeneration
        let delay = reloadMinIntervalSeconds - elapsed
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0, delay)) { [weak self, weak coordinator] in
            guard let self else {
                return
            }
            self.reloadScheduled = false
            guard self.reloadGeneration == generation,
                  let coordinator else {
                return
            }
            self.performVersionRefresh(coordinator: coordinator)
        }
    }

    private func performVersionRefresh(coordinator: HierarchyOutlineView.Coordinator) {
        guard configured, store?.node(rootId) != nil else {
            return
        }

        let refreshStartedAt = CFAbsoluteTimeGetCurrent()
        let didFullReload = outlineView.numberOfRows <= fullReloadRowLimit
        if didFullReload {
            outlineView.reloadData()
            applyExpandedState(coordinator: coordinator)
        } else {
            refreshVisibleRows()
        }
        fitSizeColumnToContent(coordinator: coordinator)
        lastReloadAt = CFAbsoluteTimeGetCurrent()

        if didFullReload || !isSelectionSynchronized(coordinator: coordinator) {
            syncSelection(coordinator: coordinator)
        }

        let refreshMode = didFullReload ? "full" : "visible"
        let details = "mode=\(refreshMode) rows=\(outlineView.numberOfRows) selected=\(selectedId)"
        NativeDiagnostics.slowPath(
            "outline_refresh",
            startedAt: refreshStartedAt,
            thresholdMs: 16,
            details: details
        )
    }

    private func refreshVisibleRows() {
        let rows = outlineView.rows(in: outlineView.visibleRect)
        guard rows.length > 0 else {
            return
        }

        let start = max(rows.location, 0)
        let end = min(outlineView.numberOfRows, start + rows.length)
        guard start < end else {
            return
        }

        let columnCount = max(1, outlineView.numberOfColumns)
        let rowIndexes = IndexSet(integersIn: start..<end)
        let columnIndexes = IndexSet(integersIn: 0..<columnCount)
        outlineView.reloadData(forRowIndexes: rowIndexes, columnIndexes: columnIndexes)
    }

    private func isSelectionSynchronized(coordinator: HierarchyOutlineView.Coordinator) -> Bool {
        let expected = coordinator.treeItem(for: selectedId)
        let row = outlineView.selectedRow
        guard row >= 0,
              let item = outlineView.item(atRow: row),
              let selectedItemId = coordinator.nodeId(from: item) else {
            return false
        }
        guard let expectedId = coordinator.nodeId(from: expected) else {
            return false
        }
        return selectedItemId == expectedId
    }

    private func syncSelection(
        coordinator: HierarchyOutlineView.Coordinator,
        forceRevealAncestors: Bool = false
    ) {
        guard configured, store != nil else {
            return
        }

        let startedAt = CFAbsoluteTimeGetCurrent()
        if forceRevealAncestors || selectedId != lastSyncedSelectionId || rootId != lastSyncedRootId {
            revealAncestors(for: selectedId, coordinator: coordinator)
        }
        let item = coordinator.treeItem(for: selectedId)
        let row = outlineView.row(forItem: item)
        guard row >= 0 else {
            return
        }

        if outlineView.selectedRow != row {
            outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        }

        if !isRowVisible(row) {
            outlineView.scrollRowToVisible(row)
        }
        lastSyncedSelectionId = selectedId
        lastSyncedRootId = rootId

        let details = "selected=\(selectedId) row=\(row) force=\(forceRevealAncestors)"
        NativeDiagnostics.slowPath(
            "outline_selection_sync",
            startedAt: startedAt,
            thresholdMs: 10,
            details: details
        )
    }

    private func isRowVisible(_ row: Int) -> Bool {
        let visibleRows = outlineView.rows(in: outlineView.visibleRect)
        guard visibleRows.length > 0 else {
            return false
        }
        let start = visibleRows.location
        let end = start + visibleRows.length
        return row >= start && row < end
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
            let ancestorItem = coordinator.treeItem(for: ancestorId)
            if !outlineView.isItemExpanded(ancestorItem) {
                outlineView.expandItem(ancestorItem)
            }
        }
    }

    private func fitSizeColumnToContent(coordinator: HierarchyOutlineView.Coordinator) {
        let target = desiredSizeColumnWidth(coordinator: coordinator)
        guard abs(sizeColumn.width - target) > 0.5
                || abs(sizeColumn.minWidth - target) > 0.5
                || abs(sizeColumn.maxWidth - target) > 0.5 else {
            return
        }

        sizeColumn.width = target
        sizeColumn.minWidth = target
        sizeColumn.maxWidth = target
    }

    private func desiredSizeColumnWidth(coordinator: HierarchyOutlineView.Coordinator) -> CGFloat {
        guard let store else {
            return 160
        }

        let totalRows = outlineView.numberOfRows
        if totalRows <= 0 {
            return 160
        }

        let rowsToMeasure: Range<Int>
        if totalRows <= fullReloadRowLimit {
            rowsToMeasure = 0..<totalRows
        } else {
            let visible = outlineView.rows(in: outlineView.visibleRect)
            let start = max(visible.location, 0)
            let end = min(totalRows, start + visible.length)
            if start < end {
                rowsToMeasure = start..<end
            } else {
                rowsToMeasure = 0..<min(totalRows, 200)
            }
        }

        var widest: CGFloat = 0
        for row in rowsToMeasure {
            guard let item = outlineView.item(atRow: row),
                  let nodeId = coordinator.nodeId(from: item),
                  let node = store.node(nodeId) else {
                continue
            }

            let sizeText = store.nodeSizeLabel(node)
            var width = (sizeText as NSString).size(withAttributes: [.font: sizeValueFont]).width
            let hasDeferred = node.childrenState == .collapsedByThreshold
            let hasError = node.errorFlag
            if hasDeferred || hasError {
                width += sizeToStatusGap
                if hasDeferred {
                    width += statusIconWidth
                }
                if hasDeferred && hasError {
                    width += statusIconSpacing
                }
                if hasError {
                    width += statusIconWidth
                }
            }

            if width > widest {
                widest = width
            }
        }

        if widest == 0 {
            widest = ("999.99 GiB" as NSString).size(withAttributes: [.font: sizeValueFont]).width
                + sizeToStatusGap
                + statusIconWidth
        }

        let padded = widest + sizeColumnPadding
        let clamped = min(max(padded, minSizeColumnWidth), maxSizeColumnWidth)
        return ceil(clamped)
    }
}
