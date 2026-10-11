using Microsoft.UI.Xaml;
using Microsoft.Windows.AppLifecycle;
using Microsoft.Windows.AppNotifications;
using Microsoft.Windows.AppNotifications.Builder;

namespace ClaudeBar;

public partial class App : Application
{
    private MainWindow? _window;

    public App()
    {
        InitializeComponent();
    }

    protected override void OnLaunched(LaunchActivatedEventArgs args)
    {
        // A notification clicked, or a second launch handed over (Program.Main): the open window takes it.
        AppNotificationManager.Default.NotificationInvoked += (_, invoked) => _window?.DispatcherQueue.TryEnqueue(() => _window.Open(invoked.Argument));
        try { AppNotificationManager.Default.Register(); }
        catch (Exception) { /* No notifications on this PC; the window says everything too. */ }
        AppInstance.GetCurrent().Activated += (_, activated) => _window?.DispatcherQueue.TryEnqueue(() => _window.Open(Arguments(activated)));

        _window = new MainWindow();
        _window.Closed += (_, _) =>
        {
            try { AppNotificationManager.Default.Unregister(); } catch (Exception) { }
        };
        _window.Activate();
        _window.Open(Arguments(AppInstance.GetCurrent().GetActivatedEventArgs()));
    }

    private static string Arguments(AppActivationArguments activation) => activation.Data switch
    {
        Windows.ApplicationModel.Activation.ILaunchActivatedEventArgs launch => launch.Arguments ?? "",
        AppNotificationActivatedEventArgs notification => notification.Argument,
        _ => "",
    };

    /// A Windows notification, with *Open the board*; few of them (design-concept/leaderboard).
    internal static void Notify(string title, string body)
    {
        try
        {
            var notification = new AppNotificationBuilder()
                .AddText(title)
                .AddText(body)
                .AddButton(new AppNotificationButton("Open the board").AddArgument("action", "--board"))
                .BuildNotification();
            AppNotificationManager.Default.Show(notification);
        }
        catch (Exception) { /* The window says it too. */ }
    }
}
