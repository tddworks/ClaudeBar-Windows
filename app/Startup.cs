using Microsoft.Win32;

namespace ClaudeBar;

/// Starting with Windows, once the person accepts it (design: offered once,
/// after the first reading, off until accepted). Unpackaged, as the app is
/// today, it's a Run entry for this user, which Windows lists in Settings →
/// Apps → Startup, where it can be turned off too.
internal static class Startup
{
    private const string RunKey = @"Software\Microsoft\Windows\CurrentVersion\Run";
    private const string Name = "ClaudeBar";

    private static string Command => $"\"{Environment.ProcessPath}\" --startup";

    internal static bool IsEnabled
    {
        get
        {
            using var key = Registry.CurrentUser.OpenSubKey(RunKey);
            return key?.GetValue(Name) is string;
        }
    }

    internal static void Set(bool enabled)
    {
        using var key = Registry.CurrentUser.CreateSubKey(RunKey);
        if (enabled) key.SetValue(Name, Command);
        else key.DeleteValue(Name, throwOnMissingValue: false);
    }

    /// A copy in another folder (Setup's, after the zip's) takes the entry over
    /// from the old one, as the hourly upload's task does, rather than leave it
    /// on a deleted path.
    internal static void Adopt()
    {
        using var key = Registry.CurrentUser.OpenSubKey(RunKey, writable: true);
        if (key?.GetValue(Name) is string command && command != Command) key.SetValue(Name, Command);
    }

    /// For the uninstall hook: the entry goes with this copy, unless it starts another.
    internal static void Remove()
    {
        using var key = Registry.CurrentUser.OpenSubKey(RunKey, writable: true);
        if (key?.GetValue(Name) is string command && command == Command) key.DeleteValue(Name, throwOnMissingValue: false);
    }
}
