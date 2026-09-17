import AppKit
import Darwin
import Foundation

/// Human readable byte counts for the app cards.
enum ByteFormatter {
    /// Disk usage reads like Finder: "1.2 GB", "256 MB", "512 KB".
    static func disk(_ bytes: Int64) -> String {
        guard bytes > 0 else { return "—" }
        let gigabytes = Double(bytes) / 1_073_741_824
        if gigabytes >= 1 { return String(format: "%.1f GB", gigabytes) }
        let megabytes = Double(bytes) / 1_048_576
        if megabytes >= 1 { return String(format: "%.0f MB", megabytes) }
        return String(format: "%.0f KB", Double(bytes) / 1024)
    }

    /// Memory usage is shown in the same shape, e.g. "1.2 G" or "512 M".
    static func memory(_ bytes: Int64) -> String {
        guard bytes > 0 else { return "—" }
        let gigabytes = Double(bytes) / 1_073_741_824
        if gigabytes >= 1 { return String(format: "%.1f G", gigabytes) }
        let megabytes = Double(bytes) / 1_048_576
        if megabytes >= 1 { return String(format: "%.0f M", megabytes) }
        return String(format: "%.0f K", Double(bytes) / 1024)
    }
}

/// Reads the resident memory of a process. This is the same source Activity Monitor uses
/// for its "Memory" column, and it does not require any entitlement.
enum ProcessMemory {
    static func residentBytes(pid: Int32) -> Int64? {
        var info = proc_taskinfo()
        let expected = Int32(MemoryLayout<proc_taskinfo>.stride)
        let read = proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &info, expected)
        guard read == expected else { return nil }
        return Int64(info.pti_resident_size)
    }
}

/// Owns disk and memory usage for the app grid.
///
/// Disk usage is measured on a background queue because walking a large bundle can take
/// a moment; results are cached in `UserDefaults` so the next launch shows them instantly.
final class AppMetrics: ObservableObject {
    /// Shared instance: the main window, the menu bar, and the settings window all read it.
    static let shared = AppMetrics()

    @Published private(set) var sizes: [String: Int64] = [:]
    @Published private(set) var memory: [String: Int64] = [:]

    private static let cacheKey = "AppShelf.sizeCache.v1"

    private let queue: OperationQueue
    private let defaults: UserDefaults
    private var inFlight: Set<String> = []
    private var trackedPaths: [String] = []
    private var saveWork: DispatchWorkItem?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 3
        queue.qualityOfService = .utility
        self.queue = queue
        if let cached = defaults.dictionary(forKey: Self.cacheKey) as? [String: Int64] {
            sizes = cached
        }
    }

    func sizeText(for path: String) -> String {
        ByteFormatter.disk(sizes[path] ?? 0)
    }

    func memoryText(for path: String) -> String {
        ByteFormatter.memory(memory[path] ?? 0)
    }

    /// Schedules a background measurement for every path that has no value yet.
    func measure(paths: [String]) {
        trackedPaths = paths
        for path in paths where sizes[path] == nil && !inFlight.contains(path) {
            inFlight.insert(path)
            queue.addOperation { [weak self] in
                let bytes = AppMetrics.directorySize(at: path)
                DispatchQueue.main.async {
                    self?.complete(path: path, bytes: bytes)
                }
            }
        }
    }

    /// Replaces the memory snapshot with the currently running processes.
    func updateMemory(_ processes: [(path: String, pid: Int32)]) {
        var updated: [String: Int64] = [:]
        updated.reserveCapacity(processes.count)
        for process in processes {
            if let bytes = ProcessMemory.residentBytes(pid: process.pid), bytes > 0 {
                updated[process.path] = bytes
            }
        }
        memory = updated
    }

    /// Drops the cached disk usage so the next pass measures every bundle again.
    func invalidateDiskCache() {
        queue.cancelAllOperations()
        inFlight.removeAll()
        sizes = [:]
        defaults.removeObject(forKey: Self.cacheKey)
    }

    /// Clears the cache and measures every known bundle again.
    func recalculate() {
        invalidateDiskCache()
        measure(paths: trackedPaths)
    }

    private func complete(path: String, bytes: Int64) {
        inFlight.remove(path)
        sizes[path] = bytes
        scheduleSave()
    }

    /// Writes are coalesced to avoid touching `UserDefaults` once per app.
    private func scheduleSave() {
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.defaults.set(self.sizes, forKey: AppMetrics.cacheKey)
        }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: work)
    }

    /// Sums the allocated size of every file inside a bundle.
    static func directorySize(at path: String) -> Int64 {
        let url = URL(fileURLWithPath: path)
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .fileAllocatedSizeKey, .fileSizeKey]
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        ) else { return 0 }

        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            autoreleasepool {
                guard let values = try? fileURL.resourceValues(forKeys: keys),
                      values.isRegularFile == true else { return }
                if let allocated = values.fileAllocatedSize, allocated > 0 {
                    total += Int64(allocated)
                } else if let size = values.fileSize {
                    total += Int64(size)
                }
            }
        }
        return total
    }
}
