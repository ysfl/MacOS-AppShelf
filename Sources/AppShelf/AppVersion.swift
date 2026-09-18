import Foundation

/// The version this build reports, read from the bundle rather than hard-coded so the
/// release script is the only place a version number is written.
enum AppVersion {
    private static let infoDictionary = Bundle.main.infoDictionary

    static var string: String {
        infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
    }

    static var build: String {
        infoDictionary?["CFBundleVersion"] as? String ?? "0"
    }
}
