using System.ComponentModel;
using System.Text.Json;
using Gimano.Core.BackOffice;
using Gimano.Core.Contracts;
using Gimano.Core.Domain;
using ModelContextProtocol;
using ModelContextProtocol.Protocol;
using ModelContextProtocol.Server;

namespace Gimano.Api.Admin;

/// <summary>
/// The gimano-backoffice MCP server (POST /mcp, stateless HTTP). Same rules as /admin/v1; every reporter-written string is
/// fenced as untrusted data. There is deliberately no tool to unseal contacts, merge, release or contact a reporter.
/// </summary>
[McpServerToolType]
public sealed class BackOfficeMcpTools(TriageService triage, IHttpContextAccessor http, Gimano.Core.AppVersions.AppVersionService versions)
{
    private Actor Actor => (http.HttpContext ?? throw new UnauthorizedAccessException("No request.")).User.ToActor();

    private static readonly JsonSerializerOptions Json = new(GimanoJson.Options) { WriteIndented = false };

    private static string Out(object value, bool untrusted = false) =>
        (untrusted ? UntrustedText.Notice + "\n" : "") + JsonSerializer.Serialize(value, Json);

    // ---- read --------------------------------------------------------------------------------------------------

    [McpServerTool(Name = "queue", ReadOnly = true), Description("Open feedback and crash groups, regressions first. type: feedback | crash | (omit for both).")]
    public Task<string> Queue(string? type = null, int take = 50, CancellationToken ct = default) => Guard(async () =>
    {
        Actor.Require(AgentScopes.Read);
        var rows = await triage.QueueAsync(type, take, ct);
        return Out(rows.Select(r => r with { Title = UntrustedText.Fence(r.Title) }), untrusted: true);
    });

    [McpServerTool(Name = "feedback_search", ReadOnly = true),
     Description("Search feedback. status: received|triaged|planned|done|wont_fix. category: bug|idea|map_data|route|search|other. text: substring of the message.")]
    public Task<string> FeedbackSearch(string? status = null, string? category = null, string? screen = null, string? platform = null,
        string? text = null, int? sinceDays = null, bool openOnly = true, int take = 30, CancellationToken ct = default) => Guard(async () =>
    {
        Actor.Require(AgentScopes.Read);
        var q = new FeedbackQuery(Parse<FeedbackStatus>(status), Parse<FeedbackCategory>(category), Parse<FeedbackScreen>(screen), platform, text,
            sinceDays is { } d ? DateTimeOffset.UtcNow.AddDays(-d) : null, openOnly, take);
        var rows = await triage.SearchFeedbackAsync(q, ct);
        return Out(rows.Select(r => r with { Message = UntrustedText.Fence(r.Message) }), untrusted: true);
    });

    [McpServerTool(Name = "feedback_get", ReadOnly = true),
     Description("One feedback item: message, rating, screen, app/device info, ≈1 km area, triage fields. Contact details appear as flags only.")]
    public Task<string> FeedbackGet(Guid id, CancellationToken ct = default) => Guard(async () =>
    {
        Actor.Require(AgentScopes.Read);
        var f = await triage.GetFeedbackAsync(id, ct) ?? throw new NotFoundException("Feedback not found.");
        return Out(f with { Message = UntrustedText.Fence(f.Message) }, untrusted: true);
    });

    [McpServerTool(Name = "feedback_screenshot", ReadOnly = true),
     Description("The screenshot attached to a feedback item, only if a maintainer shared it with agents.")]
    public Task<ContentBlock> FeedbackScreenshot(Guid id, CancellationToken ct = default) => Guard(async () =>
    {
        var s = await triage.GetScreenshotAsync(id, Actor, ct) ?? throw new NotFoundException("No screenshot on this feedback.");
        return (ContentBlock)ImageContentBlock.FromBytes(s.Bytes, s.ContentType);
    });

    [McpServerTool(Name = "crash_groups", ReadOnly = true),
     Description("Crash groups by last seen. status: open|triaged|fixing|regressed|done|wont_fix. text matches exception, top frame or signature prefix.")]
    public Task<string> CrashGroups(string? status = null, string? platform = null, string? text = null, bool openOnly = true, int take = 30,
        CancellationToken ct = default) => Guard(async () =>
    {
        Actor.Require(AgentScopes.Read);
        var rows = await triage.CrashGroupsAsync(new CrashQuery(Parse<CrashGroupStatus>(status), platform, text, openOnly, take), ct);
        return Out(rows.Select(r => r with { Message = UntrustedText.Fence(r.Message) }), untrusted: true);
    });

    [McpServerTool(Name = "crash_group", ReadOnly = true),
     Description("A crash group: latest scrubbed stack, counts by build / OS / model / screen, triage fields and any prior analysis.")]
    public Task<string> CrashGroup(string signature, CancellationToken ct = default) => Guard(async () =>
    {
        Actor.Require(AgentScopes.Read);
        var g = await triage.GetCrashGroupAsync(signature, ct) ?? throw new NotFoundException("Crash group not found.");
        return Out(g with { Group = g.Group with { Message = UntrustedText.Fence(g.Group.Message) }, LatestStack = UntrustedText.Fence(g.LatestStack) }, untrusted: true);
    });

    [McpServerTool(Name = "crash_events", ReadOnly = true), Description("Recent events of a crash group: build, OS, model, screen, uptime, stack.")]
    public Task<string> CrashEvents(string signature, int take = 10, CancellationToken ct = default) => Guard(async () =>
    {
        Actor.Require(AgentScopes.Read);
        var rows = await triage.CrashEventsAsync(signature, take, ct);
        return Out(rows.Select(e => e with { Message = UntrustedText.Fence(e.Message), Stack = UntrustedText.Fence(e.Stack), Threads = UntrustedText.Fence(e.Threads) }),
            untrusted: true);
    });

    [McpServerTool(Name = "crash_linked_feedback", ReadOnly = true), Description("Feedback items linked to a crash group.")]
    public Task<string> CrashLinkedFeedback(string signature, CancellationToken ct = default) => Guard(async () =>
    {
        Actor.Require(AgentScopes.Read);
        var rows = await triage.LinkedFeedbackAsync(signature, ct);
        return Out(rows.Select(r => r with { Message = UntrustedText.Fence(r.Message) }), untrusted: true);
    });

    [McpServerTool(Name = "builds_resolve", ReadOnly = true),
     Description("Map an app build to its git commit and symbol files. platform: android|ios; give build (number) or version.")]
    public Task<string> BuildsResolve(string platform, int? build = null, string? version = null, CancellationToken ct = default) => Guard(async () =>
    {
        Actor.Require(AgentScopes.Read);
        return await triage.ResolveBuildAsync(platform, build, version, ct) is { } b ? Out(b) : "No build registered; ask a maintainer to add it under Releases.";
    });

    [McpServerTool(Name = "app_versions", ReadOnly = true),
     Description("Latest store version, forced-update floor (forceBelow) and policy per platform (ios, android-play). Changing it is maintainer-only (back office or X-Admin-Key).")]
    public Task<string> AppVersions(CancellationToken ct = default) => Guard(async () =>
    {
        Actor.Require(AgentScopes.Read);
        return Out(new { versions = await versions.GetAsync(ct), config = await versions.ConfigsAsync(ct) });
    });

    // ---- triage ------------------------------------------------------------------------------------------------

    [McpServerTool(Name = "feedback_triage", Idempotent = true),
     Description("Set status, severity (s1–s4), category, duplicateOfId, crashSignature (link to a crash group), a note or a github.com link.")]
    public Task<string> FeedbackTriage(Guid id, string? status = null, string? severity = null, string? category = null, Guid? duplicateOfId = null,
        string? crashSignature = null, string? note = null, string? link = null, CancellationToken ct = default) => Guard(async () =>
    {
        var f = await triage.TriageFeedbackAsync(id, new FeedbackTriage(Parse<FeedbackStatus>(status), Parse<Severity>(severity),
            Parse<FeedbackCategory>(category), duplicateOfId, crashSignature, note, link), Actor, ct);
        return $"ok: {GimanoJson.ToWire(f.Status)}{(f.Severity is { } s ? " " + GimanoJson.ToWire(s) : "")}";
    });

    [McpServerTool(Name = "crash_triage", Idempotent = true),
     Description("Set status, severity, note, github.com link, root-cause analysis (markdown), or mark it done (status=done with fixedInBuild and fixedInVersion).")]
    public Task<string> CrashTriage(string signature, string? status = null, string? severity = null, string? note = null, string? link = null,
        string? analysis = null, int? fixedInBuild = null, string? fixedInVersion = null, CancellationToken ct = default) => Guard(async () =>
    {
        var g = await triage.TriageCrashAsync(signature, new CrashTriage(Parse<CrashGroupStatus>(status), Parse<Severity>(severity), note, link, analysis,
            fixedInBuild, fixedInVersion), Actor, ct);
        return $"ok: {GimanoJson.ToWire(g.Group.Status)}";
    });

    [McpServerTool(Name = "reply_draft"),
     Description("Queue a short reply (≤ 1000 chars, in the reporter's language) for a maintainer to approve. newStatus optional. Never sent directly.")]
    public Task<string> ReplyDraft(Guid feedbackId, string message, string? newStatus = null, CancellationToken ct = default) => Guard(async () =>
    {
        var r = await triage.DraftReplyAsync(feedbackId, message, Parse<FeedbackStatus>(newStatus), Actor, ct);
        return $"queued for approval: {r.Id}";
    });

    // ---- runs --------------------------------------------------------------------------------------------------

    [McpServerTool(Name = "run_start"), Description("Record that you are working on a crash group (targetType=crash, targetId=signature) or feedback item. Returns the run id.")]
    public Task<string> RunStart(string title, string targetType, string targetId, CancellationToken ct = default) => Guard(async () =>
        Out(await triage.StartRunAsync(title, targetType, targetId, Actor, ct)));

    [McpServerTool(Name = "run_log"), Description("Append a step to a run (what you did, the command and its result).")]
    public Task<string> RunLog(int runId, string title, string? detail = null, CancellationToken ct = default) => Guard(async () =>
    {
        await triage.LogRunStepAsync(runId, title, detail, Actor, ct);
        return "ok";
    });

    [McpServerTool(Name = "run_update"),
     Description("Set a run's branch (must start with agent/), PR URL (github.com), summary, or status: running|waiting_for_review|failed|cancelled.")]
    public Task<string> RunUpdate(int runId, string? status = null, string? branch = null, string? prUrl = null, string? summary = null,
        CancellationToken ct = default) => Guard(async () =>
    {
        var r = await triage.UpdateRunAsync(runId, new AgentRunUpdate(Parse<AgentRunStatus>(status), branch, prUrl, summary), Actor, ct);
        return $"ok: {GimanoJson.ToWire(r.Status)}";
    });

    /// <summary>The SDK hides exception messages from the model; domain errors (not found, invalid input, missing scope) are useful to it.</summary>
    private static async Task<T> Guard<T>(Func<Task<T>> body)
    {
        try { return await body(); }
        catch (Exception e) when (e is NotFoundException or ValidationException or ForbiddenException or ConflictException) { throw new McpException(e.Message, e); }
    }

    private static T? Parse<T>(string? wire) where T : struct, Enum
    {
        if (string.IsNullOrWhiteSpace(wire)) return null;
        return GimanoJson.TryParseWire<T>(wire, out var v) ? v
            : throw new McpException($"'{wire}' is not one of: {string.Join(", ", Enum.GetValues<T>().Select(x => GimanoJson.ToWire(x)))}.");
    }
}
