using Microsoft.UI.Xaml;

namespace ClaudeBarSpike;

public partial class App : Application
{
    private MainWindow? _window;

    public App()
    {
        InitializeComponent();
    }

    protected override void OnLaunched(LaunchActivatedEventArgs args)
    {
        _window = new MainWindow(Environment.GetCommandLineArgs());
        _window.Activate();
    }
}
