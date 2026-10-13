using Microsoft.UI.Xaml;

namespace HudProbe;

public partial class App : Application
{
    private readonly string _mode;
    private Probe? _probe;

    public App(string mode)
    {
        _mode = mode;
        InitializeComponent();
    }

    protected override void OnLaunched(LaunchActivatedEventArgs args) => _probe = new Probe(_mode);
}
