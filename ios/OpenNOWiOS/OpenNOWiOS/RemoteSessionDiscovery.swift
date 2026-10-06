import Foundation

/// CloudMatch lifecycle values shared by account discovery, resume and loading UI.
enum CloudMatchSessionState: Int {
    case unknown = 0
    case initializing = 1
    case ready = 2
    case streaming = 3
    case pausedUnintentional = 4
    case pausedIntentional = 5
    case resuming = 6
    case finished = 7

    var canResume: Bool { self != .unknown && self != .finished }
    var isPaused: Bool { self == .pausedUnintentional || self == .pausedIntentional }
    var isReady: Bool { self == .ready || self == .streaming }

    var loadingDescription: String {
        switch self {
        case .initializing: return "Preparing session"
        case .ready: return "Setting up gaming rig"
        case .streaming: return "Launching stream"
        case .pausedUnintentional, .pausedIntentional: return "Session paused"
        case .resuming: return "Resuming session"
        case .finished: return "Session ended"
        case .unknown: return "Checking session status"
        }
    }
}

/// Keep the provider result on errors: HTTP 404 alone cannot prove an allocation ended.
enum CloudMatchSessionResponse {
    private static let statusKey = "CloudMatchStatusCode"
    private static let finishedKey = "CloudMatchAllocationFinished"

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

    static func validateAllocationState(_ status: Int?) throws {
        guard status == CloudMatchSessionState.finished.rawValue else { return }
        throw NSError(domain: "OpenNOW.Session", code: 7, userInfo: [
            finishedKey: true,
            NSLocalizedDescriptionKey: "This cloud session has ended. Choose an available session or start the game again."
        ])
    }

    static func isUnavailableAllocation(_ error: Error) -> Bool {
        let value = error as NSError
        return isMissingAllocation(error)
            || (value.domain == "OpenNOW.Session" && value.userInfo[finishedKey] as? Bool == true)
    }

    static func replacement(for allocation: ActiveSession, in sessions: [RemoteSessionCandidate]) -> RemoteSessionCandidate? {
        let matches = sessions.filter {
            $0.id != allocation.id && $0.appId == allocation.game.launchAppId
                && CloudMatchSessionState(rawValue: $0.status)?.canResume == true
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
