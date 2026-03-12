import AppKit
import SwiftUI

private struct TreemapRect {
    let nodeId: UInt64
    let rect: CGRect
    let depth: Int
}

private struct EdgeKey: Hashable {
    let axis: UInt8 // 0 = horizontal, 1 = vertical
    let major: Int32
    let start: Int32
    let end: Int32
}

private struct EdgeSegment {
    let from: CGPoint
    let to: CGPoint
}

struct TreemapView: NSViewRepresentable {
    let store: NativeScanStore
    let rootId: UInt64
    let selectedId: UInt64
    let version: UInt64
    let exploredFraction: Double
    let onSelect: (UInt64) -> Void
    let onZoom: (UInt64) -> Void

    func makeNSView(context: Context) -> TreemapCanvas {
        let view = TreemapCanvas()
        view.onSelect = onSelect
        view.onZoom = onZoom
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
    private var sharedBorderSegments: [EdgeSegment] = []
    private var edgeKeysByNode: [UInt64: [EdgeKey]] = [:]
    private var exploredEdgeKeys: [EdgeKey] = []
    private var layoutScheduled = false
    private var layoutDirty = false
    private var lastLayoutAt: CFAbsoluteTime = 0

    private let maxDepth = 10
    private let minRectArea: CGFloat = 9
    private let maxRects = 20_000
    private let minLayoutIntervalSeconds: CFAbsoluteTime = 0.12

    var onSelect: ((UInt64) -> Void)?
    var onZoom: ((UInt64) -> Void)?

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
        let layoutInputsChanged = version != modelVersion
            || rootId != self.rootId
            || self.store !== store
            || abs(self.exploredFraction - normalizedExploredFraction) > 0.0005
        self.store = store
        self.rootId = rootId
        modelVersion = version
        self.exploredFraction = normalizedExploredFraction
        self.selectedId = selectedId
        if layoutInputsChanged {
            scheduleLayout()
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

        drawBackground()

        guard !rects.isEmpty else {
            let attrs: [NSAttributedString.Key: Any] = [
                .foregroundColor: NSColor.secondaryLabelColor,
                .font: NSFont.systemFont(ofSize: 14, weight: .medium)
            ]
            let text = NSString(string: "Start a scan to render treemap")
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
                let textColor = textColor(for: fill, darkMode: darkMode)
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

        drawSharedBorders(darkMode: darkMode)
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
        let delay: CFAbsoluteTime
        if forceImmediate || lastLayoutAt == 0 {
            delay = 0
        } else {
            let elapsed = now - lastLayoutAt
            delay = max(0, minLayoutIntervalSeconds - elapsed)
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
            self.lastLayoutAt = CFAbsoluteTimeGetCurrent()
            self.recomputeLayout()
            self.needsDisplay = true
        }
    }

    private func recomputeLayout() {
        guard bounds.width > 4, bounds.height > 4 else {
            rects = []
            sharedBorderSegments = []
            edgeKeysByNode = [:]
            exploredEdgeKeys = []
            exploredBounds = .zero
            return
        }
        guard let store else {
            rects = []
            sharedBorderSegments = []
            edgeKeysByNode = [:]
            exploredEdgeKeys = []
            exploredBounds = .zero
            return
        }
        let nodes = store.nodes

        var output: [TreemapRect] = []
        let inset = bounds.insetBy(dx: 2, dy: 2)
        let computedExploredBounds = exploredRect(in: inset, fraction: exploredFraction)
        exploredBounds = computedExploredBounds
        guard computedExploredBounds.width > 2, computedExploredBounds.height > 2 else {
            rects = []
            sharedBorderSegments = []
            edgeKeysByNode = [:]
            exploredEdgeKeys = []
            return
        }
        layoutChildren(
            nodeId: rootId,
            rect: computedExploredBounds,
            depth: 0,
            maxDepth: maxDepth,
            nodes: nodes,
            out: &output
        )
        rects = output
        rebuildSharedBorders()
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

    private func layoutChildren(
        nodeId: UInt64,
        rect: CGRect,
        depth: Int,
        maxDepth: Int,
        nodes: [UInt64: NativeNode],
        out: inout [TreemapRect]
    ) {
        if out.count >= maxRects || depth >= maxDepth || rect.width < 2 || rect.height < 2 {
            return
        }

        guard let node = nodes[nodeId], !node.children.isEmpty else {
            return
        }

        let children = sortedChildren(of: node, nodes: nodes)
        let total = children
            .map { max(Double(nodes[$0]?.sizeBytes ?? 1), 1.0) }
            .reduce(0, +)

        if total <= 0 {
            return
        }

        let horizontal = depth % 2 == 0
        var cursor = horizontal ? rect.minX : rect.minY
        let totalExtent = horizontal ? rect.width : rect.height

        for (index, childId) in children.enumerated() {
            let childSize = max(Double(nodes[childId]?.sizeBytes ?? 1), 1.0)
            let isLast = index == children.count - 1
            var extent = CGFloat(childSize / total) * totalExtent
            if isLast {
                extent = horizontal ? rect.maxX - cursor : rect.maxY - cursor
            }
            if extent < 1.5 {
                continue
            }

            let childRect: CGRect
            if horizontal {
                childRect = CGRect(x: cursor, y: rect.minY, width: extent, height: rect.height)
            } else {
                childRect = CGRect(x: rect.minX, y: cursor, width: rect.width, height: extent)
            }
            cursor += extent

            if childRect.width * childRect.height < minRectArea {
                continue
            }

            out.append(TreemapRect(nodeId: childId, rect: childRect, depth: depth))

            if let childNode = nodes[childId],
               childNode.kind == .directory,
               childNode.childrenState != .collapsedByThreshold {
                layoutChildren(
                    nodeId: childId,
                    rect: childRect,
                    depth: depth + 1,
                    maxDepth: maxDepth,
                    nodes: nodes,
                    out: &out
                )
            }
        }
    }

    private func sortedChildren(of node: NativeNode, nodes: [UInt64: NativeNode]) -> [UInt64] {
        node.children.sorted { left, right in
            let leftSize = nodes[left]?.sizeBytes ?? 0
            let rightSize = nodes[right]?.sizeBytes ?? 0
            if leftSize == rightSize {
                return (nodes[left]?.name ?? "") < (nodes[right]?.name ?? "")
            }
            return leftSize > rightSize
        }
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

    private func rebuildSharedBorders() {
        edgeKeysByNode.removeAll(keepingCapacity: true)
        exploredEdgeKeys = edgeKeys(for: exploredBounds)

        var unique = Set<EdgeKey>()
        unique.formUnion(exploredEdgeKeys)

        for item in rects {
            let keys = edgeKeys(for: item.rect)
            edgeKeysByNode[item.nodeId] = keys
            unique.formUnion(keys)
        }

        sharedBorderSegments = unique.map(edgeSegment(from:))
    }

    private func drawSharedBorders(darkMode: Bool) {
        guard !sharedBorderSegments.isEmpty else {
            return
        }

        let normalBorderColor = darkMode
            ? NSColor.separatorColor.withAlphaComponent(0.55)
            : NSColor.separatorColor.withAlphaComponent(0.42)
        drawBorderSegments(sharedBorderSegments, color: normalBorderColor, lineWidth: 1.0)

        var selectedKeys = Set<EdgeKey>()
        if selectedId == rootId {
            selectedKeys.formUnion(exploredEdgeKeys)
        }
        if let keys = edgeKeysByNode[selectedId] {
            selectedKeys.formUnion(keys)
        }

        if !selectedKeys.isEmpty {
            let selectedSegments = selectedKeys.map(edgeSegment(from:))
            drawBorderSegments(
                selectedSegments,
                color: NSColor.controlAccentColor.withAlphaComponent(0.96),
                lineWidth: 2.0
            )
        }
    }

    private func drawBorderSegments(_ segments: [EdgeSegment], color: NSColor, lineWidth: CGFloat) {
        guard !segments.isEmpty else {
            return
        }
        let path = NSBezierPath()
        path.lineCapStyle = .butt
        path.lineJoinStyle = .miter
        path.lineWidth = lineWidth
        for segment in segments {
            path.move(to: segment.from)
            path.line(to: segment.to)
        }
        color.setStroke()
        path.stroke()
    }

    private func edgeKeys(for rect: CGRect) -> [EdgeKey] {
        let minX = quantize(rect.minX)
        let maxX = quantize(rect.maxX)
        let minY = quantize(rect.minY)
        let maxY = quantize(rect.maxY)
        if minX >= maxX || minY >= maxY {
            return []
        }

        return [
            EdgeKey(axis: 0, major: minY, start: minX, end: maxX),
            EdgeKey(axis: 0, major: maxY, start: minX, end: maxX),
            EdgeKey(axis: 1, major: minX, start: minY, end: maxY),
            EdgeKey(axis: 1, major: maxX, start: minY, end: maxY)
        ]
    }

    private func edgeSegment(from key: EdgeKey) -> EdgeSegment {
        if key.axis == 0 {
            let y = dequantize(key.major)
            return EdgeSegment(
                from: CGPoint(x: dequantize(key.start), y: y),
                to: CGPoint(x: dequantize(key.end), y: y)
            )
        }

        let x = dequantize(key.major)
        return EdgeSegment(
            from: CGPoint(x: x, y: dequantize(key.start)),
            to: CGPoint(x: x, y: dequantize(key.end))
        )
    }

    private func quantize(_ value: CGFloat) -> Int32 {
        Int32((value * 2.0).rounded())
    }

    private func dequantize(_ value: Int32) -> CGFloat {
        CGFloat(value) / 2.0
    }

    private func color(for node: NativeNode, depth: Int, darkMode: Bool) -> NSColor {
        let palette: [NSColor] = [
            .systemBlue,
            .systemTeal,
            .systemCyan,
            .systemMint,
            .systemGreen,
            .systemYellow,
            .systemOrange,
            .systemRed,
            .systemPink,
            .systemPurple,
            .systemIndigo
        ]

        switch node.kind {
        case .file:
            let ext = fileExtension(for: node.name)
            let base = palette[Int(stableHash(ext) % UInt64(palette.count))]
            let softened = darkMode
                ? (base.blended(withFraction: 0.15, of: NSColor.white) ?? base)
                : (base.blended(withFraction: 0.14, of: NSColor.black) ?? base)
            return softened.withAlphaComponent(0.96)

        case .directory:
            let neutral = darkMode
                ? NSColor(calibratedWhite: min(0.42, 0.25 + CGFloat(depth) * 0.02), alpha: 1.0)
                : NSColor(calibratedWhite: max(0.72, 0.92 - CGFloat(depth) * 0.02), alpha: 1.0)
            let tint = palette[Int(stableHash(node.name) % UInt64(palette.count))]
            let mixed = neutral.blended(withFraction: darkMode ? 0.18 : 0.14, of: tint) ?? neutral
            return mixed.withAlphaComponent(0.95)

        case .collapsedDirectory:
            let collapsedBase = NSColor.systemOrange
            let mixed = darkMode
                ? (collapsedBase.blended(withFraction: 0.28, of: NSColor.black) ?? collapsedBase)
                : (collapsedBase.blended(withFraction: 0.20, of: NSColor.white) ?? collapsedBase)
            return mixed.withAlphaComponent(0.96)
        }
    }

    private func textColor(for fill: NSColor, darkMode: Bool) -> NSColor {
        let rgb = fill.usingColorSpace(.deviceRGB) ?? fill
        let luma = (0.2126 * rgb.redComponent + 0.7152 * rgb.greenComponent + 0.0722 * rgb.blueComponent) * 255
        if darkMode {
            return luma > 148 ? NSColor(calibratedWhite: 0.08, alpha: 1) : NSColor(calibratedWhite: 0.95, alpha: 1)
        }
        return luma > 155 ? NSColor(calibratedWhite: 0.10, alpha: 1) : NSColor(calibratedWhite: 0.98, alpha: 1)
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
