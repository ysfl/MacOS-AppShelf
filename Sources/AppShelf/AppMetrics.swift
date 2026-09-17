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
        var pids = [Int32](repeating: 0, count: 4096)
        let count = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<Int32>.stride))
        guard count > 0 else { return [] }

        var samples: [Sample] = []
        samples.reserveCapacity(Int(count))
        var buffer = [CChar](repeating: 0, count: 4096)

        for index in 0..<Int(count) where index < pids.count {
            let pid = pids[index]
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

    private static let cacheKey = "AppShelf.sizeCache.v2"

    private let queue: OperationQueue
    private let defaults: UserDefaults
    private var records: [String: Record] = [:]
    private var trackedApps: [AppItem] = []
    private var inFlight: Set<String> = []
    private var saveWork: DispatchWorkItem?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 3
        queue.qualityOfService = .utility
        self.queue = queue

        if let data = defaults.data(forKey: Self.cacheKey),
           let saved = try? JSONDecoder().decode([String: Record].self, from: data) {
            records = saved
            sizes = saved.mapValues(\.bytes)
        }
        // The first cache format only stored bundle sizes and is no longer written.
        defaults.removeObject(forKey: "AppShelf.sizeCache.v1")
    }

    func sizeText(for path: String) -> String {
        ByteFormatter.disk(sizes[path] ?? 0)
    }

    func memoryText(for path: String) -> String {
        ByteFormatter.memory(memory[path] ?? 0)
    }

    /// Schedules a measurement for every app that is missing, or whose bundle has
    /// been modified since the last measurement.
    func measure(_ apps: [AppItem]) {
        trackedApps = apps

        for app in apps {
            let modified = Self.bundleModificationDate(at: app.path)
            if let record = records[app.path], record.bundleModifiedAt == modified { continue }
            guard !inFlight.contains(app.path) else { continue }

            inFlight.insert(app.path)
            let path = app.path
            let identifier = app.bundleIdentifier
            let name = app.name
            queue.addOperation { [weak self] in
                let bytes = AppMetrics.totalSize(bundlePath: path, bundleIdentifier: identifier, displayName: name)
                DispatchQueue.main.async {
                    self?.complete(path: path, bytes: bytes, bundleModifiedAt: modified)
                }
            }
        }
    }

    /// Sums every process whose executable lives inside the given bundles.
    func updateMemory(forAppPaths paths: [String]) {
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

        // Only publish when a number moved, so the cards are not redrawn on every tick.
        guard totals != memory else { return }
        memory = totals
    }

    /// Drops the cached disk usage so the next pass measures everything again.
    func invalidateDiskCache() {
        queue.cancelAllOperations()
        inFlight.removeAll()
        records = [:]
        sizes = [:]
        defaults.removeObject(forKey: Self.cacheKey)
    }

    func recalculate() {
        invalidateDiskCache()
        measure(trackedApps)
    }

    private func complete(path: String, bytes: Int64, bundleModifiedAt: TimeInterval) {
        inFlight.remove(path)
        records[path] = Record(bytes: bytes, bundleModifiedAt: bundleModifiedAt)
        sizes[path] = bytes
        scheduleSave()
    }

    /// Writes are coalesced to avoid touching `UserDefaults` once per app.
    private func scheduleSave() {
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            guard let data = try? JSONEncoder().encode(self.records) else { return }
            self.defaults.set(data, forKey: AppMetrics.cacheKey)
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
