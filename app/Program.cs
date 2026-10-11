using System.Diagnostics;
using System.Runtime.InteropServices;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;
using Microsoft.Windows.AppLifecycle;

namespace ClaudeBar;

/// One ClaudeBar at a time: a second launch (the Start menu, the taskbar's
/// jump list, a notification) hands its arguments to the running window and
/// ends, so there is never a second membership open on this PC.
public static partial class Program
{
    [STAThread]
    private static int Main(string[] args)
    {
        WinRT.ComWrappersSupport.InitializeComWrappers();
        var main = AppInstance.FindOrRegisterForKey("ClaudeBar.window");
        if (!main.IsCurrent)
        {
            Redirect(AppInstance.GetCurrent().GetActivatedEventArgs(), main);
            return 0;
        }
        Application.Start(parameters =>
        {
            SynchronizationContext.SetSynchronizationContext(new DispatcherQueueSynchronizationContext(DispatcherQueue.GetForCurrentThread()));
            _ = new App();
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
