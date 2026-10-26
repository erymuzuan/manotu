using Gimano.Core.Community;
using Gimano.Core.Contracts;
using Gimano.Core.Data;
using Gimano.Core.Domain;
using Microsoft.EntityFrameworkCore;

namespace Gimano.Worker.Vetting;

/// <summary>
/// Every minute: finishes the content check for reviews and photos the API stopped waiting for (over 4 s, or the call failed).
/// One still unanswered after an hour goes to a maintainer instead. Also deletes rejected content nobody appealed after a week
/// (docs/content-safety.md "Privacy": rejected text is not kept).
/// </summary>
public sealed class ContentScreeningRetry(IServiceScopeFactory scopes, TimeProvider clock, ILogger<ContentScreeningRetry> logger) : BackgroundService
{
    protected override async Task ExecuteAsync(CancellationToken stoppingToken)
    {
        using var timer = new PeriodicTimer(TimeSpan.FromMinutes(1), clock);
        do
        {
            try { await TickAsync(stoppingToken); }
            catch (Exception ex) when (ex is not OperationCanceledException) { logger.LogWarning("Content screening retry failed: {Message}", ex.Message); }
        } while (await timer.WaitForNextTickAsync(stoppingToken));
    }

    internal async Task TickAsync(CancellationToken ct)
    {
        var now = clock.GetUtcNow();
        await using var scope = scopes.CreateAsyncScope();
        var db = scope.ServiceProvider.GetRequiredService<GimanoDbContext>();
        var gate = scope.ServiceProvider.GetRequiredService<ContentGate>();
        var media = scope.ServiceProvider.GetRequiredService<IMediaStore>();
        var settled = now.AddSeconds(-30);
        int done = 0, gaveUp = 0;

        var reviews = await db.Reviews.Where(r => r.ModerationState == ContentState.Checking && (r.EditedAt ?? r.CreatedAt) < settled)
            .OrderBy(r => r.CreatedAt).Take(50).ToListAsync(ct);
        foreach (var r in reviews)
        {
            if (now - (r.EditedAt ?? r.CreatedAt) > ContentScreening.GiveUpAfter)
            {
                await gate.ApplyReviewAsync(r, new ContentOutcome(ContentOutcomeKind.Held, ["unclear"]), late: true, ct);
                gaveUp++;
                continue;
            }
            var placeName = CommunityPlace.IsCommunityId(r.PlaceId)
                ? await db.CommunityPlaces.AsNoTracking().Where(x => x.Id == r.PlaceId).Select(x => x.Name).FirstOrDefaultAsync(ct)
                : await db.Places.AsNoTracking().Where(x => x.Id == r.PlaceId).Select(x => x.Name).FirstOrDefaultAsync(ct);
            var outcome = await gate.CheckTextAsync(new ContentInput(r.EditedAt is null ? ContentKind.Review : ContentKind.ReviewEdit, r.Text, placeName), TimeSpan.FromSeconds(30), ct);
            if (outcome.Kind == ContentOutcomeKind.Checking) continue;
            await gate.ApplyReviewAsync(r, outcome, late: true, ct);
            done++;
        }

        var photos = await db.Photos.Include(p => p.User)
            .Where(p => p.ModerationState == ContentState.Checking && p.Key != null && p.CreatedAt < settled).OrderBy(p => p.CreatedAt).Take(20).ToListAsync(ct);
        foreach (var p in photos)
        {
            if (now - p.CreatedAt > ContentScreening.GiveUpAfter)
            {
                await gate.ApplyPhotoAsync(p, new ContentOutcome(ContentOutcomeKind.Held, ["unclear"]), late: true, ct);
                gaveUp++;
                continue;
            }
            var webp = await media.GetAsync(MediaKeys.Webp(p.Key!), ct);
            if (webp is null) { await gate.ApplyPhotoAsync(p, new ContentOutcome(ContentOutcomeKind.Held, ["unclear"]), late: true, ct); gaveUp++; continue; }
            var outcome = await Photos.PhotoProcessor.CheckAsync(gate, db, p, webp, ct);
            if (outcome.Kind == ContentOutcomeKind.Checking) continue;
            await gate.ApplyPhotoAsync(p, outcome, late: true, ct);
            done++;
        }
        if (done + gaveUp > 0) logger.LogInformation("Content screening: {Done} finished, {GaveUp} sent to a maintainer", done, gaveUp);

        await PurgeRejectedAsync(db, media, now, ct);
    }

    /// <summary>Rejected and never appealed for a week: the review is deleted; the photo's files are deleted and its row keeps no image.</summary>
    internal static async Task PurgeRejectedAsync(GimanoDbContext db, IMediaStore media, DateTimeOffset now, CancellationToken ct)
    {
        var cutoff = now - ContentScreening.KeepRejected;
        await db.Reviews.Where(r => r.ModerationState == ContentState.Rejected && r.AppealedAt == null && r.ModeratedAt < cutoff).ExecuteDeleteAsync(ct);
        var photos = await db.Photos.Where(p => p.ModerationState == ContentState.Rejected && p.AppealedAt == null && p.ModeratedAt < cutoff && p.Key != null)
            .Take(50).ToListAsync(ct);
        foreach (var p in photos)
        {
            var keys = new[] { p.Key, p.ThumbKey }.Where(k => k is not null).Select(k => k!).ToList();
            p.Key = null; p.ThumbKey = null;
            await db.SaveChangesAsync(ct);
            foreach (var key in keys)
                if (!await db.Photos.AnyAsync(x => x.Key == key || x.ThumbKey == key, ct)) await media.DeleteAsync(MediaKeys.Webp(key), ct);
        }
    }
}
