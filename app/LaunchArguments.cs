using System.Text;
using System.Text.RegularExpressions;

namespace ClaudeBar;

/// What a launch asks for (`MainWindow.Open`): its own command line, a second
/// launch's handed over, or a notification button's action.
internal static class LaunchArguments
{
    /// A notification button's `action`. `AppNotificationBuilder` sends a
    /// button's arguments as `key=value;key=value`, each key and value with its
    /// `%`, `;` and `=` percent-encoded (WinAppSDK, AppNotificationBuilderUtility.h,
    /// `EncodeArgument`); this reads them back as its `Decode` does. Null when
    /// there's none: a click on the notification itself.
    internal static string? NotificationAction(string argument)
    {
        foreach (var pair in argument.Split(';'))
        {
            var equals = pair.IndexOf('=');
            var key = Decode(equals < 0 ? pair : pair[..equals]);
            if (key == "action" && equals >= 0) return Decode(pair[(equals + 1)..]);
        }
        return null;
    }

    /// The limit `--quiet=<limit>` asks to keep quiet, unescaped; null when it doesn't ask.
    internal static string? Quiet(string arguments) =>
        Regex.Match(arguments, @"--quiet=([^\s;&]+)") is { Success: true } quiet ? Uri.UnescapeDataString(quiet.Groups[1].Value) : null;

    /// The words a launch carries: `--hud`, `--board`, `--startup`, …
    internal static IReadOnlySet<string> Words(string arguments) =>
        Regex.Split(arguments, @"[\s;&=]+").Where(word => word != "").ToHashSet();

    /// WinAppSDK's three escapes, undone; anything else is left as it is.
    private static string Decode(string value)
    {
        var result = new StringBuilder(value.Length);
        for (var index = 0; index < value.Length;)
        {
            var escape = index + 3 <= value.Length ? value.Substring(index, 3) : "";
            var character = escape switch { "%25" => '%', "%3B" => ';', "%3D" => '=', _ => '\0' };
            if (character != '\0')
            {
                result.Append(character);
                index += 3;
            }
            else
            {
                result.Append(value[index]);
                index++;
            }
        }
        return result.ToString();
    }
}
