// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Builds the `User-Agent`:
/// `{sdk}/{version} ({app}/{version}; Swift/{version}; {os}/{version})`.
///
/// The SDK token leads so first-token User-Agent heuristics attribute the
/// traffic to this package no matter which app embeds it. The `{app}/{version}`
/// in the comment is the embedding app's bundle ID and marketing version,
/// auto-discovered from `Bundle.main`. Best-effort and self-reported —
/// analytics, not a trust boundary. OpenRouter's own app attribution rides on
/// the `HTTP-Referer` / `X-Title` headers, set by the bridge.
package enum Telemetry {
  package static let sdkVersion = "0.1.0"

  package static var userAgent: String {
    let app = appComponent.map { "\($0); " } ?? ""
    return "OpenRouterForFoundationModels/\(sdkVersion) (\(app)Swift/\(swiftVersion); \(platform))"
  }

  /// `{bundle.id}/{marketing-version}`, or `nil` outside an app bundle (CLI,
  /// tests) where there's no `CFBundleIdentifier`.
  static var appComponent: String? {
    let bundle = Bundle.main
    guard let id = bundle.bundleIdentifier else { return nil }
    let version = bundle.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    return "\(id)/\(version)"
  }

  static var swiftVersion: String {
    #if swift(>=6.4)
    "6.4"
    #elseif swift(>=6.3)
    "6.3"
    #else
    "6"
    #endif
  }

  static var platform: String {
    let v = ProcessInfo.processInfo.operatingSystemVersion
    let version = "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
    #if os(iOS)
    return "iOS/\(version)"
    #elseif os(macOS)
    return "macOS/\(version)"
    #elseif os(visionOS)
    return "visionOS/\(version)"
    #elseif os(watchOS)
    return "watchOS/\(version)"
    #else
    return "unknown/\(version)"
    #endif
  }
}
