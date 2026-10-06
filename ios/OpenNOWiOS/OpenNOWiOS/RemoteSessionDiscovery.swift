import Foundation

/// Keep the provider result on errors: HTTP 404 alone cannot prove an allocation ended.
enum CloudMatchSessionResponse {
    private static let statusKey = "CloudMatchStatusCode"

    static func validate(_ json: [String: Any], httpStatus: Int) throws {
        let status = json["requestStatus"] as? [String: Any]
        let code = status?["statusCode"] as? Int ?? 0
        guard httpStatus == 200, code == 1 else {
            throw NSError(domain: "OpenNOW.Session", code: httpStatus == 200 ? code : httpStatus,
                userInfo: [statusKey: code,
                    NSLocalizedDescriptionKey: status?["statusDescription"] as? String
                        ?? "The session status could not be refreshed (HTTP \(httpStatus))."])
        }
    }

    static func isMissingAllocation(_ error: Error) -> Bool {
        let error = error as NSError
        return error.domain == "OpenNOW.Session"
            && error.userInfo[statusKey] as? Int == 22
            && (error.code == 404 || error.code == 22)
    }

    static func replacement(for allocation: ActiveSession, in sessions: [RemoteSessionCandidate]) -> RemoteSessionCandidate? {
        let matches = sessions.filter {
            $0.id != allocation.id && $0.appId == allocation.game.launchAppId
                && (1...3).contains($0.status)
        }
        return matches.count == 1 ? matches.first : nil
    }
}

/// Only a successful account listing can replace the last known sessions.
/// Provider or transport failures must not masquerade as an empty account.
enum CloudMatchActiveSessionsResponse {
    static func entries(_ json: [String: Any], httpStatus: Int) throws -> [[String: Any]] {
        let status = json["requestStatus"] as? [String: Any]
        let code = status?["statusCode"] as? Int ?? 0
        let description = status?["statusDescription"] as? String ?? "Unable to refresh active sessions."
        guard httpStatus == 200 else {
            throw NSError(domain: "OpenNOW.Session", code: httpStatus, userInfo: [
                NSLocalizedDescriptionKey: "Unable to refresh active sessions (HTTP \(httpStatus))."
            ])
        }
        guard code == 1 else {
            throw NSError(domain: "OpenNOW.Session", code: code, userInfo: [NSLocalizedDescriptionKey: description])
        }
        guard let entries = json["sessions"] as? [[String: Any]] else {
            throw NSError(domain: "OpenNOW.Session", code: 0, userInfo: [
                NSLocalizedDescriptionKey: "The active-session response is missing its session list."
            ])
        }
        return entries
    }
}

/// Refresh account sessions while browsing, without a catalog reload or a UI timer.
/// The store owns eligibility, account checks and the request; this owns scheduling.
@MainActor
final class RemoteSessionDiscovery {
    private let interval: Duration
    private var task: Task<Void, Never>?

    init(interval: Duration = .seconds(15)) { self.interval = interval }

    func start(canRefresh: @escaping () -> Bool, refresh: @escaping () async -> Void) {
        guard task == nil else { return }
        let interval = interval
        task = Task {
            while !Task.isCancelled {
                if canRefresh() { await refresh() }
                do { try await Task.sleep(for: interval) }
                catch { break }
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    deinit { task?.cancel() }
}
