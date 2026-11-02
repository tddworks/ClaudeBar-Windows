using System.Text.Json.Nodes;
using ClaudeBar;

namespace ClaudeBar.Tests;

/// The notes and the plan beside a tool's limits (docs/plans/2026-10-13-hud-design.md,
/// Notes and plans): every one on the Limits page; on the HUD only an account
/// omp signed out, as a tool that needs you.
[TestClass]
public sealed class HudNotesTests
{
    private static readonly DateTimeOffset Now = new(2026, 11, 2, 12, 0, 0, TimeSpan.Zero);

    private static JsonObject Line(string window, int percent, string status = "healthy") => new()
    {
        ["key"] = $"time:{window}", ["window"] = window, ["percentLeft"] = percent, ["resetsAt"] = Now.AddHours(2).ToUnixTimeSeconds(),
        ["windowSeconds"] = 604800, ["status"] = status, ["runningHot"] = false, ["tick"] = 40.0, ["strip"] = true,
    };

    private static JsonObject Note(string value, string? label = null, string unit = "")
    {
        var note = new JsonObject { ["value"] = value, ["unit"] = unit };
        if (label is not null) note["label"] = label;
        return note;
    }

    private static JsonObject Tool(string id, JsonObject[] lines, JsonObject[]? notes = null, string? tier = null, bool signedOut = false)
    {
        var tool = new JsonObject
        {
            ["id"] = id, ["lines"] = new JsonArray(lines.Select(line => (JsonNode?)line).ToArray()), ["outUntil"] = null,
            ["runningHot"] = false, ["others"] = new JsonObject { ["count"] = Math.Max(0, lines.Length - 1), ["attention"] = 0 },
            ["readAt"] = Now.ToUnixTimeSeconds(),
            ["notes"] = new JsonArray((notes ?? []).Select(note => (JsonNode?)note).ToArray()), ["signedOut"] = signedOut,
        };
        if (lines.Length > 0) tool["headline"] = 0;
        if (id.IndexOf('/') is > 0 and var slash)
        {
            tool["group"] = id[(slash + 1)..];
            tool["via"] = id[..slash];
        }
        if (tier is not null) tool["tier"] = tier;
        return tool;
    }

    /// The reply as it crosses the C interface: JSON text, parsed.
    private static HudData Read(JsonObject[] tools, params (string Id, string Kind, string Message)[] problems) => HudData.Parse((JsonObject)JsonNode.Parse(new JsonObject
    {
        ["reading"] = new JsonObject { ["tools"] = new JsonArray(tools.Select(tool => (JsonNode?)tool).ToArray()), ["worst"] = "healthy" },
        ["readAt"] = Now.ToUnixTimeSeconds(),
        ["problems"] = new JsonArray(problems.Select(problem => (JsonNode?)new JsonObject
        {
            ["id"] = problem.Id, ["kind"] = problem.Kind, ["message"] = problem.Message,
        }).ToArray()),
        ["looks"] = new JsonArray(),
    }.ToJsonString())!)!;

    [TestMethod]
    public void Should_read_each_tool_s_notes_its_plan_and_whether_it_is_signed_out()
    {
        var data = Read(new[]
        {
            Tool("claude", new[] { Line("7d", 80) }, tier: "ULTRA"),
            Tool("codex", new[] { Line("7d", 71) }, new[] { Note("2", "Usage limit resets", "available"), Note("59,691", "Credits", "credits") }, tier: "PRO"),
            Tool("omp/Codex", new[] { Line("7d", 60) }, new[] { Note("1 saved reset · next expires Nov 7") }),
            Tool("omp/Claude · josh", Array.Empty<JsonObject>(), new[] { Note("Signed out · Refresh token revoked · run omp login") }, signedOut: true),
        });

        Assert.AreEqual("ULTRA", data.Tools[0].Tier);
        Assert.IsEmpty(data.Tools[0].Notes);
        CollectionAssert.AreEqual(new[] { new HudData.Note("Usage limit resets", "2", "available"), new HudData.Note("Credits", "59,691", "credits") }, data.Tools[1].Notes.ToArray());
        Assert.AreEqual("PRO", data.Tools[1].Tier);
        Assert.AreEqual(new HudData.Note(null, "1 saved reset · next expires Nov 7", ""), data.Tools[2].Notes.Single());
        Assert.IsNull(data.Tools[2].Tier);
        Assert.IsFalse(data.Tools[2].SignedOut);
        Assert.IsTrue(data.Tools[3].SignedOut);
        Assert.IsTrue(data.Tools[3].NotesOnly);
    }

    [TestMethod]
    public void Should_read_a_reply_from_before_the_notes_as_a_tool_without_any()
    {
        var tool = Tool("claude", new[] { Line("7d", 80) });
        tool.Remove("notes");
        tool.Remove("signedOut");

        var read = Read(new[] { tool }).Tools.Single();

        Assert.IsEmpty(read.Notes);
        Assert.IsNull(read.Tier);
        Assert.IsFalse(read.SignedOut);
    }

    [TestMethod]
    public void Should_show_an_account_omp_signed_out_on_the_HUD_as_a_tool_that_needs_you()
    {
        var data = Read(new[]
        {
            Tool("claude", new[] { Line("7d", 80) }),
            Tool("omp/Claude · josh", Array.Empty<JsonObject>(), new[] { Note("Signed out · Refresh token revoked · run omp login") }, signedOut: true),
        });

        var summary = data.Summary();

        var row = summary.Rows.Single();
        Assert.IsNull(row.Tool);
        Assert.AreEqual(("omp/Claude · josh", "signedOut", "Signed out · Refresh token revoked · run omp login"), (row.Problem!.Id, row.Problem.Kind, row.Problem.Message));
        Assert.IsFalse(summary.Fine!.All, "not every tool is fine while an account is signed out");
        CollectionAssert.AreEqual(new[] { "claude" }, summary.Fine.Ids.ToArray());
    }

    [TestMethod]
    public void Should_say_only_the_sign_out_on_the_HUD_not_the_group_s_other_notes()
    {
        var data = Read(new[]
        {
            Tool("omp/Codex · josh", Array.Empty<JsonObject>(), new[] { Note("1 saved reset · next expires Nov 7"), Note("Signed out · run omp login") }, signedOut: true),
        });

        var problem = data.Summary().Rows.Single().Problem!;

        Assert.AreEqual(("signedOut", "Signed out · run omp login"), (problem.Kind, problem.Message));
    }

    [TestMethod]
    public void Should_keep_a_problem_the_reading_already_has_for_a_signed_out_group()
    {
        var data = Read(new[] { Tool("omp/Claude · josh", Array.Empty<JsonObject>(), new[] { Note("Signed out · run omp login") }, signedOut: true) },
                        ("omp/Claude · josh", "failed", "omp usage timed out"));

        var problem = data.Summary().Rows.Single().Problem!;

        Assert.AreEqual(("failed", "omp usage timed out"), (problem.Kind, problem.Message));
        Assert.HasCount(1, data.Problems);
    }

    [TestMethod]
    public void Should_dim_the_numbers_of_a_group_whose_notes_say_it_is_signed_out()
    {
        var data = Read(new[] { Tool("omp/Claude · josh", new[] { Line("7d", 40) }, new[] { Note("Signed out · run omp login") }, signedOut: true) });

        var row = data.Summary().Rows.Single();

        Assert.AreEqual("omp/Claude · josh", row.Tool!.Id);
        Assert.AreEqual("signedOut", row.Problem!.Kind);
        Assert.AreEqual("signedOut", data.Stale("omp/Claude · josh")!.Kind);
    }

    [TestMethod]
    public void Should_leave_a_group_of_other_notes_off_the_HUD()
    {
        var data = Read(new[]
        {
            Tool("claude", new[] { Line("7d", 80) }),
            Tool("omp/Codex", new[] { Line("7d", 70) }),
            Tool("omp/OpenRouter", Array.Empty<JsonObject>(), new[] { Note("$12.50 left") }),
            Tool("omp/Qwen Cloud · API key", Array.Empty<JsonObject>(), new[] { Note("No usage reported") }),
        });

        var summary = data.Summary();

        Assert.IsEmpty(summary.Rows);
        Assert.IsTrue(summary.Fine!.All);
        CollectionAssert.AreEqual(new[] { "claude", "omp/Codex" }, summary.Fine.Ids.ToArray());
        CollectionAssert.AreEqual(new[] { "claude", "omp/Codex" }, data.OnHud.Select(tool => tool.Id).ToArray(), "and out of the rows drawn while it reads");
    }

    [TestMethod]
    public void Should_keep_an_aggregator_whose_groups_are_all_other_notes_on_the_HUD_as_one_with_no_limits_to_show()
    {
        var data = Read(new[]
        {
            Tool("omp/Kimi · API key", Array.Empty<JsonObject>(), new[] { Note("No usage reported") }),
            Tool("omp/OpenRouter", Array.Empty<JsonObject>(), new[] { Note("$12.50 left") }),
        });

        var row = data.Summary().Rows.Single();

        Assert.AreEqual("omp", row.Tool!.Id);
        Assert.IsNull(row.Headline);
        Assert.IsNull(row.Problem);
        CollectionAssert.AreEqual(new[] { "omp" }, data.OnHud.Select(tool => tool.Id).ToArray());
        Assert.HasCount(2, data.Tools, "the Limits page keeps both groups");
    }

    [TestMethod]
    public void Should_keep_a_login_with_notes_and_no_limit_on_the_HUD_as_one_with_no_limits_to_show()
    {
        var data = Read(new[] { Tool("codex", Array.Empty<JsonObject>(), new[] { Note("Unlimited", "Credits") }) });

        var row = data.Summary().Rows.Single();

        Assert.AreEqual("codex", row.Tool!.Id);
        Assert.IsNull(row.Headline);
        Assert.IsNull(row.Problem);
        Assert.IsFalse(row.Tool.NotesOnly);
    }

    [TestMethod]
    public void Should_say_a_note_as_the_Mac_s_card_does()
    {
        Assert.AreEqual("Usage limit resets: 2 available", HudText.NoteText(new HudData.Note("Usage limit resets", "2", "available")));
        Assert.AreEqual("Credits: Unlimited", HudText.NoteText(new HudData.Note("Credits", "Unlimited", "")));
        Assert.AreEqual("1 saved reset · next expires Nov 7", HudText.NoteText(new HudData.Note(null, "1 saved reset · next expires Nov 7", "")));
    }

    [TestMethod]
    public void Should_show_the_signed_out_account_in_the_check_s_sample_and_leave_its_other_notes_off()
    {
        var reply = (JsonObject)JsonNode.Parse(File.ReadAllText(Path.Combine(AppContext.BaseDirectory, "hud-check.json")))!;
        var data = HudData.Parse(reply)!;

        var rows = data.Summary().Rows;

        var signedOut = rows.Single(row => row.Tool is null);
        Assert.AreEqual(("omp/Claude · lab", "signedOut"), (signedOut.Problem!.Id, signedOut.Problem.Kind));
        Assert.AreEqual("Claude · lab", data.LookOf("omp/Claude · lab").Name);
        Assert.IsTrue(data.Tools.Any(tool => tool.Id == "omp/Qwen Cloud · API key" && tool.NotesOnly));
        Assert.IsFalse(rows.Any(row => row.Tool?.Id == "omp/Qwen Cloud · API key" || row.Problem?.Id == "omp/Qwen Cloud · API key"));
        Assert.AreEqual("ULTRA", data.Tools.Single(tool => tool.Id == "claude").Tier);
    }
}
