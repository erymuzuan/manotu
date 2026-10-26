using Gimano.Core.Contracts;

namespace Gimano.Core.Domain;

// Back office: agent access, audit, agent runs, reply drafts and app builds (docs/back-office.md).
// Nothing here carries a user id, device token or contact details. Feedback, crash groups/reports and the sealed
// contacts are in Entities.cs.

/// <summary>A bearer token for an AI agent (MCP / admin API). Only the sha256 is stored.</summary>
public sealed class AgentToken
{
    public Guid Id { get; set; } = Guid.CreateVersion7();
    public required string Name { get; set; }
    /// <summary>First characters of the token, to recognise it in lists ("agt_3F9k…").</summary>
    public required string Prefix { get; set; }
    public required string TokenHash { get; set; }
    public string[] Scopes { get; set; } = [];
    public required string CreatedBy { get; set; }
    public DateTimeOffset CreatedAt { get; set; }
    public DateTimeOffset ExpiresAt { get; set; }
    public DateTimeOffset? RevokedAt { get; set; }
    public DateTimeOffset? LastUsedAt { get; set; }
}

/// <summary>Who did what in the back office. Never stores returned content, contact details or request bodies.</summary>
public sealed class AuditEntry
{
    public long Id { get; set; }
    public DateTimeOffset At { get; set; }
    public required string Actor { get; set; }
    /// <summary>human | agent</summary>
    public required string ActorKind { get; set; }
    public required string Action { get; set; }
    public required string TargetType { get; set; }
    public string? TargetId { get; set; }
    /// <summary>A short summary ("status=triaged severity=s2") or the reason given for revealing a contact.</summary>
    public string? Detail { get; set; }
}

public sealed record AgentRunStep(DateTimeOffset At, string Title, string? Detail);

/// <summary>An agent working on a feedback item or crash group: its steps, branch and PR.</summary>
public sealed class AgentRun
{
    public int Id { get; set; }
    public required string Title { get; set; }
    /// <summary>feedback | crash</summary>
    public required string TargetType { get; set; }
    public required string TargetId { get; set; }
    public AgentRunStatus Status { get; set; } = AgentRunStatus.Running;
    public required string Agent { get; set; }
    public DateTimeOffset StartedAt { get; set; }
    public DateTimeOffset UpdatedAt { get; set; }
    public string? Branch { get; set; }
    public string? PrUrl { get; set; }
    public string? Summary { get; set; }
    public List<AgentRunStep> Steps { get; set; } = [];
}

/// <summary>A reply to a feedback reporter, delivered as an Inbox item once a maintainer approves it.</summary>
public sealed class ReplyDraft
{
    public Guid Id { get; set; } = Guid.CreateVersion7();
    public Guid FeedbackId { get; set; }
    public required string Message { get; set; }
    public FeedbackStatus? NewStatus { get; set; }
    public ReplyStatus Status { get; set; } = ReplyStatus.Draft;
    public required string DraftedBy { get; set; }
    public DateTimeOffset CreatedAt { get; set; }
    public string? DecidedBy { get; set; }
    public DateTimeOffset? DecidedAt { get; set; }
}

/// <summary>A shipped app build: maps version/build to the git commit (and its symbol files) for agents and regression checks.</summary>
public sealed class AppBuild
{
    public int Id { get; set; }
    /// <summary>android | ios</summary>
    public required string Platform { get; set; }
    public required string Version { get; set; }
    public int Build { get; set; }
    public required string Commit { get; set; }
    /// <summary>Where the R8 mapping.txt / dSYM lives (CI artifact URL or path).</summary>
    public string? SymbolsUrl { get; set; }
    public DateTimeOffset ReleasedAt { get; set; }
}

/// <summary>
/// A brand name on the content-safety watchlist (docs/content-safety.md "Brand watchlist"). Brand names only; nothing private.
/// <see cref="Aliases"/> are other spellings, comma-separated.
/// </summary>
public sealed class WatchedBrand
{
    public Guid Id { get; set; } = Guid.CreateVersion7();
    public required string Name { get; set; }
    public string? Aliases { get; set; }
    public Community.BrandGroup Group { get; set; }
    public Community.BrandPlaceMode PlaceMode { get; set; } = Community.BrandPlaceMode.Warn;
    public Community.BrandTextMode TextMode { get; set; } = Community.BrandTextMode.MentionOk;
    public bool Enabled { get; set; } = true;
    public DateTimeOffset UpdatedAt { get; set; } = DateTimeOffset.UtcNow;
    public string? UpdatedBy { get; set; }
}
