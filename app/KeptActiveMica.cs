using Microsoft.UI.Composition;
using Microsoft.UI.Composition.SystemBackdrops;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Media;

namespace ClaudeBar;

/// Mica whose configuration stays active. The framework's configuration
/// follows activation, and the HUD is never the active window except for a
/// moment after a click, so the system's own Mica would sit at its solid
/// inactive colour and flicker to the active tint on each click (measured,
/// design-concept/hud/research.md).
internal sealed class KeptActiveMica : SystemBackdrop
{
    private MicaController? _controller;
    private SystemBackdropConfiguration? _configuration;

    protected override void OnTargetConnected(ICompositionSupportsSystemBackdrop target, XamlRoot xamlRoot)
    {
        base.OnTargetConnected(target, xamlRoot);
        _configuration = new SystemBackdropConfiguration { IsInputActive = true, Theme = Theme(xamlRoot) };
        if (xamlRoot.Content is FrameworkElement root)
            root.ActualThemeChanged += (_, _) => { if (_configuration is { } c) c.Theme = Theme(xamlRoot); };
        _controller = new MicaController { Kind = MicaKind.Base };
        _controller.AddSystemBackdropTarget(target);
        _controller.SetSystemBackdropConfiguration(_configuration);
    }

    protected override void OnTargetDisconnected(ICompositionSupportsSystemBackdrop target)
    {
        base.OnTargetDisconnected(target);
        _controller?.RemoveSystemBackdropTarget(target);
        _controller?.Dispose();
        _controller = null;
    }

    private static SystemBackdropTheme Theme(XamlRoot root) =>
        (root.Content as FrameworkElement)?.ActualTheme == ElementTheme.Light ? SystemBackdropTheme.Light : SystemBackdropTheme.Dark;
}
