using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;

namespace HudProbe;

public static class Program
{
    [STAThread]
    private static int Main(string[] args)
    {
        WinRT.ComWrappersSupport.InitializeComWrappers();
        var mode = args.Length > 0 ? args[0] : "default";
        Application.Start(parameters =>
        {
            SynchronizationContext.SetSynchronizationContext(new DispatcherQueueSynchronizationContext(DispatcherQueue.GetForCurrentThread()));
            _ = new App(mode);
        });
        return 0;
    }
}
