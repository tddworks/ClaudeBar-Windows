using Microsoft.UI.Xaml;
using Microsoft.Windows.AppLifecycle;
using Microsoft.Windows.AppNotifications;
using Microsoft.Windows.AppNotifications.Builder;

namespace ClaudeBar;

public partial class App : Application
{
    private readonly string[] _arguments;
    private MainWindow? _window;
    /// The HUD's check, kept alive while it runs.
    internal HudCheck? Check { get; private set; }

    public App(string[] arguments)
    {
        _arguments = arguments;
        InitializeComponent();
    }

    protected override void OnLaunched(LaunchActivatedEventArgs args)
    {
        if (_arguments.Contains("--hud-check"))
        {
            Check = new HudCheck(_arguments);
            return;
        }
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
        _window.Start();
        // Opens the window, unless the launch is for the HUD alone (signed in, or a notification's action).
        _window.Open(Arguments(AppInstance.GetCurrent().GetActivatedEventArgs()));
    }

    private static string Arguments(AppActivationArguments activation) => activation.Data switch
    {
        Windows.ApplicationModel.Activation.ILaunchActivatedEventArgs launch => launch.Arguments ?? "",
        AppNotificationActivatedEventArgs notification => notification.Argument,
        _ => "",
    };

    /// A Windows notification; few of them (design-concept/leaderboard, and the
    /// HUD's crossings). Its buttons run launch arguments through the open
    /// window (`MainWindow.Open`); *Open the board* when none are given.
    internal static void Notify(string title, string body, params (string Label, string Arguments)[] buttons)
    {
        try
        {
            var builder = new AppNotificationBuilder().AddText(title).AddText(body);
            foreach (var (label, arguments) in buttons.Length > 0 ? buttons : new[] { ("Open the board", "--board") })
                builder.AddButton(new AppNotificationButton(label).AddArgument("action", arguments));
            AppNotificationManager.Default.Show(builder.BuildNotification());
        }
        catch (Exception) { /* The window says it too. */ }
    }
}
