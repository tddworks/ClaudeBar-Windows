using System.Runtime.CompilerServices;
using System.Runtime.InteropServices;

namespace ClaudeBarSpike;

/// The C functions ClaudeBarKitNative.dll exports (see native/Sources/ClaudeBarKitNative/Exports.swift).
internal static unsafe partial class Native
{
    private const string Lib = "ClaudeBarKitNative";

    [LibraryImport(Lib)] internal static partial void cb_free(byte* text);
    [LibraryImport(Lib)] internal static partial byte* cb_version();
    [LibraryImport(Lib, StringMarshalling = StringMarshalling.Utf8)]
    internal static partial byte* cb_quota_describe(double percentRemaining, string providerId);
    [LibraryImport(Lib)] internal static partial byte* cb_rate_limited_text(double secondsFromNow);
    [LibraryImport(Lib, StringMarshalling = StringMarshalling.Utf8)]
    internal static partial long cb_scan_sessions(string root, int perFileDelayMs, nint context, delegate* unmanaged[Cdecl]<nint, byte*, void> callback);
    [LibraryImport(Lib)] internal static partial void cb_cancel(long handle);
    [LibraryImport(Lib)] internal static partial void cb_mainactor_probe(nint context, delegate* unmanaged[Cdecl]<nint, byte*, void> callback);
    [LibraryImport(Lib)] internal static partial void cb_pump_main();

    [LibraryImport(Lib)] internal static partial void cb_drain_main_queue();
    [LibraryImport("kernel32.dll")] internal static partial uint GetCurrentThreadId();
    [LibraryImport("kernel32.dll")] private static partial int GetCurrentPackageFullName(ref uint length, char* name);

    private const int AppModelErrorNoPackage = 15700;

    internal static bool IsPackaged()
    {
        uint length = 0;
        return GetCurrentPackageFullName(ref length, null) != AppModelErrorNoPackage;
    }

    /// Copies a string the DLL returned, then frees it with the DLL's allocator.
    private static string Take(byte* text)
    {
        try { return Marshal.PtrToStringUTF8((nint)text) ?? ""; }
        finally { cb_free(text); }
    }

    internal static string Version() => Take(cb_version());
    internal static string QuotaDescribe(double percentRemaining, string providerId) => Take(cb_quota_describe(percentRemaining, providerId));
    internal static string RateLimitedText(double secondsFromNow) => Take(cb_rate_limited_text(secondsFromNow));
}

/// Turns the DLL's handle-plus-callback calls into Tasks.
///
/// The callback arrives on a Swift worker thread. It completes a
/// TaskCompletionSource whose continuations run asynchronously, so an `await`
/// on the UI thread resumes there through WinUI's DispatcherQueue
/// synchronization context, not on the Swift thread.
internal static unsafe class Bridge
{
    internal sealed record Reply(string Json, uint CallbackNativeThread, int CallbackManagedThread);

    private static int _pending;

    /// Calls still waiting for their callback; every GCHandle is freed when it reaches 0.
    internal static int Pending => Volatile.Read(ref _pending);

    internal static Task<Reply> ScanSessionsAsync(string root, int perFileDelayMs, CancellationToken cancellation)
    {
        var (completion, context) = Begin();
        long handle = Native.cb_scan_sessions(root, perFileDelayMs, context, &OnReply);
        if (handle == 0)
        {
            End(context).SetException(new InvalidOperationException("cb_scan_sessions did not start"));
            return completion.Task;
        }
        var registration = cancellation.Register(() => Native.cb_cancel(handle));
        _ = completion.Task.ContinueWith(_ => registration.Dispose(), TaskScheduler.Default);
        return completion.Task;
    }

    internal static Task<Reply> MainActorProbeAsync()
    {
        var (completion, context) = Begin();
        Native.cb_mainactor_probe(context, &OnReply);
        return completion.Task;
    }

    private static (TaskCompletionSource<Reply>, nint) Begin()
    {
        var completion = new TaskCompletionSource<Reply>(TaskCreationOptions.RunContinuationsAsynchronously);
        Interlocked.Increment(ref _pending);
        return (completion, GCHandle.ToIntPtr(GCHandle.Alloc(completion)));
    }

    private static TaskCompletionSource<Reply> End(nint context)
    {
        var handle = GCHandle.FromIntPtr(context);
        var completion = (TaskCompletionSource<Reply>)handle.Target!;
        handle.Free();
        Interlocked.Decrement(ref _pending);
        return completion;
    }

    [UnmanagedCallersOnly(CallConvs = new[] { typeof(CallConvCdecl) })]
    private static void OnReply(nint context, byte* json)
    {
        var text = Marshal.PtrToStringUTF8((nint)json) ?? "";
        End(context).SetResult(new Reply(text, Native.GetCurrentThreadId(), Environment.CurrentManagedThreadId));
    }
}
