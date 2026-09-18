import Foundation

/// File-system measurement with no observable state.
///
/// Split out of `AppMetrics` so that class can be main-actor isolated. These run on a
/// background queue and must not inherit an actor boundary they cannot honour.
enum DiskMeasurement {
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
