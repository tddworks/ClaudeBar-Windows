import Leaderboard

/// The one request this PC is making to be added to a member (ClaudeBar
/// design §2a), with the key it asked with. Only in the app's memory: nothing
/// is kept until the person agrees to the member it was approved for.
///
/// Asking for a code takes a round trip, and a request cancelled or replaced
/// meanwhile can still answer last. Each ask carries a generation that cancel
/// and a newer ask move on, so such an answer is dropped, unused until it
/// expires on the server, rather than taking the place of the code shown.
@MainActor
public final class DeviceRequests {
    /// The request whose code is shown, once the server gave one.
    public private(set) var current: DeviceRequest?
    private var generation = 0

    public init() {}

    /// Asks for a code, replacing any earlier request. `nil` when cancelled
    /// or replaced while the server answered.
    public func request(through membership: LeaderboardMembership) async throws -> DeviceRequest? {
        generation += 1
        let mine = generation
        current?.stopWaiting()
        current = nil
        let request = try await membership.requestToJoin()
        guard mine == generation else { return nil }
        current = request
        return request
    }

    /// *Cancel*: stops waiting, forgets the code, and drops an ask still under way.
    public func cancel() {
        generation += 1
        current?.stopWaiting()
        current = nil
    }

    /// `request` ended (joined, declined or expired): forgotten if it is still
    /// the current one, and left alone if a newer one took its place.
    public func end(_ request: DeviceRequest) {
        if current === request { current = nil }
    }
}
