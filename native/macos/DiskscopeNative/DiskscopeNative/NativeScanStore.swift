import AppKit
import Foundation
import os
import SwiftUI

private let kEventBatch = UInt32(DS_EVENT_BATCH)
private let kEventProgress = UInt32(DS_EVENT_PROGRESS)
private let kEventCompleted = UInt32(DS_EVENT_COMPLETED)
private let kEventCancelled = UInt32(DS_EVENT_CANCELLED)
private let kEventError = UInt32(DS_EVENT_ERROR)
private let kExpectedAbiVersion = UInt32(DS_FFI_ABI_VERSION)

private let kNodeDirectory = UInt8(DS_NODE_KIND_DIRECTORY)
private let kNodeFile = UInt8(DS_NODE_KIND_FILE)
private let kNodeCollapsedDirectory = UInt8(DS_NODE_KIND_COLLAPSED_DIRECTORY)

private let kSizeUnknown = UInt8(DS_SIZE_STATE_UNKNOWN)
private let kSizePartial = UInt8(DS_SIZE_STATE_PARTIAL)
private let kSizeFinal = UInt8(DS_SIZE_STATE_FINAL)

private let kChildrenUnknown = UInt8(DS_CHILDREN_STATE_UNKNOWN)
private let kChildrenPartial = UInt8(DS_CHILDREN_STATE_PARTIAL)
private let kChildrenFinal = UInt8(DS_CHILDREN_STATE_FINAL)
private let kChildrenCollapsed = UInt8(DS_CHILDREN_STATE_COLLAPSED_BY_THRESHOLD)

enum NativeDiagnostics {
    private static let logger = Logger(subsystem: "com.diskscope.native", category: "runtime")
    private static let enabledFlag = ProcessInfo.processInfo.environment["DISKSCOPE_NATIVE_TRACE"] == "1"

    static var enabled: Bool {
        enabledFlag
    }

    static func debug(_ message: String) {
        guard enabledFlag else {
            return
        }
        logger.debug("\(message, privacy: .public)")
    }

    static func info(_ message: String) {
        guard enabledFlag else {
            return
        }
        logger.info("\(message, privacy: .public)")
    }

    static func warning(_ message: String) {
        guard enabledFlag else {
            return
        }
        logger.warning("\(message, privacy: .public)")
    }

    static func slowPath(
        _ label: String,
        startedAt: CFAbsoluteTime,
        thresholdMs: Double = 16,
        details: String = ""
    ) {
        guard enabledFlag else {
            return
        }
        let elapsedMs = (CFAbsoluteTimeGetCurrent() - startedAt) * 1000
        guard elapsedMs >= thresholdMs else {
            return
        }
        let elapsedText = String(format: "%.2f", elapsedMs)
        if details.isEmpty {
            logger.warning("slow \(label, privacy: .public): \(elapsedText, privacy: .public) ms")
        } else {
            logger.warning(
                "slow \(label, privacy: .public): \(elapsedText, privacy: .public) ms (\(details, privacy: .public))"
            )
        }
    }
}

enum NativeNodeKind: UInt8 {
    case directory = 0
    case file = 1
    case collapsedDirectory = 2
}

enum NativeSizeState: UInt8 {
    case unknown = 0
    case partial = 1
    case final = 2
}

enum NativeChildrenState: UInt8 {
    case unknown = 0
    case partial = 1
    case final = 2
    case collapsedByThreshold = 3
}

enum NativeProfile: UInt32, CaseIterable, Identifiable {
    case conservative = 0
    case balanced = 1
    case aggressive = 2

    var id: UInt32 { rawValue }

    var title: String {
        switch self {
        case .conservative:
            return "Conservative"
        case .balanced:
            return "Balanced"
        case .aggressive:
            return "Aggressive"
        }
    }
}

enum NativeScanState: Equatable {
    case idle
    case running
    case completed
    case cancelled
    case failed(String)

    var label: String {
        switch self {
        case .idle:
            return "Idle"
        case .running:
            return "Scanning"
        case .completed:
            return "Completed"
        case .cancelled:
            return "Cancelled"
        case .failed:
            return "Failed"
        }
    }
}

enum NativeScreen: Equatable {
    case setup
    case results
}

enum NativeAppMode: Equatable {
    case choosingTarget
    case scanResults
}

struct NativeDriveInfo: Hashable, Identifiable {
    let path: String
    let displayName: String
    let totalBytes: UInt64?
    let usedBytes: UInt64?
    let freeBytes: UInt64?

    var id: String { path }
}

struct NativeRuntimeErrorEntry: Identifiable, Hashable {
    let id: UUID
    let timestamp: Date
    let message: String
}

struct NativeScanErrorEntry: Identifiable, Hashable {
    let id: String
    let kindLabel: String
    let location: String
    let detail: String
    let nodeId: UInt64?
}

struct NativeNode {
    var id: UInt64
    var parentId: UInt64?
    var name: String
    var kind: NativeNodeKind
    var sizeBytes: UInt64
    var sizeState: NativeSizeState
    var childrenState: NativeChildrenState
    var errorFlag: Bool
    var isHidden: Bool
    var isSymlink: Bool
    var children: [UInt64]
}

struct NativeProgress {
    var directoriesSeen: UInt64 = 0
    var filesSeen: UInt64 = 0
    var bytesSeen: UInt64 = 0
    var occupiedBytes: UInt64 = 0
    var totalBytes: UInt64 = 0
    var targetBytes: UInt64 = 0
    var queuedJobs: UInt64 = 0
    var activeWorkers: UInt64 = 0
    var elapsedMs: UInt64 = 0
}

struct NativeLaunchOptions {
    var autoStart: Bool = false
    var pathOverride: String?

    init(arguments: [String]) {
        var iterator = arguments.dropFirst().makeIterator()
        while let arg = iterator.next() {
            switch arg {
            case "--start":
                autoStart = true
            case "--path":
                pathOverride = iterator.next()
            default:
                continue
            }
        }
    }
}

private struct IncomingPatch {
    let id: UInt64
    let parentId: UInt64?
    let name: String
    let kind: NativeNodeKind
    let sizeBytes: UInt64
    let sizeState: NativeSizeState
    let childrenState: NativeChildrenState
    let errorFlag: Bool
    let isHidden: Bool
    let isSymlink: Bool
}

private enum IncomingEvent {
    case batch([IncomingPatch])
    case progress(NativeProgress)
    case completed
    case cancelled
    case error(String)
}

private enum PendingTerminalEvent {
    case completed
    case cancelled
    case error(String)
}

private let ffiEventCallback: DsScanEventCallback = { eventPtr, userData in
    guard let eventPtr, let userData else {
        return
    }
    let store = Unmanaged<NativeScanStore>.fromOpaque(userData).takeUnretainedValue()
    store.receive(event: eventPtr.pointee)
}

private final class DockProgressOverlayController {
    private final class ProgressTileView: NSView {
        var fraction: Double = 0 {
            didSet {
                needsDisplay = true
            }
        }

        override func draw(_ dirtyRect: NSRect) {
            super.draw(dirtyRect)
            guard let context = NSGraphicsContext.current?.cgContext else {
                return
            }

            let boundsRect = bounds
            if let iconImage = NSApp.applicationIconImage {
                iconImage.draw(in: boundsRect)
            } else {
                NSImage(named: NSImage.applicationIconName)?.draw(in: boundsRect)
            }

            let clamped = max(0, min(1, fraction))
            let horizontalInset = boundsRect.width * 0.12
            let barHeight = max(7, boundsRect.height * 0.075)
            let barRect = NSRect(
                x: horizontalInset,
                y: boundsRect.height * 0.09,
                width: boundsRect.width - horizontalInset * 2,
                height: barHeight
            )

            let trackPath = NSBezierPath(roundedRect: barRect, xRadius: barHeight / 2, yRadius: barHeight / 2)
            NSColor.black.withAlphaComponent(0.55).setFill()
            trackPath.fill()

            let fillWidth = max(2, barRect.width * clamped)
            let fillRect = NSRect(x: barRect.minX, y: barRect.minY, width: fillWidth, height: barRect.height)
            let fillPath = NSBezierPath(roundedRect: fillRect, xRadius: barHeight / 2, yRadius: barHeight / 2)
            NSColor.controlAccentColor.setFill()
            fillPath.fill()

            context.saveGState()
            NSColor.white.withAlphaComponent(0.35).setStroke()
            trackPath.lineWidth = 1
            trackPath.stroke()
            context.restoreGState()
        }
    }

    private var progressView: ProgressTileView?

    func setProgress(_ fraction: Double) {
        let clamped = max(0, min(1, fraction))
        let view = ensureProgressView()
        view.fraction = clamped
        if NSApp.dockTile.badgeLabel != nil {
            NSApp.dockTile.badgeLabel = nil
        }
        NSApp.dockTile.display()
    }

    func clear() {
        guard progressView != nil || NSApp.dockTile.contentView != nil || NSApp.dockTile.badgeLabel != nil else {
            return
        }
        progressView = nil
        NSApp.dockTile.contentView = nil
        NSApp.dockTile.badgeLabel = nil
        NSApp.dockTile.display()
    }

    private func ensureProgressView() -> ProgressTileView {
        if let progressView {
            progressView.frame = NSRect(origin: .zero, size: NSApp.dockTile.size)
            return progressView
        }

        let view = ProgressTileView(frame: NSRect(origin: .zero, size: NSApp.dockTile.size))
        view.wantsLayer = true
        progressView = view
        NSApp.dockTile.contentView = view
        return view
    }
}

final class NativeScanStore: ObservableObject {
    @Published var availableDrives: [NativeDriveInfo]
    @Published var selectedDrive: String
    @Published var useCustomPath: Bool = false
    @Published var customPath: String = "/"
    @Published var currentScreen: NativeScreen = .setup
    @Published private(set) var appMode: NativeAppMode = .choosingTarget
    @Published var scanState: NativeScanState = .idle
    @Published var statusLine: String = "Ready"
    @Published var progress: NativeProgress = NativeProgress()
    @Published var profile: NativeProfile = .balanced
    @Published var showAdvanced: Bool = false
    @Published var workerOverrideText: String = ""
    @Published var queueLimitText: String = "64"
    @Published var thresholdOverrideText: String = ""
    private(set) var nodes: [UInt64: NativeNode] = [:]
    @Published var rootNodeId: UInt64 = 0
    @Published var selectedNodeId: UInt64 = 0
    @Published var zoomNodeId: UInt64 = 0
    @Published var expandedNodes: Set<UInt64> = [0]
    @Published var modelVersion: UInt64 = 0
    @Published private(set) var pendingPatchBacklog: Int = 0
    @Published private(set) var errorNodeCount: Int = 0
    @Published private(set) var deferredNodeCount: Int = 0
    @Published private(set) var runtimeErrors: [NativeRuntimeErrorEntry] = []
    private var childOrderRevisions: [UInt64: UInt64] = [:]
    private var errorNodeIds: Set<UInt64> = []

    private var session: DsSessionHandleRef?
    private var pendingPatches: [IncomingPatch] = []
    private var pendingPatchCursor = 0
    private var patchFlushScheduled = false
    private let patchFlushIntervalSeconds: TimeInterval = 0.1
    private let patchFlushTimeBudgetSeconds: TimeInterval = 0.012
    private let maxRuntimeErrorEntries = 200
    private var pendingTerminalEvent: PendingTerminalEvent?
    private var ffiAbiCompatible = true
    private let dockProgress = DockProgressOverlayController()

    init(launch: NativeLaunchOptions) {
        let runtimeAbi = ds_ffi_abi_version()
        ffiAbiCompatible = runtimeAbi == kExpectedAbiVersion

        let discoveredDrives = NativeScanStore.discoverDrives()
        availableDrives = discoveredDrives
        selectedDrive = discoveredDrives.first?.path ?? "/"

        if let override = launch.pathOverride, !override.isEmpty {
            customPath = override
            useCustomPath = true
            if availableDrives.contains(where: { $0.path == override }) {
                selectedDrive = override
                useCustomPath = false
            }
        }

        resetModel(path: activePath)

        if !ffiAbiCompatible {
            scanState = .failed("FFI ABI mismatch")
            statusLine = "FFI ABI mismatch: native=\(runtimeAbi), expected=\(kExpectedAbiVersion)"
            NativeDiagnostics.warning("ffi_abi_mismatch native=\(runtimeAbi) expected=\(kExpectedAbiVersion)")
            appendRuntimeError(statusLine)
        }

        if launch.autoStart {
            appMode = .scanResults
            currentScreen = .results
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                self.startScan()
            }
        } else {
            appMode = .choosingTarget
            currentScreen = .setup
        }
    }

    deinit {
        dockProgress.clear()
        teardownSession(cancel: true, synchronous: true)
    }

    var activePath: String {
        let source = useCustomPath ? customPath : selectedDrive
        return source.isEmpty ? "/" : source
    }

    var selectedDriveInfo: NativeDriveInfo? {
        availableDrives.first(where: { $0.path == selectedDrive })
    }

    var canStartScan: Bool {
        scanState != .running && ffiAbiCompatible
    }

    var canCancelScan: Bool {
        scanState == .running && session != nil
    }

    var canRescan: Bool {
        scanState != .running && ffiAbiCompatible
    }

    var canResetZoom: Bool {
        zoomNodeId != rootNodeId
    }

    var canShowResultsScreen: Bool {
        appMode == .scanResults
    }

    var totalErrorCount: Int {
        errorNodeCount + runtimeErrors.count
    }

    var scannedBytesLabel: String {
        NativeScanStore.humanBytes(progress.bytesSeen)
    }

    var targetBytesLabel: String {
        NativeScanStore.humanBytes(progress.targetBytes)
    }

    var occupiedBytesLabel: String {
        NativeScanStore.humanBytes(progress.occupiedBytes)
    }

    var totalBytesLabel: String {
        NativeScanStore.humanBytes(progress.totalBytes)
    }

    var progressFraction: Double {
        let denominator = progress.occupiedBytes > 0 ? progress.occupiedBytes : progress.targetBytes
        guard denominator > 0 else {
            return 0
        }
        let scanned = min(progress.bytesSeen, denominator)
        return Double(scanned) / Double(denominator)
    }

    var exploredFraction: Double {
        let denominator = progress.occupiedBytes > 0 ? progress.occupiedBytes : progress.targetBytes
        guard denominator > 0 else {
            return progress.bytesSeen > 0 ? 1.0 : 0.0
        }
        let scanned = min(progress.bytesSeen, denominator)
        return Double(scanned) / Double(denominator)
    }

    func showSetupScreen() {
        appMode = .choosingTarget
        currentScreen = .setup
    }

    func showResultsScreen() {
        appMode = .scanResults
        currentScreen = .results
    }

    func showResultsScreenIfAvailable() {
        guard appMode == .scanResults else {
            return
        }
        currentScreen = .results
    }

    func handleDockReopen() {
        currentScreen = appMode == .choosingTarget ? .setup : .results
    }

    func changeTarget() {
        showSetupScreen()
    }

    func setDriveTarget(path: String) {
        selectedDrive = path
        useCustomPath = false
        showSetupScreen()
    }

    func setCustomTarget(path: String) {
        customPath = path
        useCustomPath = true
        showSetupScreen()
    }

    func selectFolderFromDialog() {
        let panel = NSOpenPanel()
        panel.title = "Select Folder to Scan"
        panel.prompt = "Choose"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.directoryURL = URL(fileURLWithPath: activePath)
        if panel.runModal() == .OK, let url = panel.url {
            setCustomTarget(path: url.path)
        }
    }

    func driveTotalLabel(for drive: NativeDriveInfo) -> String {
        guard let totalBytes = drive.totalBytes else {
            return "Unavailable"
        }
        return NativeScanStore.humanBytes(totalBytes)
    }

    func driveUsedLabel(for drive: NativeDriveInfo) -> String {
        guard let usedBytes = drive.usedBytes else {
            return "Unavailable"
        }
        return NativeScanStore.humanBytes(usedBytes)
    }

    func driveFreeLabel(for drive: NativeDriveInfo) -> String {
        guard let freeBytes = drive.freeBytes else {
            return "Unavailable"
        }
        return NativeScanStore.humanBytes(freeBytes)
    }

    func startScan() {
        showResultsScreen()
        guard ffiAbiCompatible else {
            scanState = .failed("FFI ABI mismatch")
            statusLine = "FFI ABI mismatch. Rebuild native app + Rust FFI together."
            updateDockTileProgress()
            return
        }

        teardownSession(cancel: true, synchronous: true)

        let path = activePath
        let canonical = (path as NSString).expandingTildeInPath
        NativeDiagnostics.info("start_scan path=\(canonical)")
        resetModel(path: canonical)
        scanState = .running
        statusLine = "Starting scan for \(canonical)..."
        updateDockTileProgress()

        var request = DsScanRequest(
            root_path: nil,
            include_hidden: 0,
            follow_symlinks: 0,
            one_filesystem: 1,
            profile: profile.rawValue,
            worker_override: UInt32(parsedPositiveInt(workerOverrideText) ?? 0),
            queue_limit: UInt32(parsedPositiveInt(queueLimitText) ?? 64),
            threshold_override: parsedPositiveUInt64(thresholdOverrideText) ?? 0
        )

        let handle: DsSessionHandleRef? = canonical.withCString { cstr in
            request.root_path = cstr
            return ds_scan_start_ref(
                &request,
                ffiEventCallback,
                Unmanaged.passUnretained(self).toOpaque()
            )
        }

        guard let handle else {
            scanState = .failed("Unable to start native scan session")
            statusLine = "Failed to start scan"
            NativeDiagnostics.warning("scan_start_failed path=\(canonical)")
            updateDockTileProgress()
            return
        }

        session = handle
        NativeDiagnostics.info("scan_session_started path=\(canonical)")
    }

    func cancelScan() {
        guard session != nil else {
            return
        }
        scanState = .cancelled
        statusLine = "Cancelling scan..."
        NativeDiagnostics.info("scan_cancel_requested")
        updateDockTileProgress()
        teardownSession(cancel: true, synchronous: false)
    }

    func rescan() {
        startScan()
    }

    func resetZoom() {
        guard zoomNodeId != rootNodeId else {
            return
        }
        zoomNodeId = rootNodeId
    }

    func zoomToParent() {
        guard zoomNodeId != rootNodeId else {
            return
        }
        guard let parentId = nodes[zoomNodeId]?.parentId else {
            zoomNodeId = rootNodeId
            selectedNodeId = rootNodeId
            return
        }

        zoomNodeId = parentId
        selectedNodeId = parentId
        expandedNodes.insert(parentId)
    }

    func select(nodeId: UInt64) {
        guard nodes[nodeId] != nil, selectedNodeId != nodeId else {
            return
        }
        selectedNodeId = nodeId
    }

    func zoom(to nodeId: UInt64) {
        guard nodes[nodeId] != nil else {
            return
        }
        if zoomNodeId == nodeId, expandedNodes.contains(nodeId) {
            return
        }
        zoomNodeId = nodeId
        expandedNodes.insert(nodeId)
    }

    func toggleExpanded(nodeId: UInt64) {
        if expandedNodes.contains(nodeId) {
            expandedNodes.remove(nodeId)
        } else {
            expandedNodes.insert(nodeId)
        }
    }

    func setExpanded(nodeId: UInt64, expanded: Bool) {
        if expanded {
            if expandedNodes.contains(nodeId) {
                return
            }
            expandedNodes.insert(nodeId)
        } else {
            if !expandedNodes.contains(nodeId) {
                return
            }
            expandedNodes.remove(nodeId)
        }
    }

    func node(_ nodeId: UInt64) -> NativeNode? {
        nodes[nodeId]
    }

    func sortedChildren(of nodeId: UInt64) -> [UInt64] {
        guard let children = nodes[nodeId]?.children else {
            return []
        }

        return children.sorted { left, right in
            let leftSize = nodes[left]?.sizeBytes ?? 0
            let rightSize = nodes[right]?.sizeBytes ?? 0
            if leftSize == rightSize {
                return (nodes[left]?.name ?? "") < (nodes[right]?.name ?? "")
            }
            return leftSize > rightSize
        }
    }

    func childOrderRevision(of nodeId: UInt64) -> UInt64 {
        childOrderRevisions[nodeId] ?? 0
    }

    func path(for nodeId: UInt64) -> String {
        guard nodes[nodeId] != nil else {
            return activePath
        }

        var names: [String] = []
        var cursor: UInt64? = nodeId
        while let id = cursor, let node = nodes[id] {
            names.append(node.name)
            cursor = node.parentId
        }

        names.reverse()
        if names.isEmpty {
            return activePath
        }

        var path = URL(fileURLWithPath: activePath)
        for segment in names.dropFirst() where !segment.isEmpty {
            path.appendPathComponent(segment)
        }
        return path.path
    }

    func isExpandable(_ node: NativeNode) -> Bool {
        node.kind == .directory && !node.children.isEmpty && node.childrenState != .collapsedByThreshold
    }

    func nodeBadge(_ node: NativeNode) -> String {
        if node.errorFlag {
            return "Error"
        }
        if node.childrenState == .collapsedByThreshold {
            return "Deferred"
        }
        return ""
    }

    func nodeLabel(_ node: NativeNode) -> String {
        node.name
    }

    func nodeSizeLabel(_ node: NativeNode) -> String {
        switch node.sizeState {
        case .unknown:
            return "Scanning..."
        case .partial:
            if node.sizeBytes == 0 {
                return "Scanning..."
            } else {
                return "\(NativeScanStore.humanBytes(node.sizeBytes)) ~"
            }
        case .final:
            return NativeScanStore.humanBytes(node.sizeBytes)
        }
    }

    func errorEntries() -> [NativeScanErrorEntry] {
        var nodeEntries: [NativeScanErrorEntry] = errorNodeIds.compactMap { nodeId in
            guard let node = nodes[nodeId] else {
                return nil
            }
            let detail: String
            switch node.kind {
            case .directory, .collapsedDirectory:
                detail = "Directory could not be fully read (permission denied or read error)."
            case .file:
                detail = "File metadata could not be fully read (permission denied or read error)."
            }
            return NativeScanErrorEntry(
                id: "node-\(nodeId)",
                kindLabel: "Node",
                location: path(for: nodeId),
                detail: detail,
                nodeId: nodeId
            )
        }
        nodeEntries.sort { lhs, rhs in
            lhs.location.localizedCaseInsensitiveCompare(rhs.location) == .orderedAscending
        }

        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .medium
        let runtimeEntries: [NativeScanErrorEntry] = runtimeErrors.reversed().map { runtime in
            NativeScanErrorEntry(
                id: "runtime-\(runtime.id.uuidString)",
                kindLabel: "Runtime",
                location: formatter.string(from: runtime.timestamp),
                detail: runtime.message,
                nodeId: nil
            )
        }

        return runtimeEntries + nodeEntries
    }

    func focusOnErrorNode(_ nodeId: UInt64) {
        guard nodes[nodeId] != nil else {
            return
        }
        showResultsScreen()
        var cursor: UInt64? = nodeId
        while let id = cursor {
            expandedNodes.insert(id)
            cursor = nodes[id]?.parentId
        }
        selectedNodeId = nodeId
    }

    func receive(event: DsScanEvent) {
        let decoded = decode(event: event)
        DispatchQueue.main.async {
            self.apply(decoded: decoded)
        }
    }

    private func decode(event: DsScanEvent) -> IncomingEvent {
        switch event.kind {
        case kEventBatch:
            return .batch(decodePatches(event: event))
        case kEventProgress:
            return .progress(NativeProgress(
                directoriesSeen: event.progress.directories_seen,
                filesSeen: event.progress.files_seen,
                bytesSeen: event.progress.bytes_seen,
                occupiedBytes: event.progress.occupied_bytes,
                totalBytes: event.progress.total_bytes,
                targetBytes: event.progress.target_bytes,
                queuedJobs: event.progress.queued_jobs,
                activeWorkers: event.progress.active_workers,
                elapsedMs: event.progress.elapsed_ms
            ))
        case kEventCompleted:
            return .completed
        case kEventCancelled:
            return .cancelled
        case kEventError:
            return .error(decodeMessage(event: event))
        default:
            return .error("Unknown event kind: \(event.kind)")
        }
    }

    private func decodePatches(event: DsScanEvent) -> [IncomingPatch] {
        guard event.patch_count > 0, let patchesPtr = event.patches_ptr else {
            return []
        }

        let patches = UnsafeBufferPointer(start: patchesPtr, count: Int(event.patch_count))
        let stringBytes: [UInt8]
        if event.string_table_len > 0, let tablePtr = event.string_table_ptr {
            stringBytes = Array(UnsafeBufferPointer(start: tablePtr, count: Int(event.string_table_len)))
        } else {
            stringBytes = []
        }

        var out: [IncomingPatch] = []
        out.reserveCapacity(Int(event.patch_count))

        for patch in patches {
            let start = Int(patch.name_offset)
            let end = start + Int(patch.name_len)
            let name: String
            if start >= 0, end <= stringBytes.count, start <= end {
                name = String(decoding: stringBytes[start..<end], as: UTF8.self)
            } else {
                name = ""
            }

            let kind = decodeKind(raw: patch.kind)
            let sizeState = decodeSizeState(raw: patch.size_state)
            let childrenState = decodeChildrenState(raw: patch.children_state)

            out.append(IncomingPatch(
                id: patch.id,
                parentId: patch.parent_present == 0 ? nil : patch.parent_id,
                name: name,
                kind: kind,
                sizeBytes: patch.size_bytes,
                sizeState: sizeState,
                childrenState: childrenState,
                errorFlag: patch.error_flag != 0,
                isHidden: patch.is_hidden != 0,
                isSymlink: patch.is_symlink != 0
            ))
        }

        return out
    }

    private func decodeMessage(event: DsScanEvent) -> String {
        guard event.message_len > 0, let messagePtr = event.message_ptr else {
            return "Unknown native scan error"
        }
        let bytes = UnsafeBufferPointer(start: messagePtr, count: Int(event.message_len))
        return String(decoding: bytes, as: UTF8.self)
    }

    private func apply(decoded: IncomingEvent) {
        switch decoded {
        case .batch(let patches):
            pendingPatches.append(contentsOf: patches)
            refreshPendingPatchBacklog()
            schedulePatchFlush()

        case .progress(let incoming):
            progress = incoming
            statusLine = "Scanning \(scannedBytesLabel) of \(occupiedBytesLabel) occupied"
            updateDockTileProgress()

        case .completed:
            pendingTerminalEvent = .completed
            NativeDiagnostics.info("scan_completed_event")
            schedulePatchFlush()

        case .cancelled:
            pendingTerminalEvent = .cancelled
            NativeDiagnostics.info("scan_cancelled_event")
            schedulePatchFlush()

        case .error(let message):
            pendingTerminalEvent = .error(message)
            appendRuntimeError(message)
            NativeDiagnostics.warning("scan_error_event message=\(message)")
            schedulePatchFlush()
        }
    }

    private func schedulePatchFlush() {
        guard !patchFlushScheduled else {
            return
        }
        patchFlushScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + patchFlushIntervalSeconds) { [weak self] in
            self?.flushPendingPatches()
        }
    }

    private func flushPendingPatches() {
        patchFlushScheduled = false
        guard pendingPatchCursor < pendingPatches.count || pendingTerminalEvent != nil else {
            return
        }

        let start = CFAbsoluteTimeGetCurrent()
        let startingCursor = pendingPatchCursor
        var appliedAnyPatch = false
        while pendingPatchCursor < pendingPatches.count {
            apply(patch: pendingPatches[pendingPatchCursor])
            pendingPatchCursor += 1
            appliedAnyPatch = true

            if CFAbsoluteTimeGetCurrent() - start >= patchFlushTimeBudgetSeconds {
                break
            }
        }

        if appliedAnyPatch && NativeDiagnostics.enabled {
            let applied = pendingPatchCursor - startingCursor
            let pending = max(0, pendingPatches.count - pendingPatchCursor)
            let details = "applied=\(applied) pending=\(pending) nodes=\(nodes.count)"
            NativeDiagnostics.slowPath(
                "patch_flush",
                startedAt: start,
                thresholdMs: 18,
                details: details
            )
        }

        if appliedAnyPatch {
            modelVersion &+= 1

            if nodes[selectedNodeId] == nil {
                selectedNodeId = rootNodeId
            }
            if nodes[zoomNodeId] == nil {
                zoomNodeId = rootNodeId
            }

            if scanState == .running {
                statusLine = "Scanning \(scannedBytesLabel) of \(occupiedBytesLabel) occupied"
            }
        }

        refreshPendingPatchBacklog()

        if pendingPatchCursor < pendingPatches.count {
            schedulePatchFlush()
            return
        }

        pendingPatches.removeAll(keepingCapacity: true)
        pendingPatchCursor = 0
        refreshPendingPatchBacklog()
        finalizeTerminalIfNeeded()
    }

    private func finalizeTerminalIfNeeded() {
        guard let terminal = pendingTerminalEvent else {
            return
        }
        pendingTerminalEvent = nil

        switch terminal {
        case .completed:
            scanState = .completed
            if errorNodeCount > 0 {
                statusLine = "Completed with \(errorNodeCount) scan errors"
            } else {
                statusLine = "Completed: \(scannedBytesLabel) scanned"
            }
            NativeDiagnostics.info("scan_terminal completed scanned=\(progress.bytesSeen) target=\(progress.targetBytes)")
        case .cancelled:
            scanState = .cancelled
            statusLine = "Cancelled"
            NativeDiagnostics.info("scan_terminal cancelled")
        case .error(let message):
            scanState = .failed(message)
            statusLine = message
            NativeDiagnostics.warning("scan_terminal error=\(message)")
        }

        updateDockTileProgress()
        teardownSession(cancel: false, synchronous: false)
    }

    private func apply(patch: IncomingPatch) {
        let existing = nodes[patch.id]
        let previousParent = existing?.parentId
        let previousName = existing?.name
        let previousSize = existing?.sizeBytes
        let previousErrorFlag = existing?.errorFlag ?? false
        let previousDeferred = existing?.childrenState == .collapsedByThreshold

        var node = existing ?? NativeNode(
            id: patch.id,
            parentId: patch.parentId,
            name: patch.name,
            kind: patch.kind,
            sizeBytes: patch.sizeBytes,
            sizeState: patch.sizeState,
            childrenState: patch.childrenState,
            errorFlag: patch.errorFlag,
            isHidden: patch.isHidden,
            isSymlink: patch.isSymlink,
            children: []
        )

        node.parentId = patch.parentId
        node.name = patch.name
        node.kind = patch.kind
        node.sizeBytes = patch.sizeBytes
        node.sizeState = patch.sizeState
        node.childrenState = patch.childrenState
        node.errorFlag = patch.errorFlag
        node.isHidden = patch.isHidden
        node.isSymlink = patch.isSymlink
        nodes[patch.id] = node

        if previousErrorFlag != patch.errorFlag {
            if patch.errorFlag {
                errorNodeCount += 1
                errorNodeIds.insert(patch.id)
            } else {
                errorNodeCount = max(0, errorNodeCount - 1)
                errorNodeIds.remove(patch.id)
            }
        }

        let nowDeferred = patch.childrenState == .collapsedByThreshold
        if previousDeferred != nowDeferred {
            if nowDeferred {
                deferredNodeCount += 1
            } else {
                deferredNodeCount = max(0, deferredNodeCount - 1)
            }
        }

        if let oldParent = previousParent, oldParent != patch.parentId, var parent = nodes[oldParent] {
            let originalCount = parent.children.count
            parent.children.removeAll { $0 == patch.id }
            nodes[oldParent] = parent
            if parent.children.count != originalCount {
                bumpChildOrderRevision(for: oldParent)
            }
        }

        if let parentId = patch.parentId {
            var parent = nodes[parentId] ?? NativeNode(
                id: parentId,
                parentId: nil,
                name: "(loading)",
                kind: .directory,
                sizeBytes: 0,
                sizeState: .unknown,
                childrenState: .partial,
                errorFlag: false,
                isHidden: false,
                isSymlink: false,
                children: []
            )

            var addedToParent = false
            if existing == nil || previousParent != patch.parentId {
                parent.children.append(patch.id)
                addedToParent = true
            }
            nodes[parentId] = parent

            if addedToParent {
                bumpChildOrderRevision(for: parentId)
            } else if previousName != patch.name || previousSize != patch.sizeBytes {
                bumpChildOrderRevision(for: parentId)
            }
        }
    }

    private func resetModel(path: String) {
        pendingPatches.removeAll(keepingCapacity: false)
        pendingPatchCursor = 0
        patchFlushScheduled = false
        pendingTerminalEvent = nil
        progress = NativeProgress()
        pendingPatchBacklog = 0
        errorNodeCount = 0
        deferredNodeCount = 0
        runtimeErrors.removeAll(keepingCapacity: true)
        errorNodeIds.removeAll(keepingCapacity: true)
        rootNodeId = 0
        selectedNodeId = 0
        zoomNodeId = 0
        expandedNodes = [0]
        childOrderRevisions = [0: 0]
        modelVersion &+= 1

        let rootName = NativeScanStore.displayName(path: path)
        nodes = [
            0: NativeNode(
                id: 0,
                parentId: nil,
                name: rootName,
                kind: .directory,
                sizeBytes: 0,
                sizeState: .unknown,
                childrenState: .partial,
                errorFlag: false,
                isHidden: false,
                isSymlink: false,
                children: []
            )
        ]
    }

    private func refreshPendingPatchBacklog() {
        pendingPatchBacklog = max(0, pendingPatches.count - pendingPatchCursor)
    }

    private func appendRuntimeError(_ message: String) {
        let normalized = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else {
            return
        }
        runtimeErrors.append(NativeRuntimeErrorEntry(
            id: UUID(),
            timestamp: Date(),
            message: normalized
        ))
        let overflow = runtimeErrors.count - maxRuntimeErrorEntries
        if overflow > 0 {
            runtimeErrors.removeFirst(overflow)
        }
    }

    private func teardownSession(cancel: Bool, synchronous: Bool) {
        guard let handle = session else {
            return
        }

        session = nil
        let work = {
            if cancel {
                ds_scan_cancel_ref(handle)
            }
            ds_scan_free_ref(handle)
        }

        if synchronous {
            work()
        } else {
            DispatchQueue.global(qos: .utility).async(execute: work)
        }
    }

    private func bumpChildOrderRevision(for nodeId: UInt64) {
        childOrderRevisions[nodeId] = (childOrderRevisions[nodeId] ?? 0) &+ 1
    }

    private func updateDockTileProgress() {
        if scanState == .running {
            let denominator = progress.occupiedBytes > 0 ? progress.occupiedBytes : progress.targetBytes
            guard denominator > 0 else {
                dockProgress.setProgress(0)
                return
            }
            let scanned = min(progress.bytesSeen, denominator)
            let fraction = max(0.0, min(1.0, Double(scanned) / Double(denominator)))
            dockProgress.setProgress(fraction)
        } else {
            dockProgress.clear()
        }
    }

    private static func discoverDrives() -> [NativeDriveInfo] {
        let fileManager = FileManager.default
        let keys: [URLResourceKey] = [
            .volumeNameKey,
            .volumeLocalizedNameKey,
            .isDirectoryKey
        ]

        var seen: Set<String> = []
        var drives: [NativeDriveInfo] = []

        func appendDrive(path: String, url: URL?) {
            guard seen.insert(path).inserted else {
                return
            }

            let stats = fileSystemStats(path: path)
            let resolvedURL = url ?? URL(fileURLWithPath: path)
            let resource = try? resolvedURL.resourceValues(forKeys: Set(keys))
            let displayName = resource?.volumeLocalizedName
                ?? resource?.volumeName
                ?? displayName(path: path)

            drives.append(
                NativeDriveInfo(
                    path: path,
                    displayName: displayName,
                    totalBytes: stats.totalBytes,
                    usedBytes: stats.usedBytes,
                    freeBytes: stats.freeBytes
                )
            )
        }

        appendDrive(path: "/", url: URL(fileURLWithPath: "/"))

        if let mounted = fileManager.mountedVolumeURLs(
            includingResourceValuesForKeys: keys,
            options: [.skipHiddenVolumes]
        ) {
            for url in mounted.sorted(by: { $0.path < $1.path }) {
                appendDrive(path: url.path, url: url)
            }
        }

        drives.sort { lhs, rhs in
            if lhs.path == "/" {
                return true
            }
            if rhs.path == "/" {
                return false
            }
            return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
        }
        return drives
    }

    private static func fileSystemStats(path: String) -> (
        totalBytes: UInt64?,
        usedBytes: UInt64?,
        freeBytes: UInt64?
    ) {
        guard let attributes = try? FileManager.default.attributesOfFileSystem(forPath: path) else {
            return (nil, nil, nil)
        }

        let total = (attributes[.systemSize] as? NSNumber)?.uint64Value
        let free = (attributes[.systemFreeSize] as? NSNumber)?.uint64Value
        if let total, let free, total >= free {
            return (total, total - free, free)
        }
        return (total, nil, free)
    }

    private static func displayName(path: String) -> String {
        if path == "/" {
            return "/"
        }
        let name = URL(fileURLWithPath: path).lastPathComponent
        return name.isEmpty ? path : name
    }

    private static func humanBytes(_ bytes: UInt64) -> String {
        let units = ["B", "KiB", "MiB", "GiB", "TiB", "PiB"]
        if bytes < 1024 {
            return "\(bytes) B"
        }

        var value = Double(bytes)
        var idx = 0
        while value >= 1024 && idx < units.count - 1 {
            value /= 1024
            idx += 1
        }
        return String(format: "%.2f %@", value, units[idx])
    }

    private func parsedPositiveInt(_ text: String) -> Int? {
        guard let parsed = Int(text.trimmingCharacters(in: .whitespacesAndNewlines)), parsed > 0 else {
            return nil
        }
        return parsed
    }

    private func parsedPositiveUInt64(_ text: String) -> UInt64? {
        guard let parsed = UInt64(text.trimmingCharacters(in: .whitespacesAndNewlines)), parsed > 0 else {
            return nil
        }
        return parsed
    }

    private func decodeKind(raw: UInt8) -> NativeNodeKind {
        switch raw {
        case kNodeDirectory:
            return .directory
        case kNodeFile:
            return .file
        case kNodeCollapsedDirectory:
            return .collapsedDirectory
        default:
            return .file
        }
    }

    private func decodeSizeState(raw: UInt8) -> NativeSizeState {
        switch raw {
        case kSizeUnknown:
            return .unknown
        case kSizePartial:
            return .partial
        case kSizeFinal:
            return .final
        default:
            return .unknown
        }
    }

    private func decodeChildrenState(raw: UInt8) -> NativeChildrenState {
        switch raw {
        case kChildrenUnknown:
            return .unknown
        case kChildrenPartial:
            return .partial
        case kChildrenFinal:
            return .final
        case kChildrenCollapsed:
            return .collapsedByThreshold
        default:
            return .unknown
        }
    }
}
