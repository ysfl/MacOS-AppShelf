import AppKit
import Darwin
import Foundation

import AppShelfCore

/// Reads the resident memory of running processes. This is the same source Activity
/// Monitor uses for its real-memory column, and it needs no entitlement.
enum ProcessMemory {
    struct Sample {
        let executablePath: String
        let residentBytes: Int64
    }

    static func residentBytes(pid: Int32) -> Int64? {
        var info = proc_taskinfo()
        let expected = Int32(MemoryLayout<proc_taskinfo>.stride)
        let read = proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &info, expected)
        guard read == expected else { return nil }
        return Int64(info.pti_resident_size)
    }

    /// One pass over every running process, so a bundle can be charged for all of
    /// its helpers and XPC services instead of only its main process.
    static func snapshot() -> [Sample] {
        // Ask for nothing to learn the real count first: the previous fixed 4096 slot
        // buffer truncated silently on machines with more processes than that.
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return [] }

        var pids = [Int32](repeating: 0, count: Int(count))
        let written = proc_listallpids(&pids, count * Int32(MemoryLayout<Int32>.stride))
        guard written > 0 else { return [] }

        var samples: [Sample] = []
        samples.reserveCapacity(Int(written))
        var buffer = [CChar](repeating: 0, count: 4096)

        for pid in pids.prefix(Int(written)) {
            buffer.withUnsafeMutableBufferPointer { pointer in
                let length = proc_pidpath(pid, pointer.baseAddress, UInt32(pointer.count))
                guard length > 0, let base = pointer.baseAddress else { return }
                let executablePath = String(cString: base)
                guard let bytes = residentBytes(pid: pid) else { return }
                samples.append(Sample(executablePath: executablePath, residentBytes: bytes))
            }
        }
        return samples
    }
}

/// Usage numbers for exactly one app.
///
/// Each tile watches only its own instance, so a measurement landing for one app
/// repaints that tile's footer instead of every visible footer in the grid. Values
/// are pre-formatted so no formatting work happens inside `View.body`.
final class AppStat: ObservableObject {
    let path: String
    @Published private(set) var sizeText: String = ByteFormatter.placeholder
    @Published private(set) var memoryText: String = ByteFormatter.placeholder

    init(path: String) { self.path = path }

    func apply(size: Int64?, memory: Int64?) {
        let newSize = ByteFormatter.disk(size ?? 0)
        if newSize != sizeText { sizeText = newSize }
        let newMemory = ByteFormatter.memory(memory ?? 0)
        if newMemory != memoryText { memoryText = newMemory }
    }
}

/// Owns disk and memory usage for the app grid.
///
/// Disk usage covers the bundle plus the app's own Library data, because an app such
/// as WeChat keeps several gigabytes outside its `.app`. Results are cached per bundle
/// and invalidated when the bundle changes, and they are measured on a background queue.
final class AppMetrics: ObservableObject {
    /// Shared instance: the main window, the menu bar, and the settings window all read it.
    static let shared = AppMetrics()

    @Published private(set) var sizes: [String: Int64] = [:]
    @Published private(set) var memory: [String: Int64] = [:]

    private struct Record: Codable {
        let bytes: Int64
        let bundleModifiedAt: TimeInterval
    }

    private let queue: OperationQueue
    private let defaults: UserDefaults
    private var records: [String: Record] = [:]
    private var trackedApps: [AppItem] = []
    private var inFlight: Set<String> = []
    private var saveWork: DispatchWorkItem?
    /// One observable per app path, reused across scrolls so the tile footprint stays stable.
    private var stats: [String: AppStat] = [:]
    /// Guards the periodic process scan so ticks cannot pile up.
    private var memoryScanScheduled = false

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 3
        queue.qualityOfService = .utility
        self.queue = queue

        if let data = defaults.data(forKey: ShelfDefaults.sizeCache),
           let saved = try? JSONDecoder().decode([String: Record].self, from: data) {
            records = saved
            sizes = saved.mapValues(\.bytes)
        }
        for key in ShelfDefaults.retired {
            defaults.removeObject(forKey: key)
        }
    }

    /// The observable a single tile should watch. Only changed values are published.
    func stat(for path: String) -> AppStat {
        if let existing = stats[path] { return existing }
        let created = AppStat(path: path)
        created.apply(size: sizes[path], memory: memory[path])
        stats[path] = created
        return created
    }

    /// Remembers the known apps and forgets the numbers for anything that has gone away.
    ///
    /// The three dictionaries used to only ever grow, so an uninstalled app kept its
    /// measurement in memory *and* in the persisted cache forever, and every memory scan
    /// walked those dead entries.
    func register(_ apps: [AppItem]) {
        trackedApps = apps
        prune(to: Set(apps.map(\.path)))
    }

    private func prune(to live: Set<String>) {
        guard stats.keys.contains(where: { !live.contains($0) })
            || records.keys.contains(where: { !live.contains($0) }) else { return }
        stats = stats.filter { live.contains($0.key) }
        let removedRecords = records.filter { !live.contains($0.key) }
        guard !removedRecords.isEmpty else { return }
        records = records.filter { live.contains($0.key) }
        sizes = records.mapValues(\.bytes)
        scheduleSave()
    }

    /// Called when a tile appears. Cached apps cost nothing; everything else is
    /// measured off the main thread.
    func requestSizeIfNeeded(for app: AppItem) {
        guard sizes[app.path] == nil else { return }
        guard !inFlight.contains(app.path) else { return }
        inFlight.insert(app.path)

        let path = app.path
        let identifier = app.bundleIdentifier
        let name = app.name
        // Captured on the main thread; the worker must not read `records` concurrently.
        let cachedModifiedAt = records[path]?.bundleModifiedAt

        queue.addOperation { [weak self] in
            let modified = AppMetrics.bundleModificationDate(at: path)
            // Still current: skip the walk entirely, this is the common case.
            if let cachedModifiedAt, cachedModifiedAt == modified {
                DispatchQueue.main.async { self?.inFlight.remove(path) }
                return
            }

            let bytes = AppMetrics.totalSize(bundlePath: path, bundleIdentifier: identifier, displayName: name)
            DispatchQueue.main.async {
                self?.complete(path: path, bytes: bytes, bundleModifiedAt: modified)
            }
        }
    }

    /// Forces a fresh measurement, ignoring anything already cached.
    private func forceMeasure(_ app: AppItem) {
        inFlight.remove(app.path)
        sizes.removeValue(forKey: app.path)
        requestSizeIfNeeded(for: app)
    }

    /// Sums every process whose executable lives inside the given bundles.
    ///
    /// The scan walks every pid on the system, so it runs on the utility queue and only the
    /// comparison and publish happen on main.
    func updateMemory(forAppPaths paths: [String]) {
        guard !memoryScanScheduled else { return }
        memoryScanScheduled = true

        queue.addOperation { [weak self] in
            let samples = ProcessMemory.snapshot()
            var totals: [String: Int64] = [:]

            for path in paths {
                // The trailing slash keeps "...Mail.app" from also matching "...Mail Helper.app".
                let prefix = path + "/"
                var total: Int64 = 0
                for sample in samples where sample.executablePath.hasPrefix(prefix) {
                    total += sample.residentBytes
                }
                if total > 0 { totals[path] = total }
            }

            DispatchQueue.main.async {
                guard let self else { return }
                self.memoryScanScheduled = false
                guard totals != self.memory else { return }
                self.memory = totals
                // Apps that stopped running must fall back to "—", so every stat is refreshed.
                for (path, stat) in self.stats {
                    stat.apply(size: self.sizes[path], memory: totals[path])
                }
            }
        }
    }

    /// Drops the cached disk usage so the next pass measures everything again.
    func invalidateDiskCache() {
        queue.cancelAllOperations()
        inFlight.removeAll()
        records = [:]
        sizes = [:]
        defaults.removeObject(forKey: ShelfDefaults.sizeCache)
    }

    /// Re-measures every known app.
    ///
    /// A bundle walk measured 10–150 ms each on this machine, so a full pass over a few
    /// hundred apps runs for a while: it reports progress and can be cancelled.
    func recalculate() {
        invalidateDiskCache()
        trackedApps.forEach(forceMeasure)
    }

    /// Number of measurements still queued or in flight, for the settings panel.
    var pendingMeasurements: Int { queue.operationCount }

    func cancelRecalculation() {
        queue.cancelAllOperations()
        inFlight.removeAll()
    }

    private func complete(path: String, bytes: Int64, bundleModifiedAt: TimeInterval) {
        inFlight.remove(path)
        records[path] = Record(bytes: bytes, bundleModifiedAt: bundleModifiedAt)
        sizes[path] = bytes
        stats[path]?.apply(size: bytes, memory: memory[path])
        scheduleSave()
    }

    /// Writes are coalesced to avoid touching `UserDefaults` once per app.
    private func scheduleSave() {
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            guard let data = try? JSONEncoder().encode(self.records) else { return }
            self.defaults.set(data, forKey: ShelfDefaults.sizeCache)
        }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: work)
    }

    // MARK: - Measuring

    /// Bundle size plus the app's Library data, which is where most real storage goes.
    static func totalSize(bundlePath: String, bundleIdentifier: String?, displayName: String) -> Int64 {
        directorySize(at: bundlePath) + libraryDataSize(bundleIdentifier: bundleIdentifier, displayName: displayName)
    }

    /// Sums the allocated size of every file inside a directory tree.
    static func directorySize(at path: String) -> Int64 {
        let url = URL(fileURLWithPath: path)
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .fileAllocatedSizeKey, .fileSizeKey]
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: Array(keys),
            options: []
        ) else { return 0 }

        var total: Int64 = 0
        for case let itemURL as URL in enumerator {
            autoreleasepool {
                guard let values = try? itemURL.resourceValues(forKeys: keys),
                      values.isRegularFile == true else { return }
                total += fileBytes(values)
            }
        }
        return total
    }

    /// Data the app owns outside its bundle: support files, sandbox containers,
    /// group containers, caches, and saved state.
    ///
    /// Some apps file their data under a vendor folder instead of their bundle
    /// identifier, so "Google/Chrome" and "Code" are looked up by name as well.
    static func libraryDataSize(bundleIdentifier: String?, displayName: String = "") -> Int64 {
        guard let identifier = bundleIdentifier, !identifier.isEmpty else { return 0 }

        let home = FileManager.default.homeDirectoryForCurrentUser
        // A set keeps a folder that matches two patterns from being counted twice.
        var paths: Set<String> = [
            "\(home.path)/Library/Application Support/\(identifier)",
            "\(home.path)/Library/Containers/\(identifier)",
            "\(home.path)/Library/Caches/\(identifier)",
            "\(home.path)/Library/HTTPStorages/\(identifier)",
            "\(home.path)/Library/Saved Application State/\(identifier).savedState",
            "/Library/Application Support/\(identifier)",
            "/Library/Caches/\(identifier)"
        ]

        if !displayName.isEmpty {
            let support = "\(home.path)/Library/Application Support"
            paths.insert("\(support)/\(displayName)")

            let components = identifier.split(separator: ".").map(String.init)
            guard components.count >= 3 else {
                return Self.totalSize(of: paths)
            }

            // com.google.Chrome stores its profile in "Google/Chrome" rather than under
            // its own identifier, so a few spellings of that folder are tried.
            let vendor = Self.capitalized(components[1])
            let tail = components[components.count - 1]
            paths.insert("\(support)/\(vendor)/\(displayName)")
            paths.insert("\(support)/\(vendor)/\(tail)")
            paths.insert("\(support)/\(vendor)/\(Self.capitalized(tail))")

            if displayName.localizedCaseInsensitiveContains(vendor) {
                let remainder = displayName
                    .replacingOccurrences(of: vendor, with: "", options: [.caseInsensitive])
                    .trimmingCharacters(in: .whitespaces)
                if !remainder.isEmpty {
                    paths.insert("\(support)/\(vendor)/\(remainder)")
                }
            }
        }

        // Group containers carry the team id as a prefix, so they are matched by suffix.
        let groupContainers = "\(home.path)/Library/Group Containers"
        if let entries = try? FileManager.default.contentsOfDirectory(atPath: groupContainers) {
            let suffix = ".\(identifier)"
            for entry in entries where entry.hasSuffix(suffix) {
                paths.insert("\(groupContainers)/\(entry)")
            }
        }

        return Self.totalSize(of: paths)
    }

    private static func totalSize(of paths: Set<String>) -> Int64 {
        var total: Int64 = 0
        for path in paths {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else { continue }
            total += isDirectory.boolValue
                ? directorySize(at: path)
                : (fileSize(at: URL(fileURLWithPath: path)) ?? 0)
        }
        return total
    }

    private static func capitalized(_ text: String) -> String {
        guard let first = text.first else { return text }
        return String(first).uppercased() + text.dropFirst()
    }

    private static func fileBytes(_ values: URLResourceValues) -> Int64 {
        if let allocated = values.fileAllocatedSize, allocated > 0 { return Int64(allocated) }
        return Int64(values.fileSize ?? 0)
    }

    private static func fileSize(at url: URL) -> Int64? {
        guard let values = try? url.resourceValues(forKeys: [.fileAllocatedSizeKey, .fileSizeKey]) else { return nil }
        return fileBytes(values)
    }

    /// Used to decide whether a cached measurement is still valid.
    static func bundleModificationDate(at path: String) -> TimeInterval {
        let url = URL(fileURLWithPath: path)
        let values = try? url.resourceValues(forKeys: [.contentModificationDateKey])
        return values?.contentModificationDate?.timeIntervalSince1970 ?? 0
    }
}
