import Foundation
import os

#if canImport(MWDATCore)
import MWDATCore
#endif

enum MetaWearablesBootstrap {
    private static let log = Logger(subsystem: "com.kishparikh.clawk", category: "meta-wearables")

    static func configure() {
        #if canImport(MWDATCore)
        do {
            try Wearables.configure()
            debugLog("Wearables.configure succeeded")
        } catch {
            debugLog("Wearables.configure failed error=\(error.localizedDescription)")
            assertionFailure("Failed to configure Meta Wearables DAT: \(error)")
        }
        #else
        debugLog("Wearables.configure skipped MWDATCore unavailable")
        #endif
    }

    static func handle(url: URL) async {
        #if canImport(MWDATCore)
        do {
            _ = try await Wearables.shared.handleUrl(url)
            debugLog("handleUrl succeeded url=\(url.absoluteString)")
        } catch {
            debugLog("handleUrl failed url=\(url.absoluteString) error=\(error.localizedDescription)")
        }
        #else
        debugLog("handleUrl skipped MWDATCore unavailable url=\(url.absoluteString)")
        #endif
    }

    private static func debugLog(_ message: String) {
        log.info("\(message, privacy: .public)")
        print("[MetaWearables] \(message)")
    }
}
