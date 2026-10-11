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
    [LibraryImport(Lib, StringMarshalling = StringMarshalling.Utf8)]
    internal static partial void cbw_board(string period, string provider, nint context, delegate* unmanaged[Cdecl]<nint, byte*, void> callback);
    [LibraryImport(Lib)] internal static partial void cbw_leave(nint context, delegate* unmanaged[Cdecl]<nint, byte*, void> callback);
    [LibraryImport(Lib)] internal static partial void cbw_export(nint context, delegate* unmanaged[Cdecl]<nint, byte*, void> callback);
}

/// ClaudeBar's leaderboard, as Tasks. Each call replies once with JSON that
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
    internal static Task<JsonObject> Board(string period, string provider)
    {
        var (task, context) = Begin();
        Native.cbw_board(period, provider, context, &OnReply);
        return task;
    }
    internal static Task<JsonObject> Leave() { var (task, context) = Begin(); Native.cbw_leave(context, &OnReply); return task; }
    internal static Task<JsonObject> Export() { var (task, context) = Begin(); Native.cbw_export(context, &OnReply); return task; }

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
        var text = Marshal.PtrToStringUTF8((nint)json) ?? "{}";
        completion.SetResult(JsonNode.Parse(text) as JsonObject ?? new JsonObject());
    }
}
