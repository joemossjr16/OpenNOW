import Foundation

/// Restored allocations need a native hand-over even when a poll already says ready.
/// Fresh allocations have just been provisioned and must not be claimed again.
@MainActor
final class NativeStreamSessionHandoff {
    private var restoredAllocationID: String?

    func restore(allocationID: String?) { restoredAllocationID = allocationID }

    func didClaim(allocationID: String) {
        if restoredAllocationID == allocationID { restoredAllocationID = nil }
    }

    func prepare(
        _ allocation: ActiveSession,
        usesNativeNVST: Bool,
        claim: (ActiveSession) async throws -> ActiveSession
    ) async throws -> ActiveSession {
        guard usesNativeNVST, restoredAllocationID == allocation.id,
              allocation.status == 2 || allocation.status == 3 else { return allocation }
        let claimed = try await claim(allocation)
        try Task.checkCancellation()
        guard claimed.id == allocation.id else {
            throw NSError(domain: "OpenNOW.Session", code: 0, userInfo: [
                NSLocalizedDescriptionKey: "Resume returned a different session id."
            ])
        }
        didClaim(allocationID: claimed.id)
        return claimed
    }
}

/// CloudMatch provisioning for the experimental native connection, shared by launch and hand-over.
enum NativeStreamNVSTConfiguration {
    static func endpoints(sessionObj: [String: Any], fallbackHost: String?) -> [String] {
        NvstRtspEndpoints.collect(connections: sessionObj["connectionInfo"] as? [[String: Any]] ?? [],
            fallbackHost: fallbackHost, allowsAssumedControlPort: false)
    }

    static func requestBody(_ body: [String: Any], enabled: Bool) -> [String: Any] {
        guard enabled, var request = body["sessionRequestData"] as? [String: Any] else { return body }
        var native = body
        request["secureRTSPSupported"] = true
        if let metadata = request["metaData"] as? [[String: String]] {
            request["metaData"] = metadata.filter { $0["key"] != "GSStreamerType" }
        }
        native["sessionRequestData"] = request
        return native
    }
}
