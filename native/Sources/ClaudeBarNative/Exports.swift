import ClaudeBarWindows
import DataSources
import DispatchSPI
import Foundation
import Leaderboard
import Quotas

// The C interface the C# app calls (ClaudeBar-Windows#2).
// - A string a function returns belongs to the caller, who frees it with cbw_free.
// - A call that takes a callback replies exactly once, with JSON, on the main
//   actor: the app's UI thread, which drains Swift's main queue with
//   cbw_drain_main_queue on a timer. The JSON is valid only during the callback.
// - Every reply carries "state", what the app shows, read afresh from the
//   settings file and Credential Manager; a failure adds "error", the text a
//   person reads.

public typealias CBWCallback = @convention(c) (UnsafeMutableRawPointer?, UnsafePointer<CChar>?) -> Void

// MARK: - Plumbing

private struct Reply: @unchecked Sendable {
    let context: UnsafeMutableRawPointer?
    let callback: CBWCallback

    func send(_ value: [String: Any]) {
        let data = (try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])) ?? Data("{}".utf8)
        String(decoding: data, as: UTF8.self).withCString { callback(context, $0) }
    }
}

@MainActor private let client = Client()

private func cString(_ text: String) -> UnsafeMutablePointer<CChar> {
    let bytes = Array(text.utf8CString)
    let pointer = UnsafeMutablePointer<CChar>.allocate(capacity: bytes.count)
    pointer.initialize(from: bytes, count: bytes.count)
    return pointer
}

private func string(_ pointer: UnsafePointer<CChar>?) -> String {
    pointer.map { String(cString: $0) } ?? ""
}

@MainActor private let iso: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    return formatter
}()

/// Runs `work` on the main actor with a fresh membership, and replies with
/// what it adds, the state after it, and the error a person reads if it threw,
/// or if a change didn't reach the settings file (ClaudeBar's package saves
/// without throwing, so `SettingsFile` keeps the failure for this to say).
private func run(_ context: UnsafeMutableRawPointer?, _ callback: CBWCallback?,
                 _ work: @escaping @MainActor (LeaderboardMembership) async throws -> [String: Any]) {
    guard let callback else { return }
    let reply = Reply(context: context, callback: callback)
    Task { @MainActor in
        _ = client.settings.takeFailure()
        let membership = client.membership()
        var answer: [String: Any]
        do {
            answer = try await work(membership)
        } catch {
            answer = ["error": (error as? LocalizedError)?.errorDescription ?? error.localizedDescription]
        }
        if answer["error"] == nil, let failure = client.settings.takeFailure() {
            answer["error"] = "ClaudeBar couldn't save this on this PC (\(failure)). Try again."
        }
        answer["state"] = state(of: client.membership())
        reply.send(answer)
    }
}

@MainActor private func state(of membership: LeaderboardMembership) -> [String: Any] {
    [
        "on": membership.isOn,
        "joined": membership.isJoined,
        "username": membership.username?.value ?? NSNull(),
        "visible": membership.isVisible,
        "sharing": membership.sharing.sorted(),
        "providers": client.logs.providers.map {
            ["id": $0.id, "name": $0.name, "light": $0.light, "dark": $0.dark, "shared": membership.sharing.contains($0.id)]
        },
        "lastUpload": membership.lastUpload.map { iso.string(from: $0) } ?? NSNull(),
        "refused": membership.refused.count,
        // The key came from another PC (design §2a): nothing uploads until answered.
        "copiedKey": membership.holdsCopiedKey,
        "label": membership.suggestedLabel.value,
        "version": Client.version,
    ]
}

// MARK: - Exports

@c public func cbw_free(_ pointer: UnsafeMutablePointer<CChar>?) {
    pointer?.deallocate()
}

/// Drains Swift's main queue. The app calls it from its UI thread, the thread
/// that loaded this DLL, which libdispatch binds the main queue to.
@c public func cbw_drain_main_queue() {
    _dispatch_main_queue_callback_4CF(nil)
}

@c public func cbw_version() -> UnsafeMutablePointer<CChar>? {
    cString(Client.version)
}

/// `{state}`.
@c public func cbw_state(_ context: UnsafeMutableRawPointer?, _ callback: CBWCallback?) {
    run(context, callback) { _ in [:] }
}

/// What joining would share, and what each provider sends now: its tokens on
/// this PC over the last 30 days and the last 7, counted as an upload counts
/// them (`DailyTokens.summed`), cache included; and today's rows exactly as
/// an upload sends them, for *Exactly what gets uploaded*. Every day is the
/// person's own, in their time zone (`DataSources.calendar()`), as an upload's
/// is; Foundation's own calendar is GMT on Windows (ClaudeBar#565). The logs
/// are read once: the 7 days are taken from the 30, since a PC with gigabytes
/// of sessions takes tens of seconds for each read.
/// `{providers: [{id, name, tokens, days, week}], today: String, rows: [DailyTokens], state}`.
@c public func cbw_preview(_ context: UnsafeMutableRawPointer?, _ callback: CBWCallback?) {
    run(context, callback) { _ in
        let calendar = DataSources.calendar()
        // One moment for the 30 days, the 7 and today: a read that runs past
        // midnight still answers for the day it started, every part alike.
        let now = Date()
        let month = await client.logs.days(in: DateRange.last(30, endingOn: now, calendar: calendar))
        let lastWeek = DateRange.last(7, endingOn: now, calendar: calendar)
        let week = month.map { $0.within(lastWeek) }
        let providers = client.logs.providers.map { provider -> [String: Any] in
            let days = DailyTokens.summed(month, providers: [provider.id], calendar: calendar)
            let weekTokens = DailyTokens.summed(week, providers: [provider.id], calendar: calendar).reduce(0) { $0 + $1.total }
            return ["id": provider.id, "name": provider.name, "tokens": days.reduce(0) { $0 + $1.total },
                    "days": days.count, "week": weekTokens]
        }
        let today = DailyTokens.day(of: now, calendar: calendar)
        let rows = DailyTokens.summed(week, providers: client.logs.providersWithLogs, calendar: calendar)
            .filter { $0.day == today }.map { row -> [String: Any] in
                ["provider": row.provider, "day": row.day, "input": row.input, "output": row.output,
                 "cacheWrite": row.cacheWrite, "cacheRead": row.cacheRead, "unsplit": row.unsplit]
            }
        return ["providers": providers, "today": today, "rows": rows]
    }
}

/// Joins as `username`, sharing the comma-separated provider ids, then sends
/// the last 30 days. `{uploaded: Bool, state}` or `{error, state}`.
@c public func cbw_join(_ username: UnsafePointer<CChar>?, _ sharing: UnsafePointer<CChar>?,
                        _ context: UnsafeMutableRawPointer?, _ callback: CBWCallback?) {
    let name = string(username)
    let providers = Set(string(sharing).split(separator: ",").map(String.init))
    run(context, callback) { membership in
        guard let username = Username(name) else {
            return ["error": "A username is 3 to 20 letters, digits, - or _."]
        }
        try await membership.join(as: username, sharing: providers)
        let uploader = client.uploader(for: membership)
        await uploader.uploadNow()
        return ["uploaded": uploader.lastError == nil]
    }
}

/// Shares a provider, or stops sharing it. `{state}` or `{error, state}`.
@c public func cbw_set_sharing(_ provider: UnsafePointer<CChar>?, _ shared: Bool,
                               _ context: UnsafeMutableRawPointer?, _ callback: CBWCallback?) {
    let id = string(provider)
    run(context, callback) { membership in
        if shared { try membership.share(id) } else { membership.stopSharing(id) }
        return [:]
    }
}

/// Shows the member on the board, or hides them. `{state}` or `{error, state}`.
@c public func cbw_set_visible(_ visible: Bool, _ context: UnsafeMutableRawPointer?, _ callback: CBWCallback?) {
    run(context, callback) { membership in
        try await membership.setVisible(visible)
        return [:]
    }
}

/// *Keep the key here*, when the key came from another PC (`copiedKey`):
/// this PC keeps it and uploads again. `{state}` or `{error, state}`.
@c public func cbw_keep_key_here(_ context: UnsafeMutableRawPointer?, _ callback: CBWCallback?) {
    run(context, callback) { membership in
        try membership.keepKeyHere()
        return [:]
    }
}

/// Uploads now. `{state}` or `{error, state}`.
@c public func cbw_upload_now(_ context: UnsafeMutableRawPointer?, _ callback: CBWCallback?) {
    run(context, callback) { membership in
        let uploader = client.uploader(for: membership)
        await uploader.uploadNow()
        if let error = uploader.lastError { throw error }
        return [:]
    }
}

/// One board: `period` is `today`, `7d` or `30d`; an empty `provider` is
/// everyone. `{members: [{rank, username, total, byProvider, you}],
/// you: {rank, total, byProvider} | null, state}` or `{error, state}`.
@c public func cbw_board(_ period: UnsafePointer<CChar>?, _ provider: UnsafePointer<CChar>?,
                         _ context: UnsafeMutableRawPointer?, _ callback: CBWCallback?) {
    let period = BoardPeriod(rawValue: string(period)) ?? .sevenDays
    let id = string(provider)
    run(context, callback) { membership in
        let board = Board(period: period, provider: id.isEmpty ? nil : id, api: client.api, membership: membership)
        await board.read()
        if let failure = board.failure { throw failure }
        let you = board.you
        let members = (board.members ?? []).map { member -> [String: Any] in
            ["rank": member.rank, "username": member.username, "total": member.total,
             "byProvider": member.byProvider, "you": member.username == you?.username]
        }
        let yours = you.map { ["rank": $0.rank, "total": $0.total, "byProvider": $0.byProvider] as [String: Any] }
        return ["members": members, "you": yours ?? NSNull()]
    }
}

/// Everything the server holds about the member, as it sent it (the JSON of
/// `GET /me/export`). `{export: String, state}` or `{error, state}`.
@c public func cbw_export(_ context: UnsafeMutableRawPointer?, _ callback: CBWCallback?) {
    run(context, callback) { membership in
        let data = try await membership.export()
        return ["export": String(decoding: data, as: UTF8.self)]
    }
}

/// Leaves: the server deletes the member and every day, then this PC forgets
/// the key. `{state}` or `{error, state}`.
@c public func cbw_leave(_ context: UnsafeMutableRawPointer?, _ callback: CBWCallback?) {
    run(context, callback) { membership in
        try await membership.leave()
        return [:]
    }
}
