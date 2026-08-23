import CryptoKit
import Foundation

public enum ServiceBundleFingerprint {
    public static func current(bundle: Bundle = .main) -> String? {
        current(bundleURL: bundle.bundleURL)
    }

    public static func current(bundleURL: URL) -> String? {
        let relativePaths = [
            "Contents/MacOS/LATCH",
            "Contents/Info.plist",
            "Contents/Library/Helpers/LATCHDaemon",
            "Contents/Library/Helpers/LATCHAgent",
            "Contents/Library/LaunchDaemons/\(LATCHIdentity.daemonIdentifier).plist",
            "Contents/Library/LaunchAgents/\(LATCHIdentity.agentIdentifier).plist",
        ]
        var digest = SHA256()
        for relativePath in relativePaths {
            let url = bundleURL.appendingPathComponent(relativePath)
            guard let data = try? Data(contentsOf: url) else { return nil }
            digest.update(data: data)
        }
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
