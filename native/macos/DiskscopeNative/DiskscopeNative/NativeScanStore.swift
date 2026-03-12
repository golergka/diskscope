import Foundation
import SwiftUI

private let kEventBatch = UInt32(DS_EVENT_BATCH)
private let kEventProgress = UInt32(DS_EVENT_PROGRESS)
private let kEventCompleted = UInt32(DS_EVENT_COMPLETED)
private let kEventCancelled = UInt32(DS_EVENT_CANCELLED)
private let kEventError = UInt32(DS_EVENT_ERROR)

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

final class NativeScanStore: ObservableObject {
    @Published var availableDrives: [String]
    @Published var selectedDrive: String
    @Published var useCustomPath: Bool = false
    @Published var customPath: String = "/"
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

    private var session: DsSessionHandleRef?
    private var pendingPatches: [IncomingPatch] = []
    private var pendingPatchCursor = 0
    private var patchFlushScheduled = false
    private let patchFlushIntervalSeconds: TimeInterval = 0.1
    private let patchFlushTimeBudgetSeconds: TimeInterval = 0.012
    private var pendingTerminalEvent: PendingTerminalEvent?

    init(launch: NativeLaunchOptions) {
        let discoveredDrives = NativeScanStore.discoverDrives()
        availableDrives = discoveredDrives
        selectedDrive = discoveredDrives.first ?? "/"

        if let override = launch.pathOverride, !override.isEmpty {
            customPath = override
            useCustomPath = true
            if availableDrives.contains(override) {
                selectedDrive = override
                useCustomPath = false
            }
        }

        resetModel(path: activePath)

        if launch.autoStart {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                self.startScan()
            }
        }
    }

    deinit {
        teardownSession(cancel: true, synchronous: true)
    }

    var activePath: String {
        let source = useCustomPath ? customPath : selectedDrive
        return source.isEmpty ? "/" : source
    }

    var scannedBytesLabel: String {
        NativeScanStore.humanBytes(progress.bytesSeen)
    }

    var targetBytesLabel: String {
        NativeScanStore.humanBytes(progress.targetBytes)
    }

    var progressFraction: Double {
        guard progress.targetBytes > 0 else {
            return 0
        }
        let scanned = min(progress.bytesSeen, progress.targetBytes)
        return Double(scanned) / Double(progress.targetBytes)
    }

    var exploredFraction: Double {
        guard progress.targetBytes > 0 else {
            return progress.bytesSeen > 0 ? 1.0 : 0.0
        }
        let scanned = min(progress.bytesSeen, progress.targetBytes)
        return Double(scanned) / Double(progress.targetBytes)
    }

    func startScan() {
        teardownSession(cancel: true, synchronous: true)

        let path = activePath
        let canonical = (path as NSString).expandingTildeInPath
        resetModel(path: canonical)
        scanState = .running
        statusLine = "Starting scan for \(canonical)..."

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
            return
        }

        session = handle
    }

    func cancelScan() {
        guard session != nil else {
            return
        }
        scanState = .cancelled
        statusLine = "Cancelling scan..."
        teardownSession(cancel: true, synchronous: false)
    }

    func rescan() {
        startScan()
    }

    func resetZoom() {
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
        guard nodes[nodeId] != nil else {
            return
        }
        selectedNodeId = nodeId
    }

    func zoom(to nodeId: UInt64) {
        guard nodes[nodeId] != nil else {
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
        if node.childrenState == .collapsedByThreshold {
            return "deferred"
        }
        if node.errorFlag {
            return "error"
        }
        return ""
    }

    func nodeLabel(_ node: NativeNode) -> String {
        let marker: String
        switch node.kind {
        case .directory:
            marker = "D"
        case .file:
            marker = "F"
        case .collapsedDirectory:
            marker = "C"
        }

        let sizeText: String
        switch node.sizeState {
        case .unknown:
            sizeText = "unknown"
        case .partial:
            if node.sizeBytes == 0 {
                sizeText = "estimating..."
            } else {
                sizeText = "\(NativeScanStore.humanBytes(node.sizeBytes)) (partial)"
            }
        case .final:
            sizeText = NativeScanStore.humanBytes(node.sizeBytes)
        }

        return "[\(marker)] \(node.name) (\(sizeText))"
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
            schedulePatchFlush()

        case .progress(let incoming):
            progress = incoming
            statusLine = "Scanning \(scannedBytesLabel) of \(targetBytesLabel)"

        case .completed:
            pendingTerminalEvent = .completed
            schedulePatchFlush()

        case .cancelled:
            pendingTerminalEvent = .cancelled
            schedulePatchFlush()

        case .error(let message):
            pendingTerminalEvent = .error(message)
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
        var appliedAnyPatch = false
        while pendingPatchCursor < pendingPatches.count {
            apply(patch: pendingPatches[pendingPatchCursor])
            pendingPatchCursor += 1
            appliedAnyPatch = true

            if CFAbsoluteTimeGetCurrent() - start >= patchFlushTimeBudgetSeconds {
                break
            }
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
                statusLine = "Scanning... \(nodes.count) nodes"
            }
        }

        if pendingPatchCursor < pendingPatches.count {
            schedulePatchFlush()
            return
        }

        pendingPatches.removeAll(keepingCapacity: true)
        pendingPatchCursor = 0
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
            statusLine = "Completed: \(scannedBytesLabel) scanned"
        case .cancelled:
            scanState = .cancelled
            statusLine = "Cancelled"
        case .error(let message):
            scanState = .failed(message)
            statusLine = message
        }

        teardownSession(cancel: false, synchronous: false)
    }

    private func apply(patch: IncomingPatch) {
        let existing = nodes[patch.id]
        let previousParent = existing?.parentId

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

        if let oldParent = previousParent, oldParent != patch.parentId, var parent = nodes[oldParent] {
            parent.children.removeAll { $0 == patch.id }
            nodes[oldParent] = parent
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

            if existing == nil || previousParent != patch.parentId {
                parent.children.append(patch.id)
            }
            nodes[parentId] = parent
        }
    }

    private func resetModel(path: String) {
        pendingPatches.removeAll(keepingCapacity: false)
        pendingPatchCursor = 0
        patchFlushScheduled = false
        pendingTerminalEvent = nil
        progress = NativeProgress()
        rootNodeId = 0
        selectedNodeId = 0
        zoomNodeId = 0
        expandedNodes = [0]
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

    private static func discoverDrives() -> [String] {
        var drives: [String] = ["/"]

        let keys: [URLResourceKey] = [.volumeNameKey, .isDirectoryKey]
        if let mounted = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: keys,
            options: [.skipHiddenVolumes]
        ) {
            for url in mounted {
                let path = url.path
                if !drives.contains(path) {
                    drives.append(path)
                }
            }
        }

        return drives
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
