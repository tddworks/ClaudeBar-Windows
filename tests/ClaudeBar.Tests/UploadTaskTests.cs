using ClaudeBar;

namespace ClaudeBar.Tests;

/// Where the hourly upload's task points, read from `schtasks /Query /XML`, and
/// whether it must be pointed at this copy's uploader: after Setup replaces a
/// zip install, or an update (docs/plans/2026-11-02-updates-design.md).
[TestClass]
public sealed class UploadTaskTests
{
    /// The task on the PC, made by 0.1.6 from the zip, its user's SID and name replaced.
    private const string ZipTask = """
        <?xml version="1.0" encoding="UTF-16"?>
        <Task version="1.2" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
          <RegistrationInfo>
            <Date>2026-11-02T17:08:49</Date>
            <Author>PC\someone</Author>
            <URI>\ClaudeBar Leaderboard upload</URI>
          </RegistrationInfo>
          <Principals>
            <Principal id="Author">
              <UserId>S-1-5-21-0-0-0-1001</UserId>
              <LogonType>InteractiveToken</LogonType>
            </Principal>
          </Principals>
          <Triggers>
            <TimeTrigger>
              <StartBoundary>2026-11-02T17:08:00</StartBoundary>
              <Repetition>
                <Interval>PT1H</Interval>
              </Repetition>
            </TimeTrigger>
          </Triggers>
          <Actions Context="Author">
            <Exec>
              <Command>"C:\Users\someone\AppData\Local\Programs\ClaudeBar\ClaudeBar\claudebar-upload.exe"</Command>
            </Exec>
          </Actions>
        </Task>
        """;

    private const string Installed = @"C:\Users\someone\AppData\Local\ClaudeBarWindows\current\claudebar-upload.exe";

    [TestMethod]
    public void Should_read_the_uploader_the_task_runs()
    {
        Assert.AreEqual(@"C:\Users\someone\AppData\Local\Programs\ClaudeBar\ClaudeBar\claudebar-upload.exe", UploadTask.Command(ZipTask));
    }

    [TestMethod]
    public void Should_point_a_zip_install_s_task_at_the_installed_uploader()
    {
        Assert.IsFalse(UploadTask.PointsAt(UploadTask.Command(ZipTask), Installed));
    }

    [TestMethod]
    public void Should_leave_a_task_that_already_runs_this_uploader()
    {
        var installed = ZipTask.Replace(@"Programs\ClaudeBar\ClaudeBar", @"ClaudeBarWindows\current");

        Assert.IsTrue(UploadTask.PointsAt(UploadTask.Command(installed), Installed));
        // Windows paths ignore case, and the command may come without its quotes.
        Assert.IsTrue(UploadTask.PointsAt(Installed.ToUpperInvariant(), Installed));
    }

    [TestMethod]
    public void Should_point_the_task_again_when_its_command_can_t_be_read()
    {
        Assert.IsNull(UploadTask.Command(""));
        Assert.IsNull(UploadTask.Command("ERROR: The system cannot find the file specified."));
        Assert.IsNull(UploadTask.Command("<Task xmlns=\"http://schemas.microsoft.com/windows/2004/02/mit/task\"><Actions /></Task>"));
        Assert.IsFalse(UploadTask.PointsAt(null, Installed));
    }
}
