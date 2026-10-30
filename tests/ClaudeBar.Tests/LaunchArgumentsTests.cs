using ClaudeBar;

namespace ClaudeBar.Tests;

/// What a notification's button hands the app, and what `MainWindow.Open`
/// reads from it. A button's arguments arrive as `AppNotificationBuilder`
/// wrote them: `key=value`, each part's `%`, `;` and `=` percent-encoded
/// (WinAppSDK, AppNotificationBuilderUtility.h, `EncodeArgument`).
[TestClass]
public sealed class LaunchArgumentsTests
{
    [TestMethod]
    public void Should_read_the_quiet_button_s_limit_back_as_it_was()
    {
        // The button for `omp/Kimi 7d · 5%`: `--quiet=` and the key, escaped by
        // the app (Uri.EscapeDataString), then by the builder.
        const string argument = "action=--quiet%3Domp%252FKimi%25207d%2520%25C2%25B7%25205%2525";

        var action = LaunchArguments.NotificationAction(argument);

        Assert.AreEqual("--quiet=omp%2FKimi%207d%20%C2%B7%205%25", action);
        Assert.AreEqual("omp/Kimi 7d · 5%", LaunchArguments.Quiet(action!));
    }

    [TestMethod]
    public void Should_read_the_quiet_limit_of_a_signed_in_account_as_NotificationInvoked_delivers_it()
    {
        // `NotificationInvoked`'s Argument on the PC for an omp account's Claude 7d,
        // the account's name replaced: the running app gets it, not a second launch.
        const string argument = "action=--quiet%3Domp%252FClaude%25207d%2520%25C2%25B7%2520someone0123";

        var action = LaunchArguments.NotificationAction(argument);

        Assert.AreEqual("--quiet=omp%2FClaude%207d%20%C2%B7%20someone0123", action);
        Assert.AreEqual("omp/Claude 7d · someone0123", LaunchArguments.Quiet(action!));
    }

    [TestMethod]
    public void Should_read_a_plain_button()
    {
        var action = LaunchArguments.NotificationAction("action=--board");

        Assert.AreEqual("--board", action);
        Assert.IsTrue(LaunchArguments.Words(action!).Contains("--board"));
        Assert.IsNull(LaunchArguments.Quiet(action!));
    }

    [TestMethod]
    public void Should_find_the_action_among_other_arguments()
    {
        Assert.AreEqual("--hud", LaunchArguments.NotificationAction("conversation=9813;action=--hud;flag"));
    }

    [TestMethod]
    public void Should_have_no_action_for_a_click_on_the_notification_itself()
    {
        Assert.IsNull(LaunchArguments.NotificationAction(""));
    }

    [TestMethod]
    public void Should_read_the_limit_of_a_quiet_launch_from_the_command_line()
    {
        Assert.AreEqual("claude/5h", LaunchArguments.Quiet("--quiet=claude%2F5h"));
        Assert.IsTrue(LaunchArguments.Words("--startup --hud").SetEquals(new[] { "--startup", "--hud" }));
    }
}
