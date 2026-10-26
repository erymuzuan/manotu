using System.Text.Json;
using Gimano.Core.Community;
using Gimano.Core.Contracts;
using Gimano.Core.Data;
using Gimano.Core.Domain;
using Gimano.Core.Messaging;
using Microsoft.EntityFrameworkCore;

namespace Gimano.Worker.Inbox;

/// <summary>Turns contribution events into inbox items for the contributor (thanks/helpful aggregated per day).</summary>
public sealed class InboxGenerator(RabbitMqConnection connection, IServiceScopeFactory scopes, TimeProvider clock, ILogger<InboxGenerator> logger)
    : RabbitConsumer<JsonElement>(connection, logger)
{
    protected override string QueueName => "gimano.worker.inbox";
    protected override IReadOnlyList<string> RoutingKeyBindings =>
        [RoutingKeys.ReportThanked, RoutingKeys.ReviewHelpful, RoutingKeys.PlaceVerified, RoutingKeys.SuggestionApplied, RoutingKeys.FeedbackStatusChanged,
         RoutingKeys.IssueChanged, RoutingKeys.PlaceScreened, RoutingKeys.ContentScreened];

    protected override async Task HandleAsync(JsonElement message, string routingKey, CancellationToken ct)
    {
        await using var scope = scopes.CreateAsyncScope();
        var db = scope.ServiceProvider.GetRequiredService<GimanoDbContext>();
        var o = GimanoJson.Options;
        switch (routingKey)
        {
            case RoutingKeys.ReportThanked:
            {
                var e = message.Deserialize<ReportThankedEvent>(o)!;
                var r = await db.Reports.AsNoTracking().Where(x => x.Id == e.ReportId).Select(x => new { x.ReporterId }).FirstOrDefaultAsync(ct);
                if (r?.ReporterId is { } uid) await AddAsync(db, uid, InboxKind.ReportThanked, null, "report", e.ReportId.ToString(), ct);
                break;
            }
            case RoutingKeys.ReviewHelpful:
            {
                var e = message.Deserialize<ReviewHelpfulEvent>(o)!;
                var r = await db.Reviews.AsNoTracking().Where(x => x.Id == e.ReviewId).Select(x => new { x.UserId, x.PlaceId }).FirstOrDefaultAsync(ct);
                if (r?.UserId is { } uid) await AddAsync(db, uid, InboxKind.ReviewHelpful, await PlaceNameAsync(db, r.PlaceId, ct), "place", r.PlaceId, ct);
                break;
            }
            case RoutingKeys.PlaceVerified:
            {
                var e = message.Deserialize<PlaceVerifiedEvent>(o)!;
                var p = await db.CommunityPlaces.AsNoTracking().Where(x => x.Id == e.PlaceId).Select(x => new { x.OwnerId, x.Name }).FirstOrDefaultAsync(ct);
                var kind = e.Status switch
                {
                    PlaceStatus.Published => InboxKind.PlacePublished, PlaceStatus.Hidden => InboxKind.PlaceRejected,
                    PlaceStatus.Expired => InboxKind.PlaceExpired, _ => (InboxKind?)null,
                };
                if (p?.OwnerId is { } uid && kind is { } k) await AddAsync(db, uid, k, p.Name, "place", e.PlaceId, ct);
                break;
            }
            case RoutingKeys.PlaceScreened:
            {
                // The app shows a result it waited for; the Inbox also keeps it, and carries the late ones (design C2).
                var e = message.Deserialize<PlaceScreenedEvent>(o)!;
                var p = await db.CommunityPlaces.AsNoTracking().Where(x => x.Id == e.PlaceId).Select(x => new { x.OwnerId, x.Name }).FirstOrDefaultAsync(ct);
                var kind = e.State switch
                {
                    Core.Community.ScreeningState.Held => InboxKind.PlaceHeld,
                    Core.Community.ScreeningState.Rejected => InboxKind.PlaceNotAccepted,
                    Core.Community.ScreeningState.Passed when e.Late => InboxKind.PlaceLive,
                    _ => (InboxKind?)null,
                };
                if (p?.OwnerId is { } uid && kind is { } k) await AddAsync(db, uid, k, p.Name, "place", e.PlaceId, ct);
                break;
            }
            case RoutingKeys.ContentScreened:
            {
                // A review or photo the content check held or rejected, or approved late / by a maintainer (docs/content-safety.md "Inbox").
                var e = message.Deserialize<ContentScreenedEvent>(o)!;
                Guid? uid; string? reasons; bool canAppeal;
                if (e.SubjectKind == "review" && Guid.TryParse(e.SubjectId, out var rid))
                {
                    var r = await db.Reviews.AsNoTracking().Where(x => x.Id == rid).Select(x => new { x.UserId, x.ModerationReasons, x.AppealedAt, x.ModerationState }).FirstOrDefaultAsync(ct);
                    (uid, reasons, canAppeal) = (r?.UserId, r?.ModerationReasons, r is { ModerationState: Core.Community.ContentState.Rejected, AppealedAt: null });
                }
                else if (e.SubjectKind == "photo" && Guid.TryParse(e.SubjectId, out var pid))
                {
                    var p = await db.Photos.AsNoTracking().Where(x => x.Id == pid).Select(x => new { x.UserId, x.ModerationReasons, x.AppealedAt, x.ModerationState }).FirstOrDefaultAsync(ct);
                    (uid, reasons, canAppeal) = (p?.UserId, p?.ModerationReasons, p is { ModerationState: Core.Community.ContentState.Rejected, AppealedAt: null });
                }
                else break;
                var kind = e.State switch
                {
                    Core.Community.ContentState.Held => InboxKind.ContentHeld,
                    Core.Community.ContentState.Rejected => InboxKind.ContentRejected,
                    Core.Community.ContentState.Passed when e.Late => InboxKind.ContentPublished,
                    _ => (InboxKind?)null,
                };
                if (uid is { } user && kind is { } k)
                    await AddAsync(db, user, k, await PlaceNameAsync(db, e.PlaceId, ct), e.SubjectKind, e.SubjectId, ct, e.PlaceId, reasons, kind == InboxKind.ContentRejected ? canAppeal : false);
                break;
            }
            case RoutingKeys.SuggestionApplied:
            {
                var e = message.Deserialize<SuggestionAppliedEvent>(o)!;
                var sgn = await db.PlaceSuggestions.AsNoTracking().FirstOrDefaultAsync(x => x.Id == e.SuggestionId, ct);
                if (sgn?.UserId is { } uid) await AddAsync(db, uid, InboxKind.EditAccepted, await PlaceNameAsync(db, sgn.PlaceId, ct), "place", sgn.PlaceId, ct);
                break;
            }
            case RoutingKeys.IssueChanged:
            {
                var e = message.Deserialize<IssueChangedEvent>(o)!;
                if (!e.StateChanged) break;
                var kind = e.State switch
                {
                    IssueState.Confirmed => InboxKind.IssueConfirmed, IssueState.Refuted => InboxKind.IssueRefuted,
                    IssueState.Resolved => InboxKind.IssueResolved, _ => (InboxKind?)null,
                };
                if (kind is not { } k) break;
                var issue = await db.Issues.AsNoTracking().FirstOrDefaultAsync(x => x.Id == e.IssueId, ct);
                if (issue?.CreatedBy is not { } uid) break;
                var placeName = issue.PlaceId is { } pid ? await PlaceNameAsync(db, pid, ct) : null;
                // Subject = the road or place name (language-neutral; the title around it follows the reader's language).
                var subject = placeName ?? issue.RoadName ?? Gimano.Core.Issues.IssueText.Kind(issue.Kind, "ms");
                await AddAsync(db, uid, k, subject, "issue", issue.Id.ToString(), ct);
                break;
            }
            case RoutingKeys.FeedbackStatusChanged:
            {
                var e = message.Deserialize<FeedbackStatusEvent>(o)!;
                var f = await db.Feedback.AsNoTracking().Where(x => x.Id == e.FeedbackId).Select(x => new { x.UserId }).FirstOrDefaultAsync(ct);
                if (f?.UserId is { } uid) await AddAsync(db, uid, InboxKind.FeedbackStatus, GimanoJson.ToWire(e.Status).Replace('_', ' '), "feedback", e.FeedbackId.ToString(), ct);
                break;
            }
        }
    }

    private static async Task<string?> PlaceNameAsync(GimanoDbContext db, string placeId, CancellationToken ct) =>
        CommunityPlace.IsCommunityId(placeId)
            ? await db.CommunityPlaces.Where(p => p.Id == placeId).Select(p => p.Name).FirstOrDefaultAsync(ct)
            : await db.Places.Where(p => p.Id == placeId).Select(p => p.Name).FirstOrDefaultAsync(ct);

    /// <summary>Adds an item, or bumps today's aggregate ("24 drivers thanked you") and moves it to the top as unread.</summary>
    private async Task AddAsync(GimanoDbContext db, Guid userId, InboxKind kind, string? subject, string? refType, string? refId, CancellationToken ct,
        string? placeId = null, string? reasons = null, bool? canAppeal = null)
    {
        var user = await db.Users.AsNoTracking().Where(u => u.Id == userId).Select(u => new { u.Locale }).FirstOrDefaultAsync(ct);
        if (user is null) return;
        var now = clock.GetUtcNow();
        var key = InboxRules.AggregateKey(kind, now);
        var item = key is null ? null : await db.InboxItems.FirstOrDefaultAsync(i => i.UserId == userId && i.AggregateKey == key, ct);
        if (item is null)
        {
            var (title, body) = InboxRules.Text(kind, 1, user.Locale, subject);
            db.InboxItems.Add(new InboxItem
            {
                UserId = userId, Kind = kind, Title = title, Body = body, Subject = subject, RefType = key is null ? refType : null, RefId = key is null ? refId : null,
                AggregateKey = key, CreatedAt = now, PlaceId = placeId, Reasons = reasons, CanAppeal = canAppeal,
            });
        }
        else
        {
            item.Count++;
            item.Subject = subject;
            (item.Title, item.Body) = InboxRules.Text(kind, item.Count, user.Locale, subject);
            item.CreatedAt = now;
        }
        try { await db.SaveChangesAsync(ct); }
        catch (DbUpdateException) when (key is not null)
        {
            // Two events raced to create today's aggregate: retry once as an increment.
            db.ChangeTracker.Clear();
            await AddAsync(db, userId, kind, subject, refType, refId, ct, placeId, reasons, canAppeal);
        }
    }
}

/// <summary>Hourly: deletes inbox items older than 90 days.</summary>
public sealed class InboxRetention(IServiceScopeFactory scopes, TimeProvider clock, ILogger<InboxRetention> logger) : BackgroundService
{
    protected override async Task ExecuteAsync(CancellationToken stoppingToken)
    {
        using var timer = new PeriodicTimer(TimeSpan.FromHours(1));
        do
        {
            try
            {
                await using var scope = scopes.CreateAsyncScope();
                var db = scope.ServiceProvider.GetRequiredService<GimanoDbContext>();
                var cutoff = clock.GetUtcNow() - InboxRules.Retention;
                var n = await db.InboxItems.Where(i => i.CreatedAt < cutoff).ExecuteDeleteAsync(stoppingToken);
                if (n > 0) logger.LogInformation("Inbox retention: deleted {Count} items older than 90 days", n);
            }
            catch (Exception ex) when (ex is not OperationCanceledException) { logger.LogWarning("Inbox retention failed: {Message}", ex.Message); }
        } while (await timer.WaitForNextTickAsync(stoppingToken));
    }
}
