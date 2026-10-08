import AppKit
import ClippaCore
import Observation

/// Runs the folder sync in the background: shortly after local changes,
/// and every half minute to pick up the other Macs' changes.
@MainActor
@Observable
final class SyncCoordinator {
    private(set) var lastSync: Date?
    private(set) var lastError: String?
    private(set) var otherDevices: [String] = []
    private(set) var isSyncing = false
    private(set) var waitingForFiles = false

    @ObservationIgnored private let store: ClippaStore
    @ObservationIgnored private var engine: SyncEngine?
    @ObservationIgnored private let queue = DispatchQueue(label: "clippa.sync", qos: .utility)
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var pending: DispatchWorkItem?
    @ObservationIgnored var onImport: () -> Void = {}

    init(store: ClippaStore) {
        self.store = store
    }

    var mode: JournalMode { Pref.syncModeValue }

    /// Applies the current settings; call after they change.
    func configure() {
        let mode = Pref.syncModeValue
        store.journalMode = mode
        timer?.invalidate()
        Log.info("Sync: \(mode.rawValue)")
        guard mode != .off else {
            engine = nil
            Log.attempt("Sync: clearOutbox failed") { try store.clearOutbox() }
            Log.attempt("Sync: setMeta failed") { try store.setMeta("sync.configuration", nil) }
            otherDevices = []
            return
        }
        let folder = Pref.syncFolderURL
        engine = SyncEngine(store: store, root: folder, mode: mode, retention: Pref.keepHistoryValue)
        let configuration = "\(mode.rawValue)|\(folder.path)"
        if (try? store.meta("sync.configuration")) != configuration {
            // First sync with this mode or folder: send everything it covers.
            Log.attempt("Sync: clearOutbox failed") { try store.clearOutbox() }
            Log.attempt("Sync: enqueueFullExport failed") { try store.enqueueFullExport() }
            Log.attempt("Sync: setMeta failed") { try store.setMeta("sync.configuration", configuration) }
        }
        let timer = Timer(timeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.syncNow() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        syncNow()
    }

    /// Local data changed: sync in a few seconds (changes are batched).
    func scheduleSoon() {
        guard engine != nil else { return }
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.syncNow() }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: work)
    }

    func syncNow() {
        guard let engine, !isSyncing else { return }
        engine.retention = Pref.keepHistoryValue
        isSyncing = true
        queue.async { [weak self] in
            let result = Result { try engine.sync() }
            let devices = engine.otherDevices().map(\.name)
            DispatchQueue.main.async {
                guard let self else { return }
                self.isSyncing = false
                self.otherDevices = devices
                switch result {
                case .success(let report):
                    if self.lastError != nil { Log.info("Sync: working again") }
                    if report.exported > 0 || report.imported > 0 {
                        Log.info("Sync: \(report.exported) changes sent, \(report.imported) received, \(devices.count) other Macs")
                    }
                    self.lastSync = Date()
                    self.lastError = nil
                    self.waitingForFiles = report.waitingForFiles
                    if report.imported > 0 { self.onImport() }
                case .failure(let error):
                    // Logged once per error, not every 30 seconds.
                    if self.lastError != error.localizedDescription { Log.error("Sync failed", error) }
                    self.lastError = error.localizedDescription
                }
            }
        }
    }

    /// Removes this Mac's files from the sync folder (other Macs keep what
    /// they already received).
    func removeThisMacFromFolder() {
        let engine = SyncEngine(store: store, root: Pref.syncFolderURL, mode: .off, retention: Pref.keepHistoryValue)
        queue.async {
            Log.attempt("Sync: removeThisDevice failed") { try engine.removeThisDevice() }
        }
    }
}
