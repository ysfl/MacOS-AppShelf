import Foundation

/// Human readable byte counts for the app cards.
public enum ByteFormatter {
    /// Disk usage reads like Finder: "1.2 GB", "256 MB", "512 KB".
    public static func disk(_ bytes: Int64) -> String {
        measure(bytes, kb: "KB", mb: "MB", gb: "GB")
    }

    /// Memory usage is shown in the same shape, e.g. "1.2 G" or "512 M".
    public static func memory(_ bytes: Int64) -> String {
        measure(bytes, kb: "K", mb: "M", gb: "G")
    }

    /// Shown when nothing has been measured yet, or when an app is not running.
    public static let placeholder = "—"

    /// Chooses the unit *after* rounding, which is what the original got wrong: 1,048,575
    /// bytes is 1023.999 KB, so the old code fell through to the KB branch and printed
    /// "1024 KB" instead of "1 MB".
    private static func measure(_ bytes: Int64, kb: String, mb: String, gb: String) -> String {
        guard bytes > 0 else { return placeholder }
        let kib = Double(bytes) / 1024
        if kib < 1 { return "1 \(kb)" }
        if kib < 1023.5 { return whole(kib, kb) }
        let mib = kib / 1024
        if mib < 1023.5 { return whole(mib, mb) }
        // %.1f rounds half to even, which made exactly 1.25 GB read as "1.2 GB".
        let tenths = (mib / 1024 * 10).rounded(.awayFromZero)
        return String(format: "%.1f %@", tenths / 10, gb)
    }

    private static func whole(_ value: Double, _ unit: String) -> String {
        "\(Int(value.rounded(.awayFromZero))) \(unit)"
    }
}
