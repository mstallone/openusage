import Foundation

/// Single source of truth for the app's version, shown in the dashboard footer and the About settings
/// tab. `CFBundleShortVersionString` is baked into the bundle by `script/build_and_run.sh` (dev, derived
/// from the nearest release tag) and `script/release.sh` (release), and is the same string Sparkle shows
/// in its update prompt. The fallback covers runs outside the packaged app (e.g. `swift run`, where there
/// is no Info.plist) — a plain "dev" rather than a number, so an unbundled run can never masquerade as a
/// stale release version.
enum AppInfo {
    static var version: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "dev"
    }
}
