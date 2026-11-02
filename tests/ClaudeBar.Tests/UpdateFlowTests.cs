using ClaudeBar;

namespace ClaudeBar.Tests;

/// What Settings → Updates says and offers, from a start to a restart
/// (docs/plans/2026-11-02-updates-design.md, What the person sees).
[TestClass]
public sealed class UpdateFlowTests
{
    private static readonly DateTimeOffset Now = new(2026, 11, 2, 10, 42, 0, TimeSpan.Zero);
    private static string Clock(DateTimeOffset at) => at.ToString("HH:mm");

    [TestMethod]
    public void Should_say_updates_come_with_the_installed_app_for_a_copy_setup_didnt_install()
    {
        var status = UpdateStatus.Start("0.1.8", installed: false);

        Assert.AreEqual(UpdatePhase.NotInstalled, status.Phase);
        Assert.IsFalse(status.CanCheck);
        Assert.IsFalse(status.CanUpdate);
        Assert.AreEqual("ClaudeBar for Windows 0.1.8", status.Title);
        Assert.AreEqual("Updates come with the installed app: install it with Setup.exe from Releases.", status.Detail(Clock));
        Assert.AreSame(status, status.Checking());
    }

    [TestMethod]
    public void Should_find_a_newer_version_and_offer_update()
    {
        var status = UpdateStatus.Start("0.1.8", installed: true).Checking();
        Assert.AreEqual(UpdatePhase.Checking, status.Phase);
        Assert.IsFalse(status.CanCheck);
        Assert.AreEqual("Checking for updates…", status.Detail(Clock));

        status = status.Checked("0.1.9", Now);

        Assert.AreEqual(UpdatePhase.Available, status.Phase);
        Assert.AreEqual("0.1.9", status.Available);
        Assert.IsTrue(status.CanUpdate);
        Assert.IsTrue(status.CanCheck);
        Assert.AreEqual("0.1.9 is available. Update downloads it, installs it and restarts ClaudeBar.", status.Detail(Clock));
    }

    [TestMethod]
    public void Should_say_up_to_date_and_when_it_checked()
    {
        var status = UpdateStatus.Start("0.1.9", installed: true).Checking().Checked(null, Now);

        Assert.AreEqual(UpdatePhase.UpToDate, status.Phase);
        Assert.IsNull(status.Available);
        Assert.IsFalse(status.CanUpdate);
        Assert.AreEqual("Up to date · checked 10:42", status.Detail(Clock));
    }

    [TestMethod]
    public void Should_keep_offering_a_found_version_when_a_later_check_fails()
    {
        var status = UpdateStatus.Start("0.1.8", installed: true).Checking().Checked("0.1.9", Now)
            .Checking().CheckFailed("No internet connection.");

        Assert.AreEqual(UpdatePhase.Failed, status.Phase);
        Assert.IsTrue(status.CanUpdate);
        Assert.IsTrue(status.CanCheck);
        Assert.AreEqual("Couldn't check for updates. No internet connection. 0.1.9 is still available.", status.Detail(Clock));
    }

    [TestMethod]
    public void Should_show_the_download_then_the_restart_and_allow_nothing_else_meanwhile()
    {
        var status = UpdateStatus.Start("0.1.8", installed: true).Checking().Checked("0.1.9", Now).Downloading(0);

        Assert.AreEqual(UpdatePhase.Downloading, status.Phase);
        Assert.IsFalse(status.CanCheck);
        Assert.IsFalse(status.CanUpdate);
        Assert.AreSame(status, status.Checking());
        Assert.AreEqual("Downloading 0.1.9… 42%", status.Downloading(42).Detail(Clock));

        status = status.Restarting();

        Assert.AreEqual(UpdatePhase.Restarting, status.Phase);
        Assert.IsFalse(status.CanCheck);
        Assert.IsFalse(status.CanUpdate);
        Assert.AreEqual("Installing 0.1.9 and restarting ClaudeBar…", status.Detail(Clock));
    }

    [TestMethod]
    public void Should_offer_update_again_after_a_failed_download()
    {
        var status = UpdateStatus.Start("0.1.8", installed: true).Checking().Checked("0.1.9", Now)
            .Downloading(30).DownloadFailed("The package failed its SHA-256 check.");

        Assert.AreEqual(UpdatePhase.Failed, status.Phase);
        Assert.IsTrue(status.CanUpdate);
        Assert.AreEqual("Couldn't update. The package failed its SHA-256 check. 0.1.9 is still available.", status.Detail(Clock));
    }

    [TestMethod]
    public void Should_offer_update_again_when_update_exe_can_t_start()
    {
        // The download finished, then starting Update.exe failed: nothing quits, so the person must be able to try again.
        var status = UpdateStatus.Start("0.1.8", installed: true).Checking().Checked("0.1.9", Now)
            .Downloading(100).Restarting().DownloadFailed("Update.exe wasn't found.");

        Assert.AreEqual(UpdatePhase.Failed, status.Phase);
        Assert.IsTrue(status.CanUpdate);
        Assert.IsTrue(status.CanCheck);
        Assert.AreEqual("Couldn't update. Update.exe wasn't found. 0.1.9 is still available.", status.Detail(Clock));
    }

    [TestMethod]
    public void Should_not_download_when_nothing_was_found()
    {
        var status = UpdateStatus.Start("0.1.9", installed: true).Checking().Checked(null, Now);

        Assert.AreSame(status, status.Downloading(0));
    }

    [TestMethod]
    public void Should_notify_once_per_new_version()
    {
        Assert.IsTrue(UpdateStatus.ShouldNotify("0.1.9", notified: null, current: "0.1.8"));
        Assert.IsFalse(UpdateStatus.ShouldNotify("0.1.9", notified: "0.1.9", current: "0.1.8"), "already told");
        Assert.IsTrue(UpdateStatus.ShouldNotify("0.1.10", notified: "0.1.9", current: "0.1.8"), "a newer one, by number, not by text");
        Assert.IsFalse(UpdateStatus.ShouldNotify("0.1.9", notified: "0.1.10", current: "0.1.8"), "older than one already told");
        Assert.IsFalse(UpdateStatus.ShouldNotify("0.1.8", notified: null, current: "0.1.8"), "the installed one");
        Assert.IsFalse(UpdateStatus.ShouldNotify("0.1.8-local.1", notified: null, current: "0.1.8"), "a pre-release before it");
        Assert.IsTrue(UpdateStatus.ShouldNotify("0.1.8-local.2", notified: "0.1.8-local.1", current: "0.1.8-local.1"));
    }

    [TestMethod]
    public void Should_wait_after_a_start_check_every_four_hours_and_try_again_soon_when_busy_or_failed()
    {
        Assert.AreEqual(TimeSpan.FromMinutes(2), UpdateSchedule.After(UpdateSchedule.Outcome.Started));
        Assert.AreEqual(TimeSpan.FromHours(4), UpdateSchedule.After(UpdateSchedule.Outcome.Checked));
        Assert.AreEqual(TimeSpan.FromMinutes(15), UpdateSchedule.After(UpdateSchedule.Outcome.Busy));
        Assert.AreEqual(TimeSpan.FromHours(1), UpdateSchedule.After(UpdateSchedule.Outcome.Failed));
    }

    [TestMethod]
    public void Should_count_a_full_screen_app_a_game_or_a_presentation_as_busy()
    {
        // SHQueryUserNotificationState's QUERY_USER_NOTIFICATION_STATE.
        Assert.IsFalse(UpdateSchedule.Busy(1), "QUNS_NOT_PRESENT: the screen is locked or off");
        Assert.IsTrue(UpdateSchedule.Busy(2), "QUNS_BUSY: a full-screen app");
        Assert.IsTrue(UpdateSchedule.Busy(3), "QUNS_RUNNING_D3D_FULL_SCREEN: a game");
        Assert.IsTrue(UpdateSchedule.Busy(4), "QUNS_PRESENTATION_MODE");
        Assert.IsFalse(UpdateSchedule.Busy(5), "QUNS_ACCEPTS_NOTIFICATIONS");
        Assert.IsFalse(UpdateSchedule.Busy(6), "QUNS_QUIET_TIME: the first hour after setup");
        Assert.IsTrue(UpdateSchedule.Busy(7), "QUNS_APP: a full-screen Store app");
    }

    [TestMethod]
    public void Should_read_this_repo_s_releases_unless_a_local_feed_is_set()
    {
        var github = UpdateFeed.Choose(null);
        Assert.IsFalse(github.Local);
        Assert.AreEqual("https://github.com/tddworks/ClaudeBar-Windows", github.Location);
        Assert.IsTrue(github.Prereleases, "every release so far is a pre-release");

        Assert.IsFalse(UpdateFeed.Choose("  ").Local);

        var local = UpdateFeed.Choose(@"H:\feed");
        Assert.IsTrue(local.Local);
        Assert.AreEqual(@"H:\feed", local.Location);
    }
}
