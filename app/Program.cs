using System.Diagnostics;
using System.Runtime.InteropServices;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;
using Microsoft.Windows.AppLifecycle;
using Velopack;

namespace ClaudeBar;

/// One ClaudeBar at a time: a second launch (the Start menu, the taskbar's
/// jump list, a notification) hands its arguments to the running window and
/// ends, so there is never a second membership open on this PC.
public static partial class Program
{
    /// The version Velopack just updated this copy to, for the window to say so; null otherwise.
    internal static string? UpdatedTo { get; private set; }

    [STAThread]
    private static int Main(string[] args)
    {
        // First, as Velopack requires: Setup, Update.exe and the uninstaller run
        // this exe with a hook's arguments, and it ends here after the hook
        // (docs/plans/2026-11-02-updates-design.md). The hooks show no UI.
        VelopackApp.Build()
            .OnAfterInstallFastCallback(_ => Uploads.FollowThisCopy())
            .OnAfterUpdateFastCallback(_ => Uploads.FollowThisCopy())
            .OnBeforeUninstallFastCallback(_ =>
            {
                // First, while the probe is still there: a deleted file keeps
                // running in a distro (docs/plans/2026-11-03-wsl-design.md, An uninstall).
                try { Native.cbw_wsl_end_all(); } catch (Exception) { }
                Uploads.Remove();
                Startup.Remove();
            })
            .OnRestarted(version => UpdatedTo = version.ToString())
            .Run();
        // A check's entry, as --hud-check is (scripts/check-wsl.ps1 runs it):
        // ends every probe in every running distro, as an uninstall does. Not
        // in the Start menu or the jump list.
        if (args.Contains("--wsl-end-all"))
        {
            Native.cbw_wsl_end_all();
            return 0;
        }
        WinRT.ComWrappersSupport.InitializeComWrappers();
        // The HUD's check (HudCheck.cs) runs beside the real ClaudeBar: it opens no membership.
        if (args.Contains("--hud-check"))
        {
            Application.Start(parameters =>
            {
                SynchronizationContext.SetSynchronizationContext(new DispatcherQueueSynchronizationContext(DispatcherQueue.GetForCurrentThread()));
                _ = new App(args);
            });
            return 0;
        }
        var main = AppInstance.FindOrRegisterForKey("ClaudeBar.window");
        if (!main.IsCurrent)
        {
            Redirect(AppInstance.GetCurrent().GetActivatedEventArgs(), main);
            return 0;
        }
        Application.Start(parameters =>
        {
            SynchronizationContext.SetSynchronizationContext(new DispatcherQueueSynchronizationContext(DispatcherQueue.GetForCurrentThread()));
            _ = new App(args);
        });
        return 0;
    }

    /// Redirects off the UI thread and waits without blocking COM, as the
    /// Windows App SDK's single-instancing guide does, then brings the window forward.
    private static void Redirect(AppActivationArguments arguments, AppInstance main)
    {
        var done = CreateEventW(IntPtr.Zero, true, false, null);
        Task.Run(() =>
        {
            // Set even when the redirect fails (the main instance ended meanwhile), or this one waits forever.
            try { main.RedirectActivationToAsync(arguments).AsTask().Wait(); }
            catch (Exception) { }
            finally { SetEvent(done); }
        });
        _ = CoWaitForMultipleObjects(0, 0xFFFFFFFF, 1, new[] { done }, out _);
        try { SetForegroundWindow(Process.GetProcessById((int)main.ProcessId).MainWindowHandle); }
        catch (ArgumentException) { }
    }

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)]
    private static extern IntPtr CreateEventW(IntPtr attributes, bool manualReset, bool initialState, string? name);

    [DllImport("kernel32.dll")]
    private static extern bool SetEvent(IntPtr handle);

    [DllImport("ole32.dll")]
    private static extern uint CoWaitForMultipleObjects(uint flags, uint timeout, uint count, IntPtr[] handles, out uint index);

    [DllImport("user32.dll")]
    private static extern bool SetForegroundWindow(IntPtr window);
}
