import AppKit
import SwiftUI

private struct TreemapRect {
    let nodeId: UInt64
    let rect: CGRect
    let depth: Int
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
    private var rects: [TreemapRect] = []
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

        NSColor.windowBackgroundColor.setFill()
        bounds.fill()

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

            let borderColor: NSColor = item.nodeId == selectedId ? NSColor.controlAccentColor : NSColor.separatorColor
            borderColor.setStroke()
            let border = NSBezierPath(rect: item.rect.insetBy(dx: 0.5, dy: 0.5))
            border.lineWidth = item.nodeId == selectedId ? 2.0 : 1.0
            border.stroke()

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
            return
        }
        guard let store else {
            rects = []
            return
        }
        let nodes = store.nodes

        var output: [TreemapRect] = []
        let inset = bounds.insetBy(dx: 2, dy: 2)
        let exploredBounds = exploredRect(in: inset, fraction: exploredFraction)
        guard exploredBounds.width > 2, exploredBounds.height > 2 else {
            rects = []
            return
        }
        layoutChildren(
            nodeId: rootId,
            rect: exploredBounds,
            depth: 0,
            maxDepth: maxDepth,
            nodes: nodes,
            out: &output
        )
        rects = output
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
                    rect: childRect.insetBy(dx: 1, dy: 1),
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

    private func color(for node: NativeNode, depth: Int, darkMode: Bool) -> NSColor {
        switch node.kind {
        case .file:
            let ext = fileExtension(for: node.name)
            let hue = CGFloat(stableHash(ext) % 360) / 360.0
            let saturation: CGFloat = darkMode ? 0.78 : 0.68
            let brightness: CGFloat = darkMode ? 0.86 : 0.72
            return NSColor(calibratedHue: hue, saturation: saturation, brightness: brightness, alpha: 0.95)

        case .directory:
            let hue = CGFloat(stableHash(node.name) % 360) / 360.0
            let saturation: CGFloat = darkMode ? 0.12 : 0.10
            let brightness: CGFloat = darkMode
                ? min(0.43, 0.30 + CGFloat(depth) * 0.015)
                : max(0.78, 0.93 - CGFloat(depth) * 0.015)
            return NSColor(calibratedHue: hue, saturation: saturation, brightness: brightness, alpha: 0.95)

        case .collapsedDirectory:
            return darkMode
                ? NSColor(calibratedRed: 0.56, green: 0.46, blue: 0.22, alpha: 0.96)
                : NSColor(calibratedRed: 0.84, green: 0.72, blue: 0.44, alpha: 0.96)
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
