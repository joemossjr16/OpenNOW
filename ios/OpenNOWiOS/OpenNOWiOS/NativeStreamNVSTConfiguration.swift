import Foundation

/// Restored allocations need a native hand-over even when a poll already says ready.
/// Fresh allocations have just been provisioned and must not be claimed again.
@MainActor
final class NativeStreamSessionHandoff {
    private var restoredAllocationID: String?
    private var reconnectingAllocations: Set<String> = []

    func restore(allocationID: String?) { restoredAllocationID = allocationID }

    func didClaim(allocationID: String) {
        if restoredAllocationID == allocationID { restoredAllocationID = nil }
    }

    static func canConnect(_ allocation: ActiveSession) -> Bool {
        CloudMatchSessionState(rawValue: allocation.status)?.isReady == true
            && allocation.nativeResumePending != true
    }

    func prepare(
        _ allocation: ActiveSession,
        usesNativeNVST: Bool,
        claim: (ActiveSession) async throws -> ActiveSession
    ) async throws -> ActiveSession {
        guard usesNativeNVST,
              restoredAllocationID == allocation.id || allocation.nativeResumePending == true,
              allocation.status == 2 || allocation.status == 3 else { return allocation }
        return try await reconnect(allocation, refresh: { $0 }, claim: claim)
    }

    func reconnect(
        _ allocation: ActiveSession,
        refresh: (ActiveSession) async throws -> ActiveSession,
        claim: (ActiveSession) async throws -> ActiveSession
    ) async throws -> ActiveSession {
        guard reconnectingAllocations.insert(allocation.id).inserted else {
            throw NSError(domain: "OpenNOW.Session", code: 409, userInfo: [
                NSLocalizedDescriptionKey: "A reconnect is already in progress for this session."
            ])
        }
        defer { reconnectingAllocations.remove(allocation.id) }
        let refreshed = try await refresh(allocation)
        try Task.checkCancellation()
        guard refreshed.id == allocation.id else { throw CancellationError() }
        try CloudMatchSessionResponse.validateAllocationState(refreshed.status)
        let claimed = try await claim(refreshed)
        try Task.checkCancellation()
        guard claimed.id == allocation.id else {
            throw NSError(domain: "OpenNOW.Session", code: 0, userInfo: [
                NSLocalizedDescriptionKey: "Resume returned a different session id."
            ])
        }
        try CloudMatchSessionResponse.validateAllocationState(claimed.status)
        if claimed.nativeResumePending != true { didClaim(allocationID: claimed.id) }
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
