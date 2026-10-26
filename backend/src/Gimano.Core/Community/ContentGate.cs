using Gimano.Core.Contracts;
using Gimano.Core.Data;
using Gimano.Core.Domain;
using Gimano.Core.Messaging;
using Microsoft.EntityFrameworkCore;

namespace Gimano.Core.Community;

/// <summary>
/// Runs the content check (docs/content-safety.md) and applies its answer to reviews and photos. The API calls it while the app waits
/// (4 s); the worker finishes what is still "checking" and photos (which are checked after metadata stripping).
/// </summary>
public sealed class ContentGate(GimanoDbContext db, IContentScreener screener, BrandWatchlistService brands, IEventPublisher bus, TimeProvider clock)
{
    public bool Enabled => screener.Enabled;

    /// <summary>Text check: watchlist pre-filter, then the model. Null or empty text passes without a call.</summary>
    public async Task<ContentOutcome> CheckTextAsync(ContentInput input, TimeSpan? wait, CancellationToken ct)
    {
        if (string.IsNullOrWhiteSpace(input.Text)) return new ContentOutcome(ContentOutcomeKind.Passed, ["ok"]);
        var (pre, withBrands) = await PreFilterAsync(input, ct);
        if (pre is not null) return pre;
        return ContentScreening.OutcomeFor(await AskAsync(c => screener.ScreenTextAsync(withBrands, c), wait, ct), input.Text);
    }

    public async Task<ContentOutcome> CheckImageAsync(byte[] jpeg, ContentInput input, TimeSpan? wait, CancellationToken ct)
    {
        var (pre, withBrands) = await PreFilterAsync(input, ct);
        if (pre is not null) return pre;
        if (!screener.Enabled) return new ContentOutcome(ContentOutcomeKind.Skipped, []);
        return ContentScreening.OutcomeFor(await AskAsync(c => screener.ScreenImageAsync(jpeg, withBrands, c), wait, ct));
    }

    /// <summary>A watchlist brand set to "reject" in text is refused without a model call; other matches go to the model as context.</summary>
    private async Task<(ContentOutcome? Pre, ContentInput Input)> PreFilterAsync(ContentInput input, CancellationToken ct)
    {
        var matches = (await brands.MatcherAsync(ct)).Match(input.Text);
        if (matches.Any(m => m.TextMode == BrandTextMode.Reject))
            return (new ContentOutcome(ContentOutcomeKind.Rejected, ["brand_promo"]), input);
        return (null, matches.Count == 0 ? input : input with { Brands = matches });
    }

    private async Task<ContentResult> AskAsync(Func<CancellationToken, Task<ContentResult>> call, TimeSpan? wait, CancellationToken ct)
    {
        if (!screener.Enabled) return ContentResult.Off;
        using var cts = CancellationTokenSource.CreateLinkedTokenSource(ct);
        if (wait is { } w) cts.CancelAfter(w);
        try { return await call(cts.Token); }
        catch (OperationCanceledException) when (!ct.IsCancellationRequested) { return ContentResult.Failed; }
    }

    /// <summary>
    /// Counts a rejection of a review, photo or note (user and time only) and pauses the account for 24 h at three in 24 h, rejected
    /// places included (the same <c>SuspendedUntil</c> as the place pause). Saves.
    /// </summary>
    public async Task RecordRejectionAsync(Guid userId, CancellationToken ct)
    {
        var now = clock.GetUtcNow();
        db.ContentRejections.Add(new ContentRejection { UserId = userId, At = now });
        await db.SaveChangesAsync(ct);
        await db.ContentRejections.Where(r => r.At < now - ContentScreening.KeepRejectionLedger).ExecuteDeleteAsync(ct);
        var since = now - PlaceScreening.RejectionWindow;
        var recent = await db.ContentRejections.CountAsync(r => r.UserId == userId && r.At > since, ct)
                     + await db.CommunityPlaces.CountAsync(p => p.OwnerId == userId && p.ScreeningState == ScreeningState.Rejected && p.ScreenedAt > since, ct);
        if (!ContentScreening.ShouldPause(recent)) return;
        await db.Users.Where(u => u.Id == userId && (u.SuspendedUntil == null || u.SuspendedUntil < now + PlaceScreening.PauseFor))
            .ExecuteUpdateAsync(s => s.SetProperty(u => u.SuspendedUntil, now + PlaceScreening.PauseFor), ct);
    }

    /// <summary>Applies an outcome to a stored review (the worker after "checking", a retry, or a maintainer's decision elsewhere). Saves and announces.</summary>
    public async Task ApplyReviewAsync(Review r, ContentOutcome o, bool late, CancellationToken ct)
    {
        var now = clock.GetUtcNow();
        r.ModerationState = o.State;
        r.ModerationReasons = o.Kind is ContentOutcomeKind.Passed or ContentOutcomeKind.Skipped or ContentOutcomeKind.Checking ? null : ContentScreening.Join(o.Reasons);
        r.ModeratedAt = now;
        r.HeldForReview = o.Kind == ContentOutcomeKind.Held;
        r.Status = o.Kind is ContentOutcomeKind.Passed or ContentOutcomeKind.Skipped ? ReviewStatus.Published : ReviewStatus.Hidden;
        await db.SaveChangesAsync(ct);
        if (o.Kind == ContentOutcomeKind.Rejected && r.UserId is { } uid) await RecordRejectionAsync(uid, ct);
        await bus.PublishAsync(RoutingKeys.PlaceChanged, new PlaceChangedEvent(r.PlaceId), ct);
        await AnnounceAsync("review", r.Id.ToString(), r.PlaceId, o.State, late, ct);
    }

    public async Task ApplyPhotoAsync(Photo p, ContentOutcome o, bool late, CancellationToken ct)
    {
        var now = clock.GetUtcNow();
        var wasPublished = p.Status == PhotoStatus.Published;
        // Photos have no "skipped" state in the contract: an unchecked photo simply has no moderation block.
        p.ModerationState = o.Kind == ContentOutcomeKind.Skipped ? ContentState.None : o.State;
        p.ModerationReasons = o.Kind is ContentOutcomeKind.Passed or ContentOutcomeKind.Skipped or ContentOutcomeKind.Checking ? null : ContentScreening.Join(o.Reasons);
        p.ModeratedAt = now;
        switch (o.Kind)
        {
            case ContentOutcomeKind.Passed or ContentOutcomeKind.Skipped:
                p.Status = PhotoStatus.Published;
                if (!wasPublished && p.User is { } u) u.Points += CommunityRules.Points.Photo;
                break;
            case ContentOutcomeKind.Rejected:
                p.Status = PhotoStatus.Rejected;
                p.RejectReason = "content";
                break;
            default:
                p.Status = PhotoStatus.Processing; // held or still checking: not shown to anyone else
                break;
        }
        await db.SaveChangesAsync(ct);
        if (o.Kind == ContentOutcomeKind.Rejected && p.UserId is { } uid) await RecordRejectionAsync(uid, ct);
        await bus.PublishAsync(RoutingKeys.PlaceChanged, new PlaceChangedEvent(p.PlaceId), ct);
        await AnnounceAsync("photo", p.Id.ToString(), p.PlaceId, o.State, late, ct);
    }

    /// <summary>The Inbox hears held and rejected items, and passed ones that came late (or from a maintainer).</summary>
    public Task AnnounceAsync(string subjectKind, string subjectId, string placeId, ContentState state, bool late, CancellationToken ct) =>
        state is ContentState.Held or ContentState.Rejected || (state == ContentState.Passed && late)
            ? bus.PublishAsync(RoutingKeys.ContentScreened, new ContentScreenedEvent(subjectKind, subjectId, placeId, state, late), ct)
            : Task.CompletedTask;
}
