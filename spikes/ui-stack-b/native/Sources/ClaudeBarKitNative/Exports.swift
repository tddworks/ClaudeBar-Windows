import Foundation
import Quotas
#if os(Windows)
import WinSDK
#endif

// The C interface C# calls. Rules this spike tests:
// - Strings returned by a function are owned by the caller and freed with cb_free.
// - Async work returns a handle (0 = not started) and replies exactly once through
//   the callback, on a Swift worker thread. The JSON pointer is valid only during
//   the callback. cb_cancel(handle) makes the reply arrive early with "cancelled": true.

public typealias CBCallback = @convention(c) (UnsafeMutableRawPointer?, UnsafePointer<CChar>?) -> Void

// MARK: - Plumbing

private struct Reply: @unchecked Sendable {
    let context: UnsafeMutableRawPointer?
    let callback: CBCallback

    func send(_ text: String) {
        text.withCString { callback(context, $0) }
    }
}

private final class Jobs: @unchecked Sendable {
    static let shared = Jobs()
    private let lock = NSLock()
    private var nextID: Int64 = 1
    private var tasks: [Int64: Task<Void, Never>] = [:]

    func start(_ body: @escaping @Sendable () async -> Void) -> Int64 {
        lock.lock()
        defer { lock.unlock() }
        let id = nextID
        nextID += 1
        tasks[id] = Task.detached {
            await body()
            Jobs.shared.finish(id)
        }
        return id
    }

    func cancel(_ id: Int64) {
        lock.lock()
        let task = tasks[id]
        lock.unlock()
        task?.cancel()
    }

    private func finish(_ id: Int64) {
        lock.lock()
        tasks[id] = nil
        lock.unlock()
    }
}

private func nativeThreadID() -> UInt64 {
    #if os(Windows)
    return UInt64(GetCurrentThreadId())
    #else
    var id: UInt64 = 0
    pthread_threadid_np(nil, &id)
    return id
    #endif
}

private func cString(_ text: String) -> UnsafeMutablePointer<CChar> {
    let bytes = Array(text.utf8CString)
    let pointer = UnsafeMutablePointer<CChar>.allocate(capacity: bytes.count)
    pointer.initialize(from: bytes, count: bytes.count)
    return pointer
}

private func json<T: Encodable>(_ value: T) -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    guard let data = try? encoder.encode(value) else { return "{}" }
    return String(decoding: data, as: UTF8.self)
}

// MARK: - Exports

@c public func cb_free(_ pointer: UnsafeMutablePointer<CChar>?) {
    pointer?.deallocate()
}

private struct VersionInfo: Encodable {
    let library: String
    let swift: String
    let os: String
}

@c public func cb_version() -> UnsafeMutablePointer<CChar>? {
    #if compiler(>=6.4)
    let swift = "6.4+"
    #elseif compiler(>=6.3)
    let swift = "6.3"
    #else
    let swift = "<6.3"
    #endif
    return cString(json(VersionInfo(
        library: "ClaudeBarKitNative 0.0.1 (spike, Quotas @ 721dc625)",
        swift: swift,
        os: ProcessInfo.processInfo.operatingSystemVersionString
    )))
}

private struct QuotaDescription: Encodable {
    let providerId: String
    let quotaType: String
    let percentRemaining: Double
    let percentUsed: Double
    let status: String
    let needsAttention: Bool
    let isDepleted: Bool
}

/// A session quota for `providerId`, described by ClaudeBar's own `UsageQuota`.
@c public func cb_quota_describe(_ percentRemaining: Double, _ providerId: UnsafePointer<CChar>?) -> UnsafeMutablePointer<CChar>? {
    let id = providerId.map { String(cString: $0) } ?? "unknown"
    let quota = UsageQuota(percentRemaining: percentRemaining, quotaType: .session, providerId: id)
    return cString(json(QuotaDescription(
        providerId: id,
        quotaType: quota.quotaType.displayName,
        percentRemaining: quota.percentRemaining,
        percentUsed: quota.percentUsed,
        status: "\(quota.status)",
        needsAttention: quota.needsAttention,
        isDepleted: quota.isDepleted
    )))
}

/// `UsageError.rateLimited`'s message, which formats a relative time with ICU.
@c public func cb_rate_limited_text(_ secondsFromNow: Double) -> UnsafeMutablePointer<CChar>? {
    let error = UsageError.rateLimited(retryAt: Date().addingTimeInterval(secondsFromNow))
    return cString(error.errorDescription ?? "")
}

private struct ScanResult: Encodable {
    let root: String
    let files: Int
    let bytes: Int64
    let newest: String?
    let cancelled: Bool
    let error: String?
    let elapsedMs: Int
    let nativeThread: UInt64
}

private func sessionLogs(under root: String) throws -> [URL] {
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: root, isDirectory: &isDirectory), isDirectory.boolValue else {
        throw CocoaError(.fileNoSuchFile)
    }
    let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey]
    guard let walker = FileManager.default.enumerator(at: URL(fileURLWithPath: root, isDirectory: true), includingPropertiesForKeys: keys) else {
        throw CocoaError(.fileReadUnknown)
    }
    var logs: [URL] = []
    for case let url as URL in walker where url.pathExtension == "jsonl" {
        logs.append(url)
    }
    return logs
}

/// Counts the `.jsonl` session logs under `root`. `perFileDelayMs` slows the walk
/// down so cancellation can be exercised.
@c public func cb_scan_sessions(
    _ root: UnsafePointer<CChar>?,
    _ perFileDelayMs: Int32,
    _ context: UnsafeMutableRawPointer?,
    _ callback: CBCallback?
) -> Int64 {
    guard let root, let callback else { return 0 }
    let path = String(cString: root)
    let reply = Reply(context: context, callback: callback)
    return Jobs.shared.start {
        let started = Date()
        var files = 0
        var bytes: Int64 = 0
        var newest: Date?
        var cancelled = false
        var failure: String?
        do {
            for url in try sessionLogs(under: path) {
                if perFileDelayMs > 0 {
                    try? await Task.sleep(for: .milliseconds(Int(perFileDelayMs)))
                }
                if Task.isCancelled {
                    cancelled = true
                    break
                }
                let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
                files += 1
                bytes += Int64(values?.fileSize ?? 0)
                if let modified = values?.contentModificationDate, modified > (newest ?? .distantPast) {
                    newest = modified
                }
            }
        } catch {
            failure = "\(error)"
        }
        reply.send(json(ScanResult(
            root: path,
            files: files,
            bytes: bytes,
            newest: newest?.ISO8601Format(),
            cancelled: cancelled,
            error: failure,
            elapsedMs: Int(Date().timeIntervalSince(started) * 1000),
            nativeThread: nativeThreadID()
        )))
    }
}

@c public func cb_cancel(_ handle: Int64) {
    Jobs.shared.cancel(handle)
}

private struct ProbeResult: Encodable {
    let ranOnMainActor: Bool
    let nativeThread: UInt64
}

/// Replies from a `@MainActor` task. Shows whether work isolated to the main
/// actor runs when the host's message loop, not Swift, owns the main thread.
@c public func cb_mainactor_probe(_ context: UnsafeMutableRawPointer?, _ callback: CBCallback?) {
    guard let callback else { return }
    let reply = Reply(context: context, callback: callback)
    Task { @MainActor in
        reply.send(json(ProbeResult(ranOnMainActor: true, nativeThread: nativeThreadID())))
    }
}

/// Runs the main run loop once without waiting, which drains the main dispatch
/// queue. The host calls it from its UI thread on a timer.
@c public func cb_pump_main() {
    _ = RunLoop.main.run(mode: .default, before: Date())
}
