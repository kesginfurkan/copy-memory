import AppKit
import ClipCore

/// Polls the general pasteboard and ships every new snapshot to the backend.
/// Snapshots that cannot be delivered (e.g. Docker is down) are kept in memory and retried.
@MainActor
final class ClipboardMonitor {
    private let pasteboard = NSPasteboard.general
    private let config: AgentConfig
    private let api: APIClient
    private var lastChangeCount: Int
    private var timer: Timer?
    private var pending: [Snapshot] = []
    private var nextRetry = Date.distantPast
    private static let maxPending = 100

    var isPaused = false

    init(config: AgentConfig, api: APIClient) {
        self.config = config
        self.api = api
        self.lastChangeCount = pasteboard.changeCount
    }

    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: config.pollInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    /// Called after we write to the pasteboard ourselves so it is not recorded again.
    func ignoreChange(_ changeCount: Int) {
        lastChangeCount = changeCount
    }

    private func tick() {
        retryPendingIfDue()
        let changeCount = pasteboard.changeCount
        guard changeCount != lastChangeCount else { return }
        lastChangeCount = changeCount
        guard !isPaused else { return }

        let types = Set((pasteboard.types ?? []).map(\.rawValue))
        let app = NSWorkspace.shared.frontmostApplication
        if SnapshotFilter.shouldIgnore(types: types, sourceBundleID: app?.bundleIdentifier, ignoredApps: config.ignoredApps) {
            return
        }
        let items = PasteboardIO.read(pasteboard)
        guard !items.isEmpty else { return }
        let snapshot = Snapshot(
            items: items,
            sourceApp: app?.bundleIdentifier,
            sourceAppName: app?.localizedName,
            thumbnailPNG: SnapshotFilter.wantsThumbnail(types: types) ? PasteboardIO.thumbnail(from: pasteboard) : nil
        )
        deliver(snapshot)
    }

    private func deliver(_ snapshot: Snapshot, isRetry: Bool = false) {
        Task {
            do {
                try await api.add(snapshot)
            } catch APIError.status(413) {
                log("skipped snapshot: too large (\(snapshot.totalBytes) bytes)")
            } catch APIError.status(let code) where (400..<500).contains(code) {
                log("backend rejected snapshot: HTTP \(code)")
            } catch {
                log("backend unreachable, queued (\(error.localizedDescription))")
                // keep oldest-first order so history ends up in the original sequence
                if isRetry { pending.insert(snapshot, at: 0) } else { pending.append(snapshot) }
                if pending.count > Self.maxPending { pending.removeFirst() }
                nextRetry = Date().addingTimeInterval(5)
            }
        }
    }

    private func retryPendingIfDue() {
        guard !pending.isEmpty, Date() >= nextRetry else { return }
        nextRetry = Date().addingTimeInterval(5)
        deliver(pending.removeFirst(), isRetry: true)
    }
}

func log(_ message: String) {
    let stamp = ISO8601DateFormatter().string(from: Date())
    FileHandle.standardError.write(Data("[\(stamp)] \(message)\n".utf8))
}
