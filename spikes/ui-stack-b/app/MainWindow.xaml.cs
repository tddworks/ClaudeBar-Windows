using System.Diagnostics;
using System.Text.Json;
using System.Text.Json.Nodes;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls.Primitives;
using Microsoft.UI.Xaml.Media;

namespace ClaudeBarSpike;

public sealed partial class MainWindow : Window
{
    private readonly string[] _args;
    private CancellationTokenSource? _scan;
    private DispatcherQueueTimer? _pump;
    private bool _shown;
    private string? _brushProblem;

    public MainWindow(string[] args)
    {
        _args = args;
        InitializeComponent();
        AppWindow.Resize(new Windows.Graphics.SizeInt32(960, 1100));
        Activated += OnActivated;
    }

    private static string SessionsRoot() =>
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ".omp", "agent", "sessions");

    private async void OnActivated(object sender, WindowActivatedEventArgs e)
    {
        if (_shown) return;
        _shown = true;
        var at = Array.IndexOf(_args, "--selftest");
        var reportPath = at >= 0 && at + 1 < _args.Length ? _args[at + 1] : null;
        try
        {
            var shownMs = (DateTime.Now - Process.GetCurrentProcess().StartTime).TotalMilliseconds;
            var version = JsonNode.Parse(Native.Version())!;
            VersionText.Text = $"{version["library"]} · Swift {version["swift"]} · UI thread {Native.GetCurrentThreadId()} · "
                + $"window shown {shownMs:F0} ms after process start · {(Native.IsPackaged() ? "packaged (MSIX)" : "unpackaged")}";
            ShowQuota();
            RateLimitText.Text = "UsageError.rateLimited, 29 min 59 s from now: " + Native.RateLimitedText(1799);
            if (reportPath is not null) await RunSelfTest(reportPath, shownMs);
        }
        catch (Exception error)
        {
            // An async void handler's exception would otherwise vanish; show it and report it.
            DiagText.Text = error.ToString();
            if (reportPath is not null)
            {
                await File.WriteAllTextAsync(reportPath, new JsonObject { ["error"] = error.ToString() }.ToJsonString());
            }
        }
    }

    private void OnPercentChanged(object sender, RangeBaseValueChangedEventArgs e) => ShowQuota();

    private void ShowQuota()
    {
        if (QuotaText is null) return; // Slider's initial Value fires before the rest of the tree exists.
        var quota = JsonNode.Parse(Native.QuotaDescribe(PercentSlider.Value, "claude"))!;
        var status = quota["status"]!.GetValue<string>();
        QuotaText.Text = $"{status} · {quota["percentUsed"]}% used · needs attention: {quota["needsAttention"]}";
        var brush = status switch
        {
            "healthy" => "SystemFillColorSuccessBrush",
            "warning" => "SystemFillColorCautionBrush",
            _ => "SystemFillColorCriticalBrush",
        };
        // Under NativeAOT a looked-up resource comes back typed as the nearest projected type the
        // trimmer kept. Naming SolidColorBrush keeps it, so the lookup returns a usable brush.
        var resource = Application.Current.Resources[brush];
        if (resource is SolidColorBrush themed) QuotaText.Foreground = themed;
        else _brushProblem ??= $"Resources[\"{brush}\"] is {resource?.GetType().FullName ?? "null"}, not a SolidColorBrush";
    }

    private async void OnScan(object sender, RoutedEventArgs e) => await Scan(perFileDelayMs: 0);

    private async void OnSlowScan(object sender, RoutedEventArgs e) => await Scan(perFileDelayMs: 40);

    private void OnCancel(object sender, RoutedEventArgs e) => _scan?.Cancel();

    private async Task<Bridge.Reply> Scan(int perFileDelayMs, int cancelAfterMs = -1)
    {
        _scan = new CancellationTokenSource();
        if (cancelAfterMs >= 0) _scan.CancelAfter(cancelAfterMs);
        ScanButton.IsEnabled = SlowScanButton.IsEnabled = false;
        CancelButton.IsEnabled = true;
        Busy.IsActive = true;
        try
        {
            var reply = await Bridge.ScanSessionsAsync(SessionsRoot(), perFileDelayMs, _scan.Token);
            var scan = JsonNode.Parse(reply.Json)!;
            var megabytes = scan["bytes"]!.GetValue<long>() / 1048576.0;
            ScanText.Text = (scan["cancelled"]!.GetValue<bool>()
                    ? $"Cancelled after {scan["files"]} files ({scan["elapsedMs"]} ms)."
                    : $"{scan["files"]} session logs, {megabytes:F1} MB, newest {scan["newest"]} ({scan["elapsedMs"]} ms).")
                + $"\nSwift worker thread {scan["nativeThread"]} → callback on thread {reply.CallbackNativeThread}"
                + $" → await resumed on UI thread {Native.GetCurrentThreadId()}.";
            return reply;
        }
        finally
        {
            ScanButton.IsEnabled = SlowScanButton.IsEnabled = true;
            CancelButton.IsEnabled = false;
            Busy.IsActive = false;
        }
    }

    /// Drives Swift's main dispatch queue from the UI thread, because WinUI's
    /// message loop, not Swift, owns that thread. `drain` calls libdispatch's
    /// hook directly; otherwise the main RunLoop is run once per tick.
    private void StartPump(bool drain)
    {
        _pump?.Stop();
        _pump = DispatcherQueue.CreateTimer();
        _pump.Interval = TimeSpan.FromMilliseconds(16);
        if (drain) _pump.Tick += (_, _) => Native.cb_drain_main_queue();
        else _pump.Tick += (_, _) => Native.cb_pump_main();
        _pump.Start();
    }

    private static async Task<(bool Replied, Bridge.Reply? Reply)> Within(Task<Bridge.Reply> call, int milliseconds)
    {
        var replied = await Task.WhenAny(call, Task.Delay(milliseconds)) == call;
        return (replied, replied ? call.Result : null);
    }

    private async Task RunSelfTest(string outPath, double shownMs)
    {
        var uiThread = Native.GetCurrentThreadId();
        var report = new JsonObject
        {
            ["packaged"] = Native.IsPackaged(),
            ["windowShownMsAfterProcessStart"] = Math.Round(shownMs),
            ["uiNativeThread"] = uiThread,
            ["version"] = JsonNode.Parse(Native.Version()),
        };

        var quotas = new JsonArray();
        foreach (var percent in new[] { 85.0, 35.0, 10.0, 0.0 })
        {
            quotas.Add(JsonNode.Parse(Native.QuotaDescribe(percent, "claude")));
        }
        report["quotaDescribe"] = quotas;
        report["rateLimitedText1799s"] = Native.RateLimitedText(1799);
        report["themeBrushLookup"] = _brushProblem ?? "ok";

        var clock = Stopwatch.StartNew();
        var scan = await Scan(perFileDelayMs: 0);
        report["scan"] = new JsonObject
        {
            ["result"] = JsonNode.Parse(scan.Json),
            ["callbackNativeThread"] = scan.CallbackNativeThread,
            ["callbackManagedThread"] = scan.CallbackManagedThread,
            ["resumedOnNativeThread"] = Native.GetCurrentThreadId(),
            ["resumedOnUiThread"] = Native.GetCurrentThreadId() == uiThread,
            ["roundTripMs"] = clock.ElapsedMilliseconds,
        };

        clock.Restart();
        var slow = await Scan(perFileDelayMs: 40, cancelAfterMs: 300);
        report["slowScanCancelledAfter300ms"] = new JsonObject
        {
            ["result"] = JsonNode.Parse(slow.Json),
            ["roundTripMs"] = clock.ElapsedMilliseconds,
        };

        // MainActor work: no pump, then RunLoop.main once per tick, then libdispatch's drain hook.
        var probes = new (string Name, Task<Bridge.Reply> Call)[3];
        var mainActor = new JsonObject();
        probes[0] = ("noPump", Bridge.MainActorProbeAsync());
        var replied = await Within(probes[0].Call, 2000);
        mainActor["noPump"] = replied.Replied ? JsonNode.Parse(replied.Reply!.Json) : "no reply within 2 s";
        StartPump(drain: false);
        probes[1] = ("runLoopPump", Bridge.MainActorProbeAsync());
        replied = await Within(probes[1].Call, 2000);
        mainActor["runLoopPump"] = replied.Replied ? JsonNode.Parse(replied.Reply!.Json) : "no reply within 2 s";
        StartPump(drain: true);
        probes[2] = ("drainPump", Bridge.MainActorProbeAsync());
        replied = await Within(probes[2].Call, 2000);
        mainActor["drainPump"] = replied.Replied ? JsonNode.Parse(replied.Reply!.Json) : "no reply within 2 s";
        await Task.Delay(500);
        mainActor["repliedByEnd"] = new JsonArray(probes.Select(p => (JsonNode?)$"{p.Name}: {p.Call.IsCompleted}").ToArray());
        report["mainActor"] = mainActor;
        report["pendingCallbacks"] = Bridge.Pending;

        var modules = new JsonArray();
        foreach (ProcessModule module in Process.GetCurrentProcess().Modules)
        {
            var name = module.ModuleName.ToLowerInvariant();
            if (name.StartsWith("swift") || name.StartsWith("foundation") || name.StartsWith("_foundation")
                || name is "dispatch.dll" or "blocksruntime.dll" or "claudebarkitnative.dll" or "microsoft.ui.xaml.dll")
            {
                modules.Add((JsonNode?)JsonValue.Create($"{module.ModuleName} <- {Path.GetDirectoryName(module.FileName)}"));
            }
        }
        report["appDirectory"] = AppContext.BaseDirectory;
        report["loadedModules"] = modules;

        var process = Process.GetCurrentProcess();
        process.Refresh();
        report["workingSetMB"] = Math.Round(process.WorkingSet64 / 1048576.0, 1);
        report["privateMB"] = Math.Round(process.PrivateMemorySize64 / 1048576.0, 1);

        var text = report.ToJsonString(new JsonSerializerOptions { WriteIndented = true });
        DiagText.Text = text;
        await File.WriteAllTextAsync(outPath, text);

        var hold = Array.IndexOf(_args, "--hold");
        if (hold >= 0 && hold + 1 < _args.Length && int.TryParse(_args[hold + 1], out var seconds))
        {
            await Task.Delay(TimeSpan.FromSeconds(seconds));
            Application.Current.Exit();
        }
    }
}
