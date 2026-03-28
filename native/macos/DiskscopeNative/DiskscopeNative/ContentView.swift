import AppKit
import SwiftUI

struct ContentView: View {
    @EnvironmentObject var store: NativeScanStore
    @Environment(\.openWindow) private var openWindow
    @Environment(\.colorScheme) private var colorScheme
    @State private var showingAdvancedSheet = false
    @State private var showingMonitoringSheet = false

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

            GroupBox("Target") {
                ScrollView {
                    LazyVStack(spacing: 4) {
                        ForEach(store.availableDrives) { drive in
                            driveRow(for: drive)
                        }
                        customFolderRow
                    }
                    .padding(6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: setupDriveListHeight)
            }

            HStack(spacing: 10) {
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
        }
        .sheet(isPresented: $showingAdvancedSheet) {
            SetupAdvancedSheetView()
                .environmentObject(store)
                .frame(minWidth: 420, minHeight: 220)
        }
        .sheet(isPresented: $showingMonitoringSheet) {
            MonitoringSheetView()
                .environmentObject(store)
                .frame(minWidth: 520, minHeight: 240)
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
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var customFolderRow: some View {
        let selected = store.useCustomPath
        let customPath = store.customPath.isEmpty ? "Not selected" : store.customPath

        return HStack(spacing: 8) {
            Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                .foregroundStyle(selected ? Color.accentColor : Color.secondary)

            VStack(alignment: .leading, spacing: 1) {
                Label("Custom Folder", systemImage: "folder")
                    .font(.body)
                    .lineLimit(1)
                Text(customPath)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer()

            Button("Select Folder…") {
                store.selectFolderFromDialog()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(!selected)
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 8)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(selected ? Color.accentColor.opacity(0.16) : Color.clear)
        )
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture {
            if selected {
                return
            }
            if store.customPath.isEmpty {
                store.setCustomTarget(path: store.activePath)
            } else {
                store.setCustomTarget(path: store.customPath)
            }
        }
    }

    private var setupDriveListHeight: CGFloat {
        let rowCount = store.availableDrives.count + 1
        let visibleRows = max(3, min(rowCount, 5))
        return CGFloat(visibleRows) * 48 + 12
    }

    private var resultsScreen: some View {
        VStack(spacing: 10) {
            resultsActions
            progressBar
            splitHeader

            InvisibleDividerResultsSplitView(
                leading: hierarchyPane,
                trailing: treemapPane,
                leadingMinWidth: 320,
                leadingIdealWidth: 380,
                leadingMaxWidth: 480,
                dividerHitWidth: 24
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var splitHeader: some View {
        HStack(spacing: 10) {
            Text(store.path(for: store.selectedNodeId))
                .font(.body)
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer()

            Button("Reset Zoom") {
                store.resetZoom()
            }
            .disabled(store.zoomNodeId == store.rootNodeId)
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
            if store.proEnabled {
                Button("Monitoring…") {
                    showingMonitoringSheet = true
                }
                .buttonStyle(.bordered)
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
        let segments = store.capacitySegments
        let darkMode = colorScheme == .dark

        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Text("State: \(store.scanState.label)")
                    .font(.headline)

                ScanCapacityBarView(
                    segments: segments,
                    isRunning: store.scanState == .running
                )
                    .frame(maxWidth: .infinity)
                    .frame(height: 22)

                Text(store.totalSegmentGbLabel)
                    .font(.system(.body, design: .rounded))
                    .fontWeight(.semibold)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .help("Total capacity")
            }

            HStack(spacing: 14) {
                ScanCapacityLegendItem(
                    title: "Scanned",
                    value: store.scannedSegmentGbLabel,
                    color: ScanCapacityPalette.scanned(darkMode: darkMode)
                )
                ScanCapacityLegendItem(
                    title: "Deferred",
                    value: store.deferredSegmentGbLabel,
                    color: ScanCapacityPalette.deferred(darkMode: darkMode)
                )
                ScanCapacityLegendItem(
                    title: "Pending",
                    value: store.remainingSegmentGbLabel,
                    color: ScanCapacityPalette.remaining(darkMode: darkMode)
                )
                ScanCapacityLegendItem(
                    title: "Empty",
                    value: store.emptySegmentGbLabel,
                    color: ScanCapacityPalette.empty(darkMode: darkMode)
                )

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
                    Text("Deferred nodes: \(store.deferredNodeCount)")
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundStyle(.orange)
                }

                Spacer()

                Text(store.statusLine)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.bottom, 16)
    }

    private var hierarchyPane: some View {
        VStack(alignment: .leading, spacing: 0) {
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
                },
                onContextAction: { nodeId, action in
                    handleNodeContextAction(nodeId: nodeId, action: action)
                }
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var treemapPane: some View {
        VStack(alignment: .leading, spacing: 0) {
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
                },
                onContextAction: { nodeId, action in
                    handleNodeContextAction(nodeId: nodeId, action: action)
                }
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func handleNodeContextAction(nodeId: UInt64, action: NativeNodeContextAction) {
        guard store.node(nodeId) != nil else {
            return
        }

        switch action {
        case .showInFinder:
            store.showNodeInFinder(nodeId: nodeId)
        case .revealParentInFinder:
            store.revealNodeParentInFinder(nodeId: nodeId)
        case .copyPath:
            store.copyNodePath(nodeId: nodeId)
        case .expandDeferred:
            store.enqueueDeferredExpansion(nodeId: nodeId)
        case .retryScan:
            store.retryNode(nodeId: nodeId)
        case .deleteToTrash:
            confirmDelete(nodeId: nodeId)
        }
    }

    private func confirmDelete(nodeId: UInt64) {
        guard store.canDeleteNode(nodeId: nodeId),
              let node = store.node(nodeId) else {
            NSSound.beep()
            return
        }

        let fullPath = store.path(for: nodeId)
        let itemName = node.name.isEmpty ? fullPath : node.name
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Move “\(itemName)” to Trash?"
        alert.informativeText = fullPath
        alert.addButton(withTitle: "Move to Trash")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            store.moveNodeToTrash(nodeId: nodeId)
        }
    }
}

private struct InvisibleDividerResultsSplitView<Leading: View, Trailing: View>: NSViewRepresentable {
    let leading: Leading
    let trailing: Trailing
    let leadingMinWidth: CGFloat
    let leadingIdealWidth: CGFloat
    let leadingMaxWidth: CGFloat
    let dividerHitWidth: CGFloat

    private let trailingMinWidth: CGFloat = 320

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> InvisibleDividerResultsSplitContainer {
        let view = InvisibleDividerResultsSplitContainer()
        view.splitView.delegate = context.coordinator
        context.coordinator.configure(
            leadingMinWidth: leadingMinWidth,
            leadingMaxWidth: leadingMaxWidth,
            trailingMinWidth: trailingMinWidth
        )
        view.updateContent(leading: AnyView(leading), trailing: AnyView(trailing))
        view.updateSizing(
            leadingMinWidth: leadingMinWidth,
            leadingIdealWidth: leadingIdealWidth,
            leadingMaxWidth: leadingMaxWidth,
            dividerHitWidth: dividerHitWidth
        )
        return view
    }

    func updateNSView(_ nsView: InvisibleDividerResultsSplitContainer, context: Context) {
        nsView.splitView.delegate = context.coordinator
        context.coordinator.configure(
            leadingMinWidth: leadingMinWidth,
            leadingMaxWidth: leadingMaxWidth,
            trailingMinWidth: trailingMinWidth
        )
        nsView.updateContent(leading: AnyView(leading), trailing: AnyView(trailing))
        nsView.updateSizing(
            leadingMinWidth: leadingMinWidth,
            leadingIdealWidth: leadingIdealWidth,
            leadingMaxWidth: leadingMaxWidth,
            dividerHitWidth: dividerHitWidth
        )
    }

    final class Coordinator: NSObject, NSSplitViewDelegate {
        private var leadingMinWidth: CGFloat = 320
        private var leadingMaxWidth: CGFloat = 480
        private var trailingMinWidth: CGFloat = 320

        func configure(leadingMinWidth: CGFloat, leadingMaxWidth: CGFloat, trailingMinWidth: CGFloat) {
            self.leadingMinWidth = leadingMinWidth
            self.leadingMaxWidth = leadingMaxWidth
            self.trailingMinWidth = trailingMinWidth
        }

        func splitView(
            _ splitView: NSSplitView,
            constrainMinCoordinate proposedMinimumPosition: CGFloat,
            ofSubviewAt dividerIndex: Int
        ) -> CGFloat {
            max(proposedMinimumPosition, leadingMinWidth)
        }

        func splitView(
            _ splitView: NSSplitView,
            constrainMaxCoordinate proposedMaximumPosition: CGFloat,
            ofSubviewAt dividerIndex: Int
        ) -> CGFloat {
            let maxByTrailing = splitView.bounds.width - splitView.dividerThickness - trailingMinWidth
            let hardMax = min(leadingMaxWidth, maxByTrailing)
            if hardMax <= leadingMinWidth {
                return leadingMinWidth
            }
            return min(proposedMaximumPosition, hardMax)
        }

        func splitView(_ splitView: NSSplitView, shouldHideDividerAt dividerIndex: Int) -> Bool {
            true
        }

        func splitView(
            _ splitView: NSSplitView,
            effectiveRect proposedEffectiveRect: NSRect,
            forDrawnRect drawnRect: NSRect,
            ofDividerAt dividerIndex: Int
        ) -> NSRect {
            let requestedHitWidth = (splitView as? InvisibleDividerSplitView)?.dragHitWidth ?? splitView.dividerThickness
            let hitWidth = max(requestedHitWidth, splitView.dividerThickness)
            if splitView.isVertical {
                return NSRect(
                    x: drawnRect.midX - hitWidth * 0.5,
                    y: splitView.bounds.minY,
                    width: hitWidth,
                    height: splitView.bounds.height
                )
            }
            return NSRect(
                x: splitView.bounds.minX,
                y: drawnRect.midY - hitWidth * 0.5,
                width: splitView.bounds.width,
                height: hitWidth
            )
        }
    }
}

private final class InvisibleDividerResultsSplitContainer: NSView {
    let splitView = InvisibleDividerSplitView()
    private let leadingHost = NSHostingView(rootView: AnyView(EmptyView()))
    private let trailingHost = NSHostingView(rootView: AnyView(EmptyView()))

    private var leadingMinWidth: CGFloat = 320
    private var leadingIdealWidth: CGFloat = 380
    private var leadingMaxWidth: CGFloat = 480
    private var didApplyInitialSplitPosition = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    func updateContent(leading: AnyView, trailing: AnyView) {
        leadingHost.rootView = leading
        trailingHost.rootView = trailing
    }

    func updateSizing(
        leadingMinWidth: CGFloat,
        leadingIdealWidth: CGFloat,
        leadingMaxWidth: CGFloat,
        dividerHitWidth: CGFloat
    ) {
        self.leadingMinWidth = leadingMinWidth
        self.leadingIdealWidth = leadingIdealWidth
        self.leadingMaxWidth = leadingMaxWidth
        splitView.dragHitWidth = dividerHitWidth
        applyInitialSplitPositionIfNeeded()
    }

    override func layout() {
        super.layout()
        applyInitialSplitPositionIfNeeded()
    }

    private func setup() {
        splitView.translatesAutoresizingMaskIntoConstraints = false
        splitView.isVertical = true
        splitView.dividerStyle = .thin
        splitView.adjustSubviews()
        addSubview(splitView)

        splitView.addArrangedSubview(leadingHost)
        splitView.addArrangedSubview(trailingHost)

        NSLayoutConstraint.activate([
            splitView.leadingAnchor.constraint(equalTo: leadingAnchor),
            splitView.trailingAnchor.constraint(equalTo: trailingAnchor),
            splitView.topAnchor.constraint(equalTo: topAnchor),
            splitView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    private func applyInitialSplitPositionIfNeeded() {
        guard !didApplyInitialSplitPosition, splitView.bounds.width > 0 else {
            return
        }
        let availableWidth = splitView.bounds.width - splitView.dividerThickness
        guard availableWidth > 0 else {
            return
        }
        let clamped = min(max(leadingIdealWidth, leadingMinWidth), min(leadingMaxWidth, availableWidth))
        splitView.setPosition(clamped, ofDividerAt: 0)
        didApplyInitialSplitPosition = true
    }
}

private final class InvisibleDividerSplitView: NSSplitView {
    var dragHitWidth: CGFloat = 24

    override var dividerThickness: CGFloat {
        1
    }

    override var dividerColor: NSColor {
        .clear
    }

    override func drawDivider(in dividerRect: NSRect) {
        // Keep divider invisible while preserving resize behavior.
    }

}

private enum ScanCapacityPalette {
    static func scanned(darkMode: Bool) -> Color {
        Color(nsColor: NativeThemeColorPalette.progressSegmentColor(.scanned, darkMode: darkMode))
    }

    static func deferred(darkMode: Bool) -> Color {
        Color(nsColor: NativeThemeColorPalette.progressSegmentColor(.deferred, darkMode: darkMode))
    }

    static func remaining(darkMode: Bool) -> Color {
        Color(nsColor: NativeThemeColorPalette.progressSegmentColor(.remaining, darkMode: darkMode))
    }

    static func empty(darkMode: Bool) -> Color {
        Color(nsColor: emptyBase(darkMode: darkMode))
    }

    static var trackGradient: LinearGradient {
        gradient(base: NSColor.controlBackgroundColor)
    }

    static func scannedGradient(darkMode: Bool) -> LinearGradient {
        gradient(base: NativeThemeColorPalette.progressSegmentColor(.scanned, darkMode: darkMode))
    }

    static func deferredGradient(darkMode: Bool) -> LinearGradient {
        gradient(base: NativeThemeColorPalette.progressSegmentColor(.deferred, darkMode: darkMode))
    }

    static func remainingGradient(darkMode: Bool) -> LinearGradient {
        gradient(base: NativeThemeColorPalette.progressSegmentColor(.remaining, darkMode: darkMode))
    }

    static func emptyGradient(darkMode: Bool) -> LinearGradient {
        gradient(base: emptyBase(darkMode: darkMode))
    }

    static var glossGradient: LinearGradient {
        LinearGradient(
            stops: [
                .init(color: Color.white.opacity(0.33), location: 0.0),
                .init(color: Color.white.opacity(0.12), location: 0.33),
                .init(color: Color.white.opacity(0.03), location: 0.58),
                .init(color: Color.clear, location: 1.0)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    static var lowerShadeGradient: LinearGradient {
        LinearGradient(
            stops: [
                .init(color: Color.clear, location: 0.0),
                .init(color: Color.black.opacity(0.08), location: 0.62),
                .init(color: Color.black.opacity(0.2), location: 1.0)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    static var rimGradient: LinearGradient {
        LinearGradient(
            colors: [Color.white.opacity(0.55), Color.black.opacity(0.3)],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    static var innerHighlightGradient: LinearGradient {
        LinearGradient(
            colors: [Color.white.opacity(0.28), Color.clear],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    private static func gradient(base: NSColor) -> LinearGradient {
        let top = base.blended(withFraction: 0.28, of: .white) ?? base
        let mid = base
        let bottom = base.blended(withFraction: 0.2, of: .black) ?? base
        return LinearGradient(
            stops: [
                .init(color: Color(nsColor: top), location: 0.0),
                .init(color: Color(nsColor: mid), location: 0.5),
                .init(color: Color(nsColor: bottom), location: 1.0)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    private static func emptyBase(darkMode: Bool) -> NSColor {
        darkMode
            ? NSColor(calibratedWhite: 0.34, alpha: 1.0)
            : NSColor(calibratedWhite: 0.82, alpha: 1.0)
    }
}

private struct ScanCapacityLegendItem: View {
    let title: String
    let value: String
    let color: Color

    var body: some View {
        HStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(color)
                .frame(width: 10, height: 10)
            Text("\(title): \(value)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
    }
}

private struct ScanCapacityBarView: View {
    @Environment(\.colorScheme) private var colorScheme
    let segments: NativeCapacitySegments
    let isRunning: Bool

    var body: some View {
        GeometryReader { geometry in
            let darkMode = colorScheme == .dark
            let total = max(Double(segments.totalBytes), 1.0)
            let barWidth = geometry.size.width
            let barHeight = geometry.size.height
            let widthForBytes: (UInt64) -> CGFloat = { bytes in
                barWidth * CGFloat(Double(bytes) / total)
            }
            let scannedWidth = widthForBytes(segments.scannedBytes)
            let deferredWidth = widthForBytes(segments.deferredBytes)
            let remainingWidth = widthForBytes(segments.remainingBytes)
            let emptyWidth = widthForBytes(segments.emptyBytes)

            ZStack(alignment: .leading) {
                Capsule(style: .continuous)
                    .fill(ScanCapacityPalette.trackGradient)

                HStack(spacing: 0) {
                    Rectangle()
                        .fill(ScanCapacityPalette.scannedGradient(darkMode: darkMode))
                        .frame(width: scannedWidth)
                    Rectangle()
                        .fill(ScanCapacityPalette.deferredGradient(darkMode: darkMode))
                        .frame(width: deferredWidth)
                    Rectangle()
                        .fill(ScanCapacityPalette.remainingGradient(darkMode: darkMode))
                        .frame(width: remainingWidth)
                    Rectangle()
                        .fill(ScanCapacityPalette.emptyGradient(darkMode: darkMode))
                        .frame(width: emptyWidth)
                }
                .clipShape(Capsule(style: .continuous))

                if isRunning {
                    TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
                        let phase = timeline.date.timeIntervalSinceReferenceDate
                            .truncatingRemainder(dividingBy: 1.8) / 1.8
                        let highlightWidth = min(max(barWidth * 0.2, 52), 180)
                        let offset = (barWidth + highlightWidth) * CGFloat(phase) - highlightWidth

                        ZStack(alignment: .leading) {
                            Color.clear
                            LinearGradient(
                                colors: [
                                    Color.white.opacity(0),
                                    Color.white.opacity(0.3),
                                    Color.white.opacity(0)
                                ],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                            .frame(width: highlightWidth, height: barHeight)
                            .offset(x: offset)
                        }
                        .frame(width: barWidth, height: barHeight, alignment: .leading)
                    }
                    .clipShape(Capsule(style: .continuous))
                    .allowsHitTesting(false)
                }

                Capsule(style: .continuous)
                    .fill(ScanCapacityPalette.glossGradient)

                Capsule(style: .continuous)
                    .fill(ScanCapacityPalette.lowerShadeGradient)

                Capsule(style: .continuous)
                    .strokeBorder(ScanCapacityPalette.rimGradient, lineWidth: 1)

                Capsule(style: .continuous)
                    .inset(by: 1)
                    .stroke(ScanCapacityPalette.innerHighlightGradient, lineWidth: 0.7)
            }
            .shadow(color: Color.black.opacity(0.12), radius: 0.8, x: 0, y: 0.6)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Disk scan capacity")
        .accessibilityValue(
            "Scanned \(segments.scannedBytes) bytes, deferred \(segments.deferredBytes) bytes, pending \(segments.remainingBytes) bytes, empty \(segments.emptyBytes) bytes"
        )
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

private struct MonitoringSheetView: View {
    @EnvironmentObject var store: NativeScanStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Background Monitoring")
                .font(.headline)

            if store.proEnabled {
                Text("Full Version is unlocked. Background daemon monitoring is planned for the next milestone.")
                    .font(.body)
                Text("Planned behavior: LaunchAgent + FSEvents stream with periodic reconcile scans and growth alerts.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Toggle("Enable background daemon (coming soon)", isOn: .constant(false))
                    .disabled(true)
            } else {
                Text("Unlock Full Version to access background monitoring when it ships.")
                    .font(.body)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            HStack {
                if store.buyFullVersionVisible {
                    Button("Buy Full Version") {
                        store.buyFullVersion()
                    }
                    .buttonStyle(.borderedProminent)
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
    let onContextAction: (UInt64, NativeNodeContextAction) -> Void

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
        private var contextNodeId: UInt64?

        init(parent: HierarchyOutlineView) {
            self.parent = parent
        }

        func contextMenu(for row: Int, in outlineView: NSOutlineView) -> NSMenu? {
            guard row >= 0,
                  let item = outlineView.item(atRow: row),
                  let nodeId = nodeId(from: item),
                  let node = parent.store.node(nodeId) else {
                return nil
            }

            contextNodeId = nodeId
            let menu = NSMenu(title: "Node")
            menu.autoenablesItems = false

            let showItem = contextMenuItem(
                title: "Show in Finder",
                action: .showInFinder,
                enabled: true
            )
            let revealParentItem = contextMenuItem(
                title: "Reveal Parent in Finder",
                action: .revealParentInFinder,
                enabled: true
            )
            let copyPathItem = contextMenuItem(
                title: "Copy Path",
                action: .copyPath,
                enabled: true
            )
            let expandDeferredItem = contextMenuItem(
                title: "Expand Deferred",
                action: .expandDeferred,
                enabled: node.childrenState == .collapsedByThreshold
            )
            let retryItem = contextMenuItem(
                title: "Retry",
                action: .retryScan,
                enabled: node.errorFlag
            )
            let deleteItem = contextMenuItem(
                title: "Delete…",
                action: .deleteToTrash,
                enabled: parent.store.canDeleteNode(nodeId: nodeId)
            )

            menu.items = [
                showItem,
                revealParentItem,
                copyPathItem,
                NSMenuItem.separator(),
                expandDeferredItem,
                retryItem,
                NSMenuItem.separator(),
                deleteItem
            ]
            return menu
        }

        private func contextMenuItem(
            title: String,
            action: NativeNodeContextAction,
            enabled: Bool
        ) -> NSMenuItem {
            let item = NSMenuItem(
                title: title,
                action: #selector(handleContextMenuAction(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.tag = action.rawValue
            item.isEnabled = enabled
            return item
        }

        @objc
        private func handleContextMenuAction(_ sender: NSMenuItem) {
            guard let nodeId = contextNodeId,
                  let action = NativeNodeContextAction(rawValue: sender.tag) else {
                return
            }
            parent.onContextAction(nodeId, action)
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
            let statusLane: NSView
            let deferredIconView: NSImageView
            let errorIconView: NSImageView
            if let reused = outlineView.makeView(withIdentifier: identifier, owner: nil) as? NSTableCellView {
                cell = reused
                label = reused.textField ?? NSTextField(labelWithString: "")
                deferredIconView = (reused.viewWithTag(1001) as? NSImageView) ?? NSImageView(frame: .zero)
                errorIconView = (reused.viewWithTag(1002) as? NSImageView) ?? NSImageView(frame: .zero)
                statusLane = deferredIconView.superview ?? NSView(frame: .zero)
            } else {
                cell = NSTableCellView(frame: .zero)
                cell.identifier = identifier

                let label = NSTextField(labelWithString: "")
                label.translatesAutoresizingMaskIntoConstraints = false
                label.alignment = .right
                label.lineBreakMode = .byTruncatingHead
                label.font = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .regular)
                label.textColor = .secondaryLabelColor

                let statusLane = NSView(frame: .zero)
                statusLane.translatesAutoresizingMaskIntoConstraints = false

                let deferredIconView = NSImageView(frame: .zero)
                deferredIconView.translatesAutoresizingMaskIntoConstraints = false
                deferredIconView.tag = 1001
                deferredIconView.imageScaling = .scaleProportionallyDown
                deferredIconView.contentTintColor = .systemOrange
                deferredIconView.image = statusIcon(key: "status.deferred", symbol: "clock.fill")

                let errorIconView = NSImageView(frame: .zero)
                errorIconView.translatesAutoresizingMaskIntoConstraints = false
                errorIconView.tag = 1002
                errorIconView.imageScaling = .scaleProportionallyDown
                errorIconView.contentTintColor = .systemRed
                errorIconView.image = statusIcon(key: "status.error", symbol: "exclamationmark.triangle.fill")

                label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

                statusLane.addSubview(deferredIconView)
                statusLane.addSubview(errorIconView)
                cell.addSubview(label)
                cell.addSubview(statusLane)
                cell.textField = label

                NSLayoutConstraint.activate([
                    label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
                    label.trailingAnchor.constraint(equalTo: statusLane.leadingAnchor, constant: -hierarchySizeToStatusGap),
                    label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),

                    statusLane.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -8),
                    statusLane.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                    statusLane.widthAnchor.constraint(equalToConstant: hierarchyStatusLaneWidth),
                    statusLane.heightAnchor.constraint(greaterThanOrEqualToConstant: hierarchyStatusIconWidth),

                    deferredIconView.leadingAnchor.constraint(equalTo: statusLane.leadingAnchor),
                    deferredIconView.centerYAnchor.constraint(equalTo: statusLane.centerYAnchor),
                    deferredIconView.widthAnchor.constraint(equalToConstant: hierarchyStatusIconWidth),
                    deferredIconView.heightAnchor.constraint(equalToConstant: hierarchyStatusIconWidth),

                    errorIconView.trailingAnchor.constraint(equalTo: statusLane.trailingAnchor),
                    errorIconView.centerYAnchor.constraint(equalTo: statusLane.centerYAnchor),
                    errorIconView.widthAnchor.constraint(equalToConstant: hierarchyStatusIconWidth),
                    errorIconView.heightAnchor.constraint(equalToConstant: hierarchyStatusIconWidth),

                    deferredIconView.trailingAnchor.constraint(
                        equalTo: errorIconView.leadingAnchor,
                        constant: -hierarchyStatusIconSpacing
                    )
                ])

                label.stringValue = parent.store.nodeSizeLabel(node)
                configureSizeStatusViews(
                    node: node,
                    statusLane: statusLane,
                    deferredIconView: deferredIconView,
                    errorIconView: errorIconView
                )
                return cell
            }

            label.stringValue = parent.store.nodeSizeLabel(node)
            label.textColor = .secondaryLabelColor
            configureSizeStatusViews(
                node: node,
                statusLane: statusLane,
                deferredIconView: deferredIconView,
                errorIconView: errorIconView
            )
            return cell
        }

        private func configureSizeStatusViews(
            node: NativeNode,
            statusLane: NSView,
            deferredIconView: NSImageView,
            errorIconView: NSImageView
        ) {
            let showsDeferred = node.childrenState == .collapsedByThreshold
            deferredIconView.isHidden = !showsDeferred

            let showsError = node.errorFlag
            errorIconView.isHidden = !showsError

            let tooltip = statusTooltip(nodeId: node.id, showsDeferred: showsDeferred, showsError: showsError)
            statusLane.toolTip = tooltip
            deferredIconView.toolTip = tooltip
            errorIconView.toolTip = tooltip
        }

        private func deferredTooltip(nodeId: UInt64) -> String {
            let nodePath = parent.store.path(for: nodeId)
            return """
            Deferred: subtree details were collapsed by scan threshold.
            \(nodePath)
            """
        }

        private func errorTooltip(nodeId: UInt64) -> String {
            let nodePath = parent.store.path(for: nodeId)
            let description = parent.store.nodeErrorDescription(nodeId: nodeId)
            return """
            Error: \(description)
            \(nodePath)
            """
        }

        private func statusTooltip(nodeId: UInt64, showsDeferred: Bool, showsError: Bool) -> String? {
            if showsDeferred && showsError {
                return "\(deferredTooltip(nodeId: nodeId))\n\n\(errorTooltip(nodeId: nodeId))"
            }
            if showsDeferred {
                return deferredTooltip(nodeId: nodeId)
            }
            if showsError {
                return errorTooltip(nodeId: nodeId)
            }
            return nil
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

private let hierarchySizeToStatusGap: CGFloat = 6
private let hierarchyStatusIconWidth: CGFloat = 12
private let hierarchyStatusIconSpacing: CGFloat = 4
private let hierarchyStatusLaneWidth: CGFloat =
    (hierarchyStatusIconWidth * 2) + hierarchyStatusIconSpacing

private final class HierarchyOutlineNativeView: NSOutlineView {
    var contextMenuProvider: ((Int) -> NSMenu?)?

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        let clicked = row(at: point)
        let targetRow = clicked >= 0 ? clicked : selectedRow
        guard targetRow >= 0 else {
            return nil
        }

        if selectedRow != targetRow {
            selectRowIndexes(IndexSet(integer: targetRow), byExtendingSelection: false)
        }
        return contextMenuProvider?(targetRow)
    }
}

private final class HierarchyOutlineContainerView: NSView {
    private let minReloadIntervalIdleSeconds: CFAbsoluteTime = 0.16
    private let minReloadIntervalScanningSeconds: CFAbsoluteTime = 1.0
    private let maxReloadIntervalScanningSeconds: CFAbsoluteTime = 3.0
    private let fullReloadRowLimit = 2_000
    private let minSizeColumnWidth: CGFloat = 108
    private let maxSizeColumnWidth: CGFloat = 260
    private let sizeColumnPadding: CGFloat = 16
    private let sizeValueFont = NSFont.monospacedDigitSystemFont(ofSize: 12.5, weight: .regular)

    private let scrollView = NSScrollView()
    private let outlineView = HierarchyOutlineNativeView()
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
        scrollView.backgroundColor = .clear
        scrollView.drawsBackground = false

        outlineView.headerView = NSTableHeaderView()
        outlineView.style = .sourceList
        outlineView.backgroundColor = .clear
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
        outlineView.contextMenuProvider = { [weak coordinator, weak outlineView] row in
            guard let coordinator, let outlineView else {
                return nil
            }
            return coordinator.contextMenu(for: row, in: outlineView)
        }
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
        let interval = reloadIntervalSeconds()
        let elapsed = now - lastReloadAt
        if elapsed >= interval {
            performVersionRefresh(coordinator: coordinator)
            return
        }

        guard !reloadScheduled else {
            return
        }
        reloadScheduled = true
        let generation = reloadGeneration
        let delay = interval - elapsed
        NativeDiagnostics.debug(
            "outline_refresh_scheduled delay=\(String(format: "%.3f", max(0, delay))) version=\(version) backlog=\(store?.pendingPatchBacklog ?? 0)"
        )
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

    private func reloadIntervalSeconds() -> CFAbsoluteTime {
        guard let store else {
            return minReloadIntervalIdleSeconds
        }
        if store.scanState == .running {
            if store.pendingPatchBacklog >= 24_000 {
                return maxReloadIntervalScanningSeconds
            }
            if store.pendingPatchBacklog >= 8_000 {
                return 2.0
            }
            return minReloadIntervalScanningSeconds
        }
        return minReloadIntervalIdleSeconds
    }

    private func performVersionRefresh(coordinator: HierarchyOutlineView.Coordinator) {
        guard configured, store?.node(rootId) != nil else {
            return
        }

        let refreshStartedAt = CFAbsoluteTimeGetCurrent()
        lastReloadAt = refreshStartedAt
        let didFullReload = outlineView.numberOfRows <= fullReloadRowLimit
        if didFullReload {
            outlineView.reloadData()
            applyExpandedState(coordinator: coordinator)
        } else {
            refreshVisibleRows()
        }
        fitSizeColumnToContent(coordinator: coordinator)

        if didFullReload || !isSelectionSynchronized(coordinator: coordinator) {
            syncSelection(coordinator: coordinator)
        }

        let refreshMode = didFullReload ? "full" : "visible"
        let details = "mode=\(refreshMode) rows=\(outlineView.numberOfRows) selected=\(selectedId) version=\(version)"
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
            width += hierarchySizeToStatusGap + hierarchyStatusLaneWidth

            if width > widest {
                widest = width
            }
        }

        if widest == 0 {
            widest = ("999.99 GiB" as NSString).size(withAttributes: [.font: sizeValueFont]).width
                + hierarchySizeToStatusGap
                + hierarchyStatusLaneWidth
        }

        let padded = widest + sizeColumnPadding
        let clamped = min(max(padded, minSizeColumnWidth), maxSizeColumnWidth)
        return ceil(clamped)
    }
}
