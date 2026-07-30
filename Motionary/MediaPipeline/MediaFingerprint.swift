// Stable source fingerprints used to invalidate derived media analysis artifacts.

import CryptoKit
import Foundation

enum MediaFingerprint {
    static func sha256(for url: URL) async throws -> String {
        let task = Task.detached(priority: .utility) {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }

            var hasher = SHA256()
            while true {
                try Task.checkCancellation()
                guard let data = try handle.read(upToCount: 1_048_576), !data.isEmpty else {
                    break
                }
                hasher.update(data: data)
            }
            return hasher.finalize().map { String(format: "%02x", $0) }.joined()
        }
        return try await withTaskCancellationHandler(
            operation: { try await task.value },
            onCancel: { task.cancel() }
        )
    }
}
