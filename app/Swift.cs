using System.Runtime.CompilerServices;
using System.Runtime.InteropServices;
using System.Text.Json.Nodes;

namespace ClaudeBar;

/// The C functions ClaudeBarNative.dll exports (native/Sources/ClaudeBarNative/Exports.swift).
internal static unsafe partial class Native
{
    private const string Lib = "ClaudeBarNative";

    [LibraryImport(Lib)] internal static partial void cbw_free(byte* text);
    [LibraryImport(Lib)] internal static partial void cbw_drain_main_queue();
    [LibraryImport(Lib)] internal static partial byte* cbw_version();
    [LibraryImport(Lib)] internal static partial void cbw_state(nint context, delegate* unmanaged[Cdecl]<nint, byte*, void> callback);
    [LibraryImport(Lib)] internal static partial void cbw_preview(nint context, delegate* unmanaged[Cdecl]<nint, byte*, void> callback);
    [LibraryImport(Lib, StringMarshalling = StringMarshalling.Utf8)]
    internal static partial void cbw_join(string username, string sharing, nint context, delegate* unmanaged[Cdecl]<nint, byte*, void> callback);
    [LibraryImport(Lib, StringMarshalling = StringMarshalling.Utf8)]
    internal static partial void cbw_set_sharing(string provider, [MarshalAs(UnmanagedType.U1)] bool shared, nint context, delegate* unmanaged[Cdecl]<nint, byte*, void> callback);
    [LibraryImport(Lib)]
    internal static partial void cbw_set_visible([MarshalAs(UnmanagedType.U1)] bool visible, nint context, delegate* unmanaged[Cdecl]<nint, byte*, void> callback);
    [LibraryImport(Lib)] internal static partial void cbw_upload_now(nint context, delegate* unmanaged[Cdecl]<nint, byte*, void> callback);
    [LibraryImport(Lib)] internal static partial void cbw_keep_key_here(nint context, delegate* unmanaged[Cdecl]<nint, byte*, void> callback);
    [LibraryImport(Lib, StringMarshalling = StringMarshalling.Utf8)]
    internal static partial void cbw_board(string period, string provider, nint context, delegate* unmanaged[Cdecl]<nint, byte*, void> callback);
    [LibraryImport(Lib)] internal static partial void cbw_leave(nint context, delegate* unmanaged[Cdecl]<nint, byte*, void> callback);
    [LibraryImport(Lib)] internal static partial void cbw_export(nint context, delegate* unmanaged[Cdecl]<nint, byte*, void> callback);
    [LibraryImport(Lib)] internal static partial void cbw_request_device(nint context, delegate* unmanaged[Cdecl]<nint, byte*, void> callback);
    [LibraryImport(Lib)] internal static partial void cbw_wait_device(nint context, delegate* unmanaged[Cdecl]<nint, byte*, void> callback);
    [LibraryImport(Lib, StringMarshalling = StringMarshalling.Utf8)]
    internal static partial void cbw_join_device(string sharing, nint context, delegate* unmanaged[Cdecl]<nint, byte*, void> callback);
    [LibraryImport(Lib)] internal static partial void cbw_decline_device(nint context, delegate* unmanaged[Cdecl]<nint, byte*, void> callback);
    [LibraryImport(Lib)] internal static partial void cbw_cancel_device(nint context, delegate* unmanaged[Cdecl]<nint, byte*, void> callback);
    [LibraryImport(Lib)] internal static partial void cbw_hud_reading(nint context, delegate* unmanaged[Cdecl]<nint, byte*, void> callback);
    [LibraryImport(Lib)] internal static partial void cbw_hud_refresh(nint context, delegate* unmanaged[Cdecl]<nint, byte*, void> callback);
}

/// ClaudeBar's leaderboard and the HUD's limits, as Tasks. Each call replies once with JSON that
/// carries "state", and "error" when it failed. The reply comes on the UI
/// thread, which drains Swift's main queue (Pump); awaits resume there too.
internal static unsafe class Swift
{
    internal static string Version()
    {
        var text = Native.cbw_version();
        try { return Marshal.PtrToStringUTF8((nint)text) ?? ""; }
        finally { Native.cbw_free(text); }
    }

    internal static Task<JsonObject> State() { var (task, context) = Begin(); Native.cbw_state(context, &OnReply); return task; }
    internal static Task<JsonObject> Preview() { var (task, context) = Begin(); Native.cbw_preview(context, &OnReply); return task; }
    internal static Task<JsonObject> Join(string username, IEnumerable<string> sharing)
    {
        var (task, context) = Begin();
        Native.cbw_join(username, string.Join(",", sharing), context, &OnReply);
        return task;
    }
    internal static Task<JsonObject> SetSharing(string provider, bool shared)
    {
        var (task, context) = Begin();
        Native.cbw_set_sharing(provider, shared, context, &OnReply);
        return task;
    }
    internal static Task<JsonObject> SetVisible(bool visible) { var (task, context) = Begin(); Native.cbw_set_visible(visible, context, &OnReply); return task; }
    internal static Task<JsonObject> UploadNow() { var (task, context) = Begin(); Native.cbw_upload_now(context, &OnReply); return task; }
    internal static Task<JsonObject> KeepKeyHere() { var (task, context) = Begin(); Native.cbw_keep_key_here(context, &OnReply); return task; }
    internal static Task<JsonObject> Board(string period, string provider)
    {
        var (task, context) = Begin();
        Native.cbw_board(period, provider, context, &OnReply);
        return task;
    }
    internal static Task<JsonObject> Leave() { var (task, context) = Begin(); Native.cbw_leave(context, &OnReply); return task; }
    internal static Task<JsonObject> Export() { var (task, context) = Begin(); Native.cbw_export(context, &OnReply); return task; }
    internal static Task<JsonObject> RequestDevice() { var (task, context) = Begin(); Native.cbw_request_device(context, &OnReply); return task; }
    internal static Task<JsonObject> WaitDevice() { var (task, context) = Begin(); Native.cbw_wait_device(context, &OnReply); return task; }
    internal static Task<JsonObject> JoinDevice(IEnumerable<string> sharing)
    {
        var (task, context) = Begin();
        Native.cbw_join_device(string.Join(",", sharing), context, &OnReply);
        return task;
    }
    internal static Task<JsonObject> DeclineDevice() { var (task, context) = Begin(); Native.cbw_decline_device(context, &OnReply); return task; }
    internal static Task<JsonObject> CancelDevice() { var (task, context) = Begin(); Native.cbw_cancel_device(context, &OnReply); return task; }

    /// The HUD's reading (HudData): every signed-in tool's limits, from the
    /// numbers ClaudeBar's monitor holds now. The first call starts the monitor.
    internal static Task<JsonObject> HudReading() { var (task, context) = Begin(); Native.cbw_hud_reading(context, &OnReply); return task; }
    /// *Refresh*: reads every tool again, then replies as `HudReading` does.
    internal static Task<JsonObject> HudRefresh() { var (task, context) = Begin(); Native.cbw_hud_refresh(context, &OnReply); return task; }

    private static (Task<JsonObject>, nint) Begin()
    {
        var completion = new TaskCompletionSource<JsonObject>(TaskCreationOptions.RunContinuationsAsynchronously);
        return (completion.Task, GCHandle.ToIntPtr(GCHandle.Alloc(completion)));
    }

    [UnmanagedCallersOnly(CallConvs = new[] { typeof(CallConvCdecl) })]
    private static void OnReply(nint context, byte* json)
    {
        var handle = GCHandle.FromIntPtr(context);
        var completion = (TaskCompletionSource<JsonObject>)handle.Target!;
        handle.Free();
        // Nothing may throw here: an exception can't cross back into Swift, and the task must end.
        try
        {
            var text = Marshal.PtrToStringUTF8((nint)json) ?? "{}";
            completion.SetResult(JsonNode.Parse(text) as JsonObject ?? new JsonObject { ["error"] = "ClaudeBar's answer was empty." });
        }
        catch (Exception error)
        {
            completion.TrySetResult(new JsonObject { ["error"] = $"ClaudeBar's answer couldn't be read: {error.Message}" });
        }
    }
}
