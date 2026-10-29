using Microsoft.UI.Composition;
using Microsoft.UI.Composition.SystemBackdrops;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Media;

namespace ClaudeBar;

/// Mica whose configuration stays active. The framework's configuration
/// follows activation, and the HUD is never the active window except for a
/// moment after a click, so the system's own Mica would sit at its solid
/// inactive colour and flicker to the active tint on each click (measured,
/// design-concept/hud/research.md). Its own configuration, so it takes the
/// theme itself, and never the framework's default one.
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

    /// Windows' theme or contrast changed: the framework's default configuration
    /// did, which this material doesn't use. Not passed to the base: it updates
    /// that default for this target, and threw ArgumentException ("target",
    /// E_INVALIDARG) on a Windows theme switch, which XAML turned into a fail-fast
    /// (0xC000027B in combase), seen with the HUD up on the PC.
    protected override void OnDefaultSystemBackdropConfigurationChanged(ICompositionSupportsSystemBackdrop target, XamlRoot xamlRoot)
    {
        if (_configuration is { } c) c.Theme = Theme(xamlRoot);
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
