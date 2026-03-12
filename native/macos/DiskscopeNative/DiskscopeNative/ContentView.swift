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

            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    NodeTreeRow(nodeId: store.zoomNodeId, depth: 0)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
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

private struct NodeTreeRow: View {
    @EnvironmentObject var store: NativeScanStore

    let nodeId: UInt64
    let depth: Int

    var body: some View {
        guard let node = store.node(nodeId) else {
            return AnyView(EmptyView())
        }

        let expandable = store.isExpandable(node)
        let expanded = store.expandedNodes.contains(nodeId)
        let badge = store.nodeBadge(node)
        let children = expanded ? store.sortedChildren(of: nodeId) : []

        return AnyView(
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Color.clear.frame(width: CGFloat(depth) * 14, height: 1)

                    if expandable {
                        Button(action: {
                            store.toggleExpanded(nodeId: nodeId)
                        }) {
                            Image(systemName: expanded ? "chevron.down" : "chevron.right")
                                .font(.caption)
                                .frame(width: 12)
                        }
                        .buttonStyle(.plain)
                    } else {
                        Color.clear.frame(width: 12, height: 12)
                    }

                    Text(store.nodeLabel(node))
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    if !badge.isEmpty {
                        Text("[\(badge)]")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 2)
                .padding(.horizontal, 4)
                .background(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(nodeId == store.selectedNodeId
                              ? Color.accentColor.opacity(0.22)
                              : Color.clear)
                )
                .contentShape(Rectangle())
                .onTapGesture {
                    store.select(nodeId: nodeId)
                }
                .simultaneousGesture(TapGesture(count: 2).onEnded {
                    store.zoom(to: nodeId)
                })

                if expandable && expanded {
                    ForEach(children, id: \.self) { childId in
                        NodeTreeRow(nodeId: childId, depth: depth + 1)
                    }
                }
            }
        )
    }
}
