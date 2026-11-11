// SPDX-License-Identifier: GPL-3.0-only
import Foundation

enum VersionSupport {
    // Supported OS versions; individual capabilities still depend on device access.
    static let range = "iOS 27.x"
    static var minimum: String {
        "iOS " + (Bundle.main.object(forInfoDictionaryKey: "MinimumOSVersion") as? String ?? "27.0")
    }

    static func contains(_ version: OperatingSystemVersion) -> Bool {
        version.majorVersion == 27
    }
    static var current: Bool { contains(ProcessInfo.processInfo.operatingSystemVersion) }
    static var label: String { L(current ? "Supported" : "Unsupported") }
}
