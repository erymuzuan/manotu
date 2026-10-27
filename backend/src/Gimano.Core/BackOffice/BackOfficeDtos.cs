using Gimano.Core.Contracts;
using Gimano.Core.Domain;

namespace Gimano.Core.BackOffice;

// Views served to maintainers (Blazor), the admin API and the MCP tools. None of them carries a user id, device token,
// IP address or contact details: a contact appears only as "present until", and revealing it is a separate audited call
// that only a signed-in maintainer can make.

/// <summary>A volunteered contact exists on this report; it is deleted at <see cref="ExpiresAt"/> at the latest.</summary>
public sealed record ContactFlags(DateTimeOffset CreatedAt, DateTimeOffset ExpiresAt);

public sealed record QueueRow(
    string Type, string Id, string Title, string Subtitle, string Kind, int Count, string? Builds, string Status,
    Severity? Severity, bool HasContact, bool HasScreenshot, DateTimeOffset LastSeenAt);

public sealed record FeedbackQuery(
    FeedbackStatus? Status = null, FeedbackCategory? Category = null, FeedbackScreen? Screen = null, string? Platform = null,
    string? Text = null, DateTimeOffset? Since = null, bool OpenOnly = false, int Take = 50);

public sealed record FeedbackListItem(
    Guid Id, FeedbackCategory Category, string Message, int? Rating, FeedbackScreen? Screen, FeedbackStatus Status,
    Severity? Severity, string? AppVersion, string? Platform, bool HasScreenshot, bool HasContact, DateTimeOffset CreatedAt,
    bool SuspectedSpam = false);

/// <param name="Lat">Coarse location (2 dp), only when the reporter ticked "include approximate location".</param>
public sealed record FeedbackView(
    Guid Id, FeedbackCategory Category, string Message, int? Rating, FeedbackScreen? Screen, FeedbackStatus Status,
    Severity? Severity, DeviceInfo? Device, double? Lat, double? Lng, string? RouteId, string? PlaceId, bool HasScreenshot,
    bool ScreenshotSharedWithAgents, ContactFlags? Contact, Guid? DuplicateOfId, string? CrashSignature, string? TriageNote,
    string? ExternalUrl, DateTimeOffset CreatedAt, DateTimeOffset? UpdatedAt, DateTimeOffset? ClosedAt, bool SuspectedSpam = false);

public sealed record FeedbackTriage(
    FeedbackStatus? Status = null, Severity? Severity = null, FeedbackCategory? Category = null, Guid? DuplicateOfId = null,
    string? CrashSignature = null, string? Note = null, string? ExternalUrl = null);

public sealed record CrashQuery(CrashGroupStatus? Status = null, string? Platform = null, string? Text = null, bool OpenOnly = false, int Take = 50);

public sealed record CrashGroupItem(
    string Signature, string? Platform, CrashKind? Kind, string Exception, string? Message, string? TopFrame, CrashGroupStatus Status,
    Severity? Severity, int EventCount, DateTimeOffset FirstSeenAt, DateTimeOffset LastSeenAt, string? FirstVersion,
    string? LatestVersion, string? FixedInVersion, string? ExternalUrl);

public sealed record Bucket(string Label, int Count);

public sealed record CrashGroupView(
    CrashGroupItem Group, int? FixedInBuild, string? TriageNote, string? Analysis, string? AnalysisBy, string? LatestStack,
    IReadOnlyList<Bucket> ByVersion, IReadOnlyList<Bucket> ByOs, IReadOnlyList<Bucket> ByModel, IReadOnlyList<Bucket> ByScreen,
    int OlderThanRetained, DateTimeOffset? ClosedAt);

public sealed record CrashEventView(
    Guid Id, DateTimeOffset? OccurredAt, DateTimeOffset ReceivedAt, CrashKind Kind, string? Message, string? Stack, string? Threads,
    string? Screen, long? UptimeS, DeviceInfo? Device, bool HasContact);

public sealed record CrashTriage(
    CrashGroupStatus? Status = null, Severity? Severity = null, string? Note = null, string? ExternalUrl = null, string? Analysis = null,
    int? FixedInBuild = null, string? FixedInVersion = null);

public sealed record AgentRunView(
    int Id, string Title, string TargetType, string TargetId, AgentRunStatus Status, string Agent, DateTimeOffset StartedAt,
    DateTimeOffset UpdatedAt, string? Branch, string? PrUrl, string? Summary, IReadOnlyList<AgentRunStep> Steps);

public sealed record AgentRunUpdate(AgentRunStatus? Status = null, string? Branch = null, string? PrUrl = null, string? Summary = null);

public sealed record ReplyView(
    Guid Id, Guid FeedbackId, string FeedbackMessage, string Message, FeedbackStatus? NewStatus, ReplyStatus Status,
    string DraftedBy, DateTimeOffset CreatedAt, string? DecidedBy, DateTimeOffset? DecidedAt, bool ReporterReachable);

public sealed record AgentTokenView(
    Guid Id, string Name, string Prefix, IReadOnlyList<string> Scopes, string CreatedBy, DateTimeOffset CreatedAt,
    DateTimeOffset ExpiresAt, DateTimeOffset? RevokedAt, DateTimeOffset? LastUsedAt)
{
    public bool Active(DateTimeOffset now) => RevokedAt is null && ExpiresAt > now;
}

public sealed record CreatedAgentToken(AgentTokenView Token, string Secret);

public sealed record AppBuildView(int Id, string Platform, string Version, int Build, string Commit, string? SymbolsUrl, DateTimeOffset ReleasedAt);

public sealed record AuditView(long Id, DateTimeOffset At, string Actor, string ActorKind, string Action, string TargetType, string? TargetId, string? Detail);

public sealed record BackOfficeStats(int OpenFeedback, int OpenCrashGroups, int New24h, int Regressions, int RunsAwaitingReview, int RepliesToApprove);
