import AppKit
import SwiftUI

private struct TreemapRect {
    let nodeId: UInt64
    let rect: CGRect
    let depth: Int
}

private struct LayoutNodeSnapshot {
    let id: UInt64
    let name: String
    let sizeBytes: UInt64
    let kind: NativeNodeKind
    let childrenState: NativeChildrenState
    var children: [UInt64]
}

private struct LayoutSnapshot {
    let rootId: UInt64
    let nodes: [UInt64: LayoutNodeSnapshot]
    let exploredBounds: CGRect
}

private struct LayoutWorkItem {
    let nodeId: UInt64
    let rect: CGRect
    let depth: Int
}

private struct LayoutFrame {
    let generation: UInt64
    let modelVersion: UInt64
    let rootId: UInt64
    let rects: [TreemapRect]
    let exploredBounds: CGRect
    let isFinal: Bool
}

struct TreemapView: NSViewRepresentable {
    let store: NativeScanStore
    let rootId: UInt64
    let selectedId: UInt64
    let version: UInt64
    let exploredFraction: Double
    let onSelect: (UInt64) -> Void
    let onZoom: (UInt64) -> Void
    let onContextAction: (UInt64, NativeNodeContextAction) -> Void

    func makeNSView(context: Context) -> TreemapCanvas {
        let view = TreemapCanvas()
        view.onSelect = onSelect
        view.onZoom = onZoom
        view.onContextAction = onContextAction
        view.update(
            store: store,
            rootId: rootId,
            selectedId: selectedId,
            version: version,
            exploredFraction: exploredFraction
        )
        return view
    }

    func updateNSView(_ nsView: TreemapCanvas, context: Context) {
        nsView.onSelect = onSelect
        nsView.onZoom = onZoom
        nsView.onContextAction = onContextAction
        nsView.update(
            store: store,
            rootId: rootId,
            selectedId: selectedId,
            version: version,
            exploredFraction: exploredFraction
        )
    }
}

final class TreemapCanvas: NSView {
    private weak var store: NativeScanStore?
    private var rootId: UInt64 = 0
    private var selectedId: UInt64 = 0
    private var modelVersion: UInt64 = 0
    private var exploredFraction: Double = 0
    private var exploredBounds: CGRect = .zero
    private var rects: [TreemapRect] = []

    private var layoutScheduled = false
    private var layoutDirty = false
    private var layoutInFlight = false
    private var lastLayoutKickAt: CFAbsoluteTime = 0
    private var lastCommittedRootId: UInt64 = UInt64.max
    private var lastCommittedModelVersion: UInt64 = 0

    private let generationLock = NSLock()
    private var latestLayoutGeneration: UInt64 = 0
    private let layoutQueue = DispatchQueue(
        label: "com.diskscope.native.treemap-layout",
        qos: .userInitiated,
        attributes: .concurrent
    )

    private var drawSampleStartedAt: CFAbsoluteTime = 0
    private var drawSampleCount = 0

    private let maxDepth = 10
    private let minRectArea: CGFloat = 9
    private let maxRects = 35_000
    private let layoutNodeBudget = 100_000
    private let minLayoutIntervalIdleSeconds: CFAbsoluteTime = 0.16
    private let minLayoutIntervalScanningSeconds: CFAbsoluteTime = 1.0
    private let maxLayoutIntervalScanningSeconds: CFAbsoluteTime = 3.0

    var onSelect: ((UInt64) -> Void)?
    var onZoom: ((UInt64) -> Void)?
    var onContextAction: ((UInt64, NativeNodeContextAction) -> Void)?

    override var isFlipped: Bool {
        true
    }

    func update(
        store: NativeScanStore,
        rootId: UInt64,
        selectedId: UInt64,
        version: UInt64,
        exploredFraction: Double
    ) {
        let normalizedExploredFraction = max(0.0, min(1.0, exploredFraction))
        let rootChanged = rootId != self.rootId
        let storeChanged = self.store !== store
        let layoutInputsChanged = version != modelVersion
            || rootChanged
            || storeChanged
            || abs(self.exploredFraction - normalizedExploredFraction) > 0.0005

        self.store = store
        self.rootId = rootId
        modelVersion = version
        self.exploredFraction = normalizedExploredFraction
        self.selectedId = selectedId

        if layoutInputsChanged {
            scheduleLayout(forceImmediate: rootChanged || storeChanged)
        } else {
            needsDisplay = true
        }
    }

    override func layout() {
        super.layout()
        scheduleLayout(forceImmediate: true)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        let drawStartedAt = CFAbsoluteTimeGetCurrent()
        drawBackground()

        guard !rects.isEmpty else {
            let attrs: [NSAttributedString.Key: Any] = [
                .foregroundColor: NSColor.secondaryLabelColor,
                .font: NSFont.systemFont(ofSize: 14, weight: .medium)
            ]
            let placeholder = layoutInFlight ? "Computing layout..." : "Start a scan to render treemap"
            let text = NSString(string: placeholder)
            text.draw(at: CGPoint(x: 20, y: 20), withAttributes: attrs)
            return
        }

        let darkMode = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua

        for item in rects {
            guard let node = store?.nodes[item.nodeId] else {
                continue
            }

            let fill = color(for: node, depth: item.depth, darkMode: darkMode)
            fill.setFill()
            item.rect.fill()

            drawGlossOverlay(in: item.rect, node: node, depth: item.depth, darkMode: darkMode)

            if item.rect.width > 70 && item.rect.height > 24 {
                let textColor = NativeThemeColorPalette.treemapLabelColor(darkMode: darkMode)
                let attrs: [NSAttributedString.Key: Any] = [
                    .foregroundColor: textColor,
                    .font: NSFont.systemFont(ofSize: 11, weight: .medium)
                ]
                NSString(string: node.name).draw(
                    in: item.rect.insetBy(dx: 4, dy: 4),
                    withAttributes: attrs
                )
            }
        }

        drawSelectedInsetBorder(darkMode: darkMode)
        recordDrawSample(startedAt: drawStartedAt)
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let hit = hitNode(at: point) else {
            return
        }

        onSelect?(hit)
        if event.clickCount >= 2 {
            onZoom?(hit)
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        guard let hit = hitNode(at: point), store?.node(hit) != nil else {
            return nil
        }

        onSelect?(hit)

        let menu = NSMenu(title: "Node")
        menu.autoenablesItems = false
        menu.items = [
            makeContextMenuItem(title: "Show in Finder", action: .showInFinder, nodeId: hit, enabled: true),
            makeContextMenuItem(
                title: "Reveal Parent in Finder",
                action: .revealParentInFinder,
                nodeId: hit,
                enabled: true
            ),
            makeContextMenuItem(title: "Copy Path", action: .copyPath, nodeId: hit, enabled: true),
            NSMenuItem.separator(),
            makeContextMenuItem(
                title: "Delete…",
                action: .deleteToTrash,
                nodeId: hit,
                enabled: store?.canDeleteNode(nodeId: hit) ?? false
            )
        ]
        return menu
    }

    private func makeContextMenuItem(
        title: String,
        action: NativeNodeContextAction,
        nodeId: UInt64,
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
        item.representedObject = NSNumber(value: nodeId)
        return item
    }

    @objc
    private func handleContextMenuAction(_ sender: NSMenuItem) {
        guard let represented = sender.representedObject as? NSNumber,
              let action = NativeNodeContextAction(rawValue: sender.tag) else {
            return
        }
        onContextAction?(represented.uint64Value, action)
    }

    private func hitNode(at point: CGPoint) -> UInt64? {
        for item in rects.reversed() where item.rect.contains(point) {
            return item.nodeId
        }
        return nil
    }

    private func scheduleLayout(forceImmediate: Bool = false) {
        layoutDirty = true
        if layoutScheduled {
            return
        }
        layoutScheduled = true

        let now = CFAbsoluteTimeGetCurrent()
        let interval = forceImmediate ? 0 : layoutIntervalSeconds()
        let delay: CFAbsoluteTime
        if forceImmediate || lastLayoutKickAt == 0 {
            delay = 0
        } else {
            let elapsed = now - lastLayoutKickAt
            delay = max(0, interval - elapsed)
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else {
                return
            }
            self.layoutScheduled = false
            guard self.layoutDirty else {
                return
            }
            self.layoutDirty = false
            self.lastLayoutKickAt = CFAbsoluteTimeGetCurrent()
            self.launchLayoutJob()
        }
    }

    private func layoutIntervalSeconds() -> CFAbsoluteTime {
        guard let store else {
            return minLayoutIntervalIdleSeconds
        }

        if store.scanState == .running {
            if store.pendingPatchBacklog >= 24_000 {
                return maxLayoutIntervalScanningSeconds
            }
            if store.pendingPatchBacklog >= 8_000 {
                return 2.0
            }
            return minLayoutIntervalScanningSeconds
        }

        return minLayoutIntervalIdleSeconds
    }

    private func launchLayoutJob() {
        let startedAt = CFAbsoluteTimeGetCurrent()
        guard bounds.width > 4, bounds.height > 4 else {
            clearLayoutOrPreserveLast(reason: "bounds_too_small")
            return
        }
        guard let store else {
            clearLayoutOrPreserveLast(reason: "store_unavailable")
            return
        }

        let inset = bounds.insetBy(dx: 2, dy: 2)
        let exploredBounds = exploredRect(in: inset, fraction: exploredFraction)
        guard exploredBounds.width > 2, exploredBounds.height > 2 else {
            clearLayoutOrPreserveLast(exploredBounds: exploredBounds, reason: "explored_bounds_too_small")
            return
        }

        guard let snapshot = captureLayoutSnapshot(
            store: store,
            rootId: rootId,
            exploredBounds: exploredBounds
        ) else {
            clearLayoutOrPreserveLast(exploredBounds: exploredBounds, reason: "snapshot_unavailable")
            return
        }

        let generation = reserveLayoutGeneration()
        let layoutModelVersion = modelVersion
        layoutInFlight = true
        NativeDiagnostics.debug(
            "treemap_layout_launch gen=\(generation) version=\(layoutModelVersion) root=\(rootId) explored=\(String(format: "%.4f", exploredFraction)) backlog=\(store.pendingPatchBacklog)"
        )

        NativeDiagnostics.slowPath(
            "treemap_snapshot",
            startedAt: startedAt,
            thresholdMs: 14,
            details: "gen=\(generation) nodes=\(snapshot.nodes.count) backlog=\(store.pendingPatchBacklog)"
        )

        layoutQueue.async { [weak self] in
            guard let self else {
                return
            }
            self.computeLayoutProgressively(
                snapshot: snapshot,
                generation: generation,
                modelVersion: layoutModelVersion
            )
        }
    }

    private func captureLayoutSnapshot(
        store: NativeScanStore,
        rootId: UInt64,
        exploredBounds: CGRect
    ) -> LayoutSnapshot? {
        guard let rootNode = store.nodes[rootId] else {
            return nil
        }

        var snapshots: [UInt64: LayoutNodeSnapshot] = [:]
        snapshots.reserveCapacity(min(layoutNodeBudget, store.nodes.count))

        var queue: [UInt64] = [rootId]
        var enqueued: Set<UInt64> = [rootId]
        var cursor = 0

        snapshots[rootId] = LayoutNodeSnapshot(
            id: rootNode.id,
            name: rootNode.name,
            sizeBytes: rootNode.sizeBytes,
            kind: rootNode.kind,
            childrenState: rootNode.childrenState,
            children: []
        )

        while cursor < queue.count {
            if snapshots.count >= layoutNodeBudget {
                break
            }

            let nodeId = queue[cursor]
            cursor += 1

            guard let node = store.nodes[nodeId] else {
                continue
            }

            if snapshots[nodeId] == nil {
                snapshots[nodeId] = LayoutNodeSnapshot(
                    id: node.id,
                    name: node.name,
                    sizeBytes: node.sizeBytes,
                    kind: node.kind,
                    childrenState: node.childrenState,
                    children: []
                )
            }

            let canExpand = node.kind == .directory
                && node.childrenState != .collapsedByThreshold
                && !node.children.isEmpty
            guard canExpand else {
                continue
            }

            var keptChildren: [UInt64] = []
            keptChildren.reserveCapacity(node.children.count)

            for childId in node.children {
                guard let child = store.nodes[childId] else {
                    continue
                }

                if snapshots[childId] == nil {
                    if snapshots.count >= layoutNodeBudget {
                        break
                    }

                    snapshots[childId] = LayoutNodeSnapshot(
                        id: child.id,
                        name: child.name,
                        sizeBytes: child.sizeBytes,
                        kind: child.kind,
                        childrenState: child.childrenState,
                        children: []
                    )
                }

                keptChildren.append(childId)

                let childExpandable = child.kind == .directory
                    && child.childrenState != .collapsedByThreshold
                    && !child.children.isEmpty

                if childExpandable,
                   !enqueued.contains(childId),
                   queue.count < layoutNodeBudget {
                    queue.append(childId)
                    enqueued.insert(childId)
                }
            }

            if var entry = snapshots[nodeId] {
                entry.children = keptChildren
                snapshots[nodeId] = entry
            }
        }

        return LayoutSnapshot(rootId: rootId, nodes: snapshots, exploredBounds: exploredBounds)
    }

    private func computeLayoutProgressively(
        snapshot: LayoutSnapshot,
        generation: UInt64,
        modelVersion: UInt64
    ) {
        let startedAt = CFAbsoluteTimeGetCurrent()

        var output: [TreemapRect] = []
        output.reserveCapacity(min(maxRects, snapshot.nodes.count))

        var currentLevel: [LayoutWorkItem] = [
            LayoutWorkItem(nodeId: snapshot.rootId, rect: snapshot.exploredBounds, depth: 0)
        ]

        var levelsBuilt = 0
        var emittedAnyFrame = false

        while !currentLevel.isEmpty && levelsBuilt < maxDepth && output.count < maxRects {
            guard isLayoutGenerationCurrent(generation) else {
                return
            }

            var nextLevel: [LayoutWorkItem] = []
            nextLevel.reserveCapacity(currentLevel.count * 2)

            for work in currentLevel {
                guard isLayoutGenerationCurrent(generation) else {
                    return
                }

                guard let node = snapshot.nodes[work.nodeId], !node.children.isEmpty else {
                    continue
                }

                let children = sortedChildren(node.children, nodes: snapshot.nodes)
                if children.isEmpty {
                    continue
                }

                let total = children
                    .map { max(Double(snapshot.nodes[$0]?.sizeBytes ?? 1), 1.0) }
                    .reduce(0, +)
                if total <= 0 {
                    continue
                }

                let horizontal = work.depth % 2 == 0
                var cursor = horizontal ? work.rect.minX : work.rect.minY
                let totalExtent = horizontal ? work.rect.width : work.rect.height

                for (index, childId) in children.enumerated() {
                    guard isLayoutGenerationCurrent(generation) else {
                        return
                    }
                    if output.count >= maxRects {
                        break
                    }

                    let childSize = max(Double(snapshot.nodes[childId]?.sizeBytes ?? 1), 1.0)
                    let isLast = index == children.count - 1
                    var extent = CGFloat(childSize / total) * totalExtent
                    if isLast {
                        extent = horizontal ? work.rect.maxX - cursor : work.rect.maxY - cursor
                    }
                    if extent < 1.5 {
                        continue
                    }

                    let childRect: CGRect
                    if horizontal {
                        childRect = CGRect(
                            x: cursor,
                            y: work.rect.minY,
                            width: extent,
                            height: work.rect.height
                        )
                    } else {
                        childRect = CGRect(
                            x: work.rect.minX,
                            y: cursor,
                            width: work.rect.width,
                            height: extent
                        )
                    }
                    cursor += extent

                    if childRect.width * childRect.height < minRectArea {
                        continue
                    }

                    output.append(TreemapRect(nodeId: childId, rect: childRect, depth: work.depth))

                    if let childNode = snapshot.nodes[childId],
                       childNode.kind == .directory,
                       childNode.childrenState != .collapsedByThreshold,
                       !childNode.children.isEmpty,
                       work.depth + 1 < maxDepth {
                        nextLevel.append(
                            LayoutWorkItem(
                                nodeId: childId,
                                rect: childRect,
                                depth: work.depth + 1
                            )
                        )
                    }
                }
            }

            levelsBuilt += 1
            let isFinal = nextLevel.isEmpty || levelsBuilt >= maxDepth || output.count >= maxRects
            emitLayoutFrame(
                LayoutFrame(
                    generation: generation,
                    modelVersion: modelVersion,
                    rootId: snapshot.rootId,
                    rects: output,
                    exploredBounds: snapshot.exploredBounds,
                    isFinal: isFinal
                )
            )
            emittedAnyFrame = true

            if isFinal {
                break
            }

            currentLevel = nextLevel
        }

        if !emittedAnyFrame {
            emitLayoutFrame(
                LayoutFrame(
                    generation: generation,
                    modelVersion: modelVersion,
                    rootId: snapshot.rootId,
                    rects: [],
                    exploredBounds: snapshot.exploredBounds,
                    isFinal: true
                )
            )
        }

        if isLayoutGenerationCurrent(generation) {
            NativeDiagnostics.slowPath(
                "treemap_relayout",
                startedAt: startedAt,
                thresholdMs: 18,
                details: "gen=\(generation) rects=\(output.count) levels=\(levelsBuilt) nodes=\(snapshot.nodes.count)"
            )
        }
    }

    private func emitLayoutFrame(_ frame: LayoutFrame) {
        DispatchQueue.main.async { [weak self] in
            guard let self else {
                return
            }
            guard self.isLayoutGenerationCurrent(frame.generation) else {
                return
            }
            if !frame.isFinal {
                return
            }

            // Progressive recompute can transiently emit empty snapshots while patches are still in flight.
            // Keep the last committed frame to avoid visual blank flashes.
            if frame.rects.isEmpty && !frame.isFinal {
                NativeDiagnostics.debug(
                    "treemap_frame_skip_empty_intermediate gen=\(frame.generation) version=\(frame.modelVersion) root=\(frame.rootId)"
                )
                return
            }
            if self.shouldPreserveCommittedLayout(for: frame) {
                self.exploredBounds = frame.exploredBounds
                if frame.isFinal {
                    self.layoutInFlight = false
                }
                NativeDiagnostics.debug(
                    "treemap_frame_preserve_committed gen=\(frame.generation) version=\(frame.modelVersion) root=\(frame.rootId) prev_rects=\(self.rects.count)"
                )
                self.needsDisplay = true
                return
            }

            self.rects = frame.rects
            self.exploredBounds = frame.exploredBounds
            self.lastCommittedRootId = frame.rootId
            self.lastCommittedModelVersion = frame.modelVersion
            if frame.isFinal {
                self.layoutInFlight = false
            }
            NativeDiagnostics.debug(
                "treemap_frame_apply gen=\(frame.generation) version=\(frame.modelVersion) root=\(frame.rootId) rects=\(frame.rects.count) final=\(frame.isFinal)"
            )
            self.needsDisplay = true
        }
    }

    private func shouldPreserveCommittedLayout(for frame: LayoutFrame) -> Bool {
        guard frame.isFinal,
              frame.rects.isEmpty,
              !rects.isEmpty,
              rootId == lastCommittedRootId else {
            return false
        }

        // Do not preserve stale rectangles when the current root is genuinely empty
        // (e.g. zooming into a file, reset model before first patches).
        guard let store,
              let currentRoot = store.nodes[frame.rootId],
              !currentRoot.children.isEmpty else {
            return false
        }
        return frame.modelVersion >= lastCommittedModelVersion
    }

    private func clearLayoutOrPreserveLast(
        exploredBounds: CGRect = .zero,
        reason: String
    ) {
        if let store,
           rootId == lastCommittedRootId,
           !rects.isEmpty,
           let root = store.nodes[rootId],
           !root.children.isEmpty {
            self.exploredBounds = exploredBounds
            layoutInFlight = false
            NativeDiagnostics.debug(
                "treemap_layout_preserve reason=\(reason) version=\(modelVersion) root=\(rootId) rects=\(rects.count)"
            )
            needsDisplay = true
            return
        }
        NativeDiagnostics.debug(
            "treemap_layout_clear reason=\(reason) version=\(modelVersion) root=\(rootId)"
        )
        clearLayout(exploredBounds: exploredBounds)
    }

    private func clearLayout(exploredBounds: CGRect = .zero) {
        rects = []
        self.exploredBounds = exploredBounds
        layoutInFlight = false
        needsDisplay = true
    }

    private func reserveLayoutGeneration() -> UInt64 {
        generationLock.lock()
        defer { generationLock.unlock() }
        latestLayoutGeneration &+= 1
        return latestLayoutGeneration
    }

    private func isLayoutGenerationCurrent(_ generation: UInt64) -> Bool {
        generationLock.lock()
        defer { generationLock.unlock() }
        return latestLayoutGeneration == generation
    }

    private func sortedChildren(
        _ children: [UInt64],
        nodes: [UInt64: LayoutNodeSnapshot]
    ) -> [UInt64] {
        children.sorted { left, right in
            let leftNode = nodes[left]
            let rightNode = nodes[right]
            let leftSize = leftNode?.sizeBytes ?? 0
            let rightSize = rightNode?.sizeBytes ?? 0
            if leftSize == rightSize {
                return (leftNode?.name ?? "") < (rightNode?.name ?? "")
            }
            return leftSize > rightSize
        }
    }

    private func recordDrawSample(startedAt: CFAbsoluteTime) {
        NativeDiagnostics.slowPath(
            "treemap_draw",
            startedAt: startedAt,
            thresholdMs: 12,
            details: "rects=\(rects.count)"
        )

        guard NativeDiagnostics.enabled else {
            return
        }

        let now = CFAbsoluteTimeGetCurrent()
        if drawSampleStartedAt == 0 {
            drawSampleStartedAt = now
            drawSampleCount = 1
            return
        }

        drawSampleCount += 1
        let elapsed = now - drawSampleStartedAt
        guard elapsed >= 2.0 else {
            return
        }

        let fps = Double(drawSampleCount) / elapsed
        NativeDiagnostics.debug("treemap_fps fps=\(String(format: "%.1f", fps)) rects=\(rects.count) inflight=\(layoutInFlight)")
        drawSampleStartedAt = now
        drawSampleCount = 0
    }

    private func exploredRect(in bounds: CGRect, fraction: Double) -> CGRect {
        let clamped = max(0.0, min(1.0, fraction))
        if clamped <= 0.0 {
            return CGRect(x: bounds.minX, y: bounds.minY, width: 0, height: 0)
        }
        if clamped >= 1.0 {
            return bounds
        }

        let sideScale = CGFloat(sqrt(clamped))
        return CGRect(
            x: bounds.minX,
            y: bounds.minY,
            width: bounds.width * sideScale,
            height: bounds.height * sideScale
        )
    }

    private func drawBackground() {
        let top = NSColor.windowBackgroundColor.blended(withFraction: 0.20, of: .controlBackgroundColor)
            ?? NSColor.windowBackgroundColor
        let bottom = NSColor.windowBackgroundColor
        if let gradient = NSGradient(starting: top, ending: bottom) {
            gradient.draw(in: bounds, angle: 90)
        } else {
            NSColor.windowBackgroundColor.setFill()
            bounds.fill()
        }
    }

    private func drawGlossOverlay(in rect: CGRect, node: NativeNode, depth: Int, darkMode: Bool) {
        let area = rect.width * rect.height
        if area < 220 || rect.width < 12 || rect.height < 12 {
            return
        }

        let depthFactor = min(CGFloat(depth), 8) / 8
        let highlightAlphaBase: CGFloat = darkMode ? 0.20 : 0.26
        let shadeAlphaBase: CGFloat = darkMode ? 0.24 : 0.14
        let highlightAlpha = max(0.06, highlightAlphaBase * (1.0 - depthFactor * 0.45))
        let shadeAlpha = min(0.28, shadeAlphaBase * (1.0 + depthFactor * 0.25))

        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: rect).addClip()

        if let topGloss = NSGradient(colors: [
            NSColor.white.withAlphaComponent(highlightAlpha),
            NSColor.white.withAlphaComponent(highlightAlpha * 0.35),
            NSColor.white.withAlphaComponent(0.0)
        ]) {
            topGloss.draw(in: rect, angle: 90)
        }

        if let diagonalShade = NSGradient(colors: [
            NSColor.clear,
            NSColor.black.withAlphaComponent(shadeAlpha * 0.30),
            NSColor.black.withAlphaComponent(shadeAlpha)
        ]) {
            diagonalShade.draw(in: rect, angle: -38)
        }

        if node.kind == .directory || node.kind == .collapsedDirectory {
            let bandHeight = min(rect.height * 0.28, 26)
            let bandRect = CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: bandHeight)
            if let band = NSGradient(colors: [
                NSColor.white.withAlphaComponent(darkMode ? 0.09 : 0.12),
                NSColor.white.withAlphaComponent(0.0)
            ]) {
                band.draw(in: bandRect, angle: 90)
            }
        }

        NSGraphicsContext.restoreGraphicsState()
    }

    private func drawSelectedInsetBorder(darkMode _: Bool) {
        let selectedRect: CGRect?
        if selectedId == rootId {
            selectedRect = exploredBounds
        } else {
            selectedRect = rects.first(where: { $0.nodeId == selectedId })?.rect
        }

        guard var rect = selectedRect,
              rect.width > 2.0,
              rect.height > 2.0 else {
            return
        }

        let lineWidth: CGFloat = 2.0
        rect = rect.insetBy(dx: lineWidth * 0.5, dy: lineWidth * 0.5)
        guard rect.width > 0.0, rect.height > 0.0 else {
            return
        }

        let borderPath = NSBezierPath(rect: rect)
        borderPath.lineWidth = lineWidth
        NSColor.labelColor.withAlphaComponent(0.72).setStroke()
        borderPath.stroke()
    }

    private func color(for node: NativeNode, depth _: Int, darkMode: Bool) -> NSColor {
        switch node.kind {
        case .file:
            let ext = fileExtension(for: node.name)
            return NativeThemeColorPalette.hashedHueColor(
                hash: stableHash(ext),
                darkMode: darkMode,
                alpha: 0.96
            )

        case .directory:
            return NativeThemeColorPalette.hashedHueColor(
                hash: stableHash(node.name),
                darkMode: darkMode,
                alpha: 0.95
            )

        case .collapsedDirectory:
            return NativeThemeColorPalette.hashedHueColor(
                hash: stableHash("_collapsed_\(node.name)"),
                darkMode: darkMode,
                alpha: 0.96
            )
        }
    }

    private func fileExtension(for name: String) -> String {
        let ext = URL(fileURLWithPath: name).pathExtension.lowercased()
        return ext.isEmpty ? "_no_ext" : ext
    }

    private func stableHash(_ value: String) -> UInt64 {
        var hash: UInt64 = 1469598103934665603
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 1099511628211
        }
        return hash
    }
}
