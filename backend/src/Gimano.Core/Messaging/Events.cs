using Gimano.Core.Contracts;

namespace Gimano.Core.Messaging;

/// <summary>RabbitMQ topology from docs/architecture.md ("Messaging").</summary>
public static class RoutingKeys
{
    public const string Exchange = "gimano.events";

    public const string LocationPing = "location.ping";
    public const string ReportCreated = "report.created";
    public const string ReportUpdated = "report.updated";
    public const string ReportVoted = "report.voted";
    public const string ReportExpired = "report.expired";
    public const string JamUpdated = "jam.updated";
    public const string JamCleared = "jam.cleared";
    public const string PlaceChanged = "place.changed";
    public const string FeedbackCreated = "feedback.created";
    public const string PhotoUploaded = "photo.uploaded";
    public const string ReportThanked = "report.thanked";
    public const string ReviewHelpful = "review.helpful";
    public const string PlaceVerified = "place.verified";
    public const string SuggestionApplied = "suggestion.applied";
    public const string FeedbackStatusChanged = "feedback.status";
    public const string IssueChanged = "issue.changed";
    public const string PlaceScreened = "place.screened";
    public const string ContentScreened = "content.screened";
}

public sealed record ReportVotedEvent(Guid ReportId, bool StillThere, Guid UserId);
public sealed record ReportExpiredEvent(Guid ReportId);
public sealed record JamClearedEvent(Guid JamId);
public sealed record PlaceChangedEvent(string PlaceId);
/// <summary>Deliberately carries no user/device identifiers or screenshot; consumers load the row by id.</summary>
public sealed record FeedbackCreatedEvent(Guid FeedbackId, FeedbackCategory Category, DateTimeOffset CreatedAt);

public sealed record PhotoUploadedEvent(Guid PhotoId);

public sealed record ReportThankedEvent(Guid ReportId);
public sealed record ReviewHelpfulEvent(Guid ReviewId);
public sealed record PlaceVerifiedEvent(string PlaceId, PlaceStatus Status);
/// <summary>The AI check decided (<paramref name="Late"/>: after the app stopped waiting, so the owner hears it in the Inbox).</summary>
public sealed record PlaceScreenedEvent(string PlaceId, Community.ScreeningState State, bool Late);
/// <summary>The content check decided on a review or photo (<paramref name="Late"/>: after the app stopped waiting, or a maintainer decided).</summary>
public sealed record ContentScreenedEvent(string SubjectKind, string SubjectId, string PlaceId, Community.ContentState State, bool Late);
public sealed record SuggestionAppliedEvent(Guid SuggestionId);
public sealed record FeedbackStatusEvent(Guid FeedbackId, FeedbackStatus Status);

/// <summary>An issue was created, voted on or changed state (for map updates and the reporter's inbox).</summary>
public sealed record IssueChangedEvent(Guid IssueId, Contracts.IssueState State, bool StateChanged);
