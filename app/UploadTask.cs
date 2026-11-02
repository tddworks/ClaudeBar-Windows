using System.Xml;
using System.Xml.Linq;

namespace ClaudeBar;

/// Where the hourly upload's task points, read from `schtasks /Query /XML`.
internal static class UploadTask
{
    private static readonly XNamespace Task = "http://schemas.microsoft.com/windows/2004/02/mit/task";

    /// The program the task runs, without its quotes; null when the answer
    /// isn't a task with one (no task, an error, a garbled answer).
    internal static string? Command(string xml)
    {
        try
        {
            var command = XDocument.Parse(xml).Root?.Element(Task + "Actions")?.Element(Task + "Exec")?.Element(Task + "Command")?.Value;
            return string.IsNullOrWhiteSpace(command) ? null : command.Trim().Trim('"');
        }
        catch (XmlException) { return null; }
    }

    /// Whether `command` already runs `uploader`; Windows paths ignore case.
    internal static bool PointsAt(string? command, string uploader) =>
        command is not null && string.Equals(command.Trim().Trim('"'), uploader, StringComparison.OrdinalIgnoreCase);
}
