import Foundation

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
