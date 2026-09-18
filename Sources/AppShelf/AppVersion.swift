import Foundation

/// The version this build reports, read from the bundle rather than hard-coded so the
/// release script is the only place a version number is written.
enum AppVersion {
    /// Read per access rather than cached in a static: `Bundle.infoDictionary` is not
    /// `Sendable`, so a stored copy would be shared mutable global state.
    private static func value(_ key: String) -> String? {
        Bundle.main.infoDictionary?[key] as? String
    }

    static var string: String { value("CFBundleShortVersionString") ?? "0.0.0" }

    static var build: String { value("CFBundleVersion") ?? "0" }
}
