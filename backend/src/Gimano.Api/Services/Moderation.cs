using Gimano.Core.Community;
using Gimano.Core.Contracts;
using Gimano.Core.Data;
using Gimano.Core.Domain;
using Gimano.Core.Messaging;
using Microsoft.EntityFrameworkCore;

namespace Gimano.Api.Services;

public enum ModerationKind { Review, Photo, Place }

public sealed record ModerationFlag(FlagReason Reason, DateTimeOffset? At);

/// <summary>
/// One item in the moderation queue. The author appears only as display name + opaque handle (never the user id); act on
/// the author through the item ("ban the author of this review").
/// </summary>
public sealed record ModerationItem(ModerationKind Kind, string Id, string? PlaceId, string Status, int FlagCount,
    IReadOnlyList<ModerationFlag> Flags, string? Text, string? MediaUrl, string? AuthorName, string? AuthorRef,
    bool AuthorBanned, DateTimeOffset CreatedAt, bool Held = false);

/// <summary>
/// Moderation of user content (Apple 1.2 / Play UGC; docs/back-office.md "Moderation"): flagged reviews, photos and
/// community places, hide/restore, and banning abusive contributors (their public content is hidden, new contributions
/// are refused). Maintainers reach it through /api/v1/admin/moderation (X-Admin-Key).
/// </summary>
public sealed class Moderation(GimanoDbContext db, IEventPublisher bus, AuthorHandles handles, TimeProvider clock)
{
    /// <summary>Refuses new public contributions from a banned account.</summary>
    public static User EnsureMayContribute(User user) => user.BannedAt is null ? user
        : throw new ForbiddenException("This account can no longer post public content (community rules: https://manotu.app/terms/).");

    /// <summary>
    /// Flagged (or hidden) items, most-flagged first. state=flagged: visible items with at least one flag (to review);
    /// state=hidden: hidden by flags or a moderator (to restore or confirm).
    /// </summary>
    public async Task<IReadOnlyList<ModerationItem>> QueueAsync(ModerationKind? kind, bool hidden, CancellationToken ct)
    {
        var items = new List<ModerationItem>();
        if (kind is null or ModerationKind.Review)
        {
            var q = db.Reviews.AsNoTracking().Include(r => r.User).Where(r => hidden ? r.Status == ReviewStatus.Hidden : r.Status == ReviewStatus.Published && r.FlagCount > 0);
            foreach (var r in await q.OrderByDescending(r => r.FlagCount).ThenByDescending(r => r.CreatedAt).Take(200).ToListAsync(ct))
            {
                var flags = await db.ReviewFlags.AsNoTracking().Where(f => f.ReviewId == r.Id).Select(f => new ModerationFlag(f.Reason, f.CreatedAt)).ToListAsync(ct);
                items.Add(new ModerationItem(ModerationKind.Review, r.Id.ToString(), r.PlaceId, GimanoJson.ToWire(r.Status), r.FlagCount, flags, r.Text, null,
                    r.User?.DisplayName, handles.For(r.UserId), r.User?.BannedAt is not null, r.CreatedAt, r.HeldForReview));
            }
        }
        if (kind is null or ModerationKind.Photo)
        {
            var q = db.Photos.AsNoTracking().Include(p => p.User).Where(p => hidden ? p.Status == PhotoStatus.Rejected && p.FlagCount > 0 : p.Status == PhotoStatus.Published && p.FlagCount > 0);
            foreach (var p in await q.OrderByDescending(p => p.FlagCount).ThenByDescending(p => p.CreatedAt).Take(200).ToListAsync(ct))
            {
                var flags = await db.PhotoFlags.AsNoTracking().Where(f => f.PhotoId == p.Id).Select(f => new ModerationFlag(f.Reason, null)).ToListAsync(ct);
                items.Add(new ModerationItem(ModerationKind.Photo, p.Id.ToString(), p.PlaceId, GimanoJson.ToWire(p.Status), p.FlagCount, flags, p.Caption,
                    MediaKeys.Url(p.Key), p.User?.DisplayName, handles.For(p.UserId), p.User?.BannedAt is not null, p.CreatedAt));
            }
        }
        if (kind is null or ModerationKind.Place)
        {
            // Held places (near a restricted area, sensitive words) wait in the hidden queue without any flag.
            var q = db.CommunityPlaces.AsNoTracking().Include(p => p.Owner).Where(p => hidden
                ? p.Status == PlaceStatus.Hidden && (p.FlagCount > 0 || p.HeldForReview)
                : p.FlagCount > 0 && (p.Status == PlaceStatus.Pending || p.Status == PlaceStatus.Published));
            foreach (var p in await q.OrderByDescending(p => p.FlagCount).ThenByDescending(p => p.CreatedAt).Take(200).ToListAsync(ct))
            {
                var flags = await db.PlaceFlags.AsNoTracking().Where(f => f.PlaceId == p.Id).Select(f => new ModerationFlag(f.Reason, f.CreatedAt)).ToListAsync(ct);
                items.Add(new ModerationItem(ModerationKind.Place, p.Id, p.Id, GimanoJson.ToWire(p.Status), p.FlagCount, flags,
                    string.Join(" · ", new[]
                    {
                        p.Name, p.Description, p.Website,
                        p.ScreeningReasons is { Length: > 0 } r ? $"[AI check: {r}]" : null,
                        p.AppealedAt is not null ? $"[Review asked: {p.AppealNote ?? "no note"}]" : null,
                    }.Where(x => !string.IsNullOrWhiteSpace(x))), null,
                    p.Owner?.DisplayName, handles.For(p.OwnerId), p.Owner?.BannedAt is not null, p.CreatedAt, p.HeldForReview));
            }
        }
        return items.OrderByDescending(i => i.Held).ThenByDescending(i => i.FlagCount).ThenByDescending(i => i.CreatedAt).ToList();
    }

    /// <summary>Hides an item (review hidden, photo rejected, place hidden).</summary>
    public async Task HideAsync(ModerationKind kind, string id, CancellationToken ct)
    {
        string? placeId = null, rejectedHeld = null;
        switch (kind)
        {
            case ModerationKind.Review:
                var r = await db.Reviews.FirstOrDefaultAsync(x => x.Id == ParseGuid(id), ct) ?? throw new NotFoundException("Review not found.");
                r.Status = ReviewStatus.Hidden; r.HeldForReview = false; placeId = r.PlaceId;
                break;
            case ModerationKind.Photo:
                var p = await db.Photos.FirstOrDefaultAsync(x => x.Id == ParseGuid(id), ct) ?? throw new NotFoundException("Photo not found.");
                p.Status = PhotoStatus.Rejected; p.RejectReason = "moderation"; placeId = p.PlaceId;
                break;
            case ModerationKind.Place:
                var c = await db.CommunityPlaces.FirstOrDefaultAsync(x => x.Id == id, ct) ?? throw new NotFoundException("Place not found.");
                // A held place the maintainer refuses: the owner gets the usual "not published" Inbox note.
                if (c.HeldForReview) rejectedHeld = c.Id;
                c.Status = PlaceStatus.Hidden; c.HeldForReview = false; c.UpdatedAt = clock.GetUtcNow(); placeId = c.Id;
                break;
        }
        await db.SaveChangesAsync(ct);
        if (placeId is not null) await bus.PublishAsync(RoutingKeys.PlaceChanged, new PlaceChangedEvent(placeId), ct);
        if (rejectedHeld is not null) await bus.PublishAsync(RoutingKeys.PlaceVerified, new PlaceVerifiedEvent(rejectedHeld, PlaceStatus.Hidden), ct);
    }

    /// <summary>Restores an item a moderator found fine (also "dismiss": its flags are cleared, so it leaves the queue).</summary>
    public async Task RestoreAsync(ModerationKind kind, string id, CancellationToken ct)
    {
        string placeId;
        string? acceptedScreened = null;
        switch (kind)
        {
            case ModerationKind.Review:
            {
                var gid = ParseGuid(id);
                var r = await db.Reviews.FirstOrDefaultAsync(x => x.Id == gid, ct) ?? throw new NotFoundException("Review not found.");
                r.Status = ReviewStatus.Published; r.FlagCount = 0; r.HeldForReview = false; placeId = r.PlaceId;
                await db.ReviewFlags.Where(f => f.ReviewId == gid).ExecuteDeleteAsync(ct);
                break;
            }
            case ModerationKind.Photo:
            {
                var gid = ParseGuid(id);
                var p = await db.Photos.FirstOrDefaultAsync(x => x.Id == gid, ct) ?? throw new NotFoundException("Photo not found.");
                if (p.Key is null) throw new ConflictException("This photo was never processed.");
                p.Status = PhotoStatus.Published; p.RejectReason = null; p.FlagCount = 0; placeId = p.PlaceId;
                await db.PhotoFlags.Where(f => f.PhotoId == gid).ExecuteDeleteAsync(ct);
                break;
            }
            default:
            {
                var c = await db.CommunityPlaces.FirstOrDefaultAsync(x => x.Id == id, ct) ?? throw new NotFoundException("Place not found.");
                // Back to what it was before the flags: published once verified, otherwise still waiting for verification.
                if (c.Status is PlaceStatus.Hidden or PlaceStatus.Rejected) c.Status = c.ResolvedAt is null ? PlaceStatus.Pending : PlaceStatus.Published;
                // A place the AI check held or rejected that a maintainer accepts goes live like a passed one, and its owner hears it.
                if (c.ScreeningState is Core.Community.ScreeningState.Held or Core.Community.ScreeningState.Rejected)
                {
                    c.ScreeningState = Core.Community.ScreeningState.Passed;
                    c.Listed = c.Status == PlaceStatus.Pending;
                    acceptedScreened = c.Id;
                }
                c.FlagCount = 0; c.HeldForReview = false; c.UpdatedAt = clock.GetUtcNow(); placeId = c.Id;
                await db.PlaceFlags.Where(f => f.PlaceId == id).ExecuteDeleteAsync(ct);
                break;
            }
        }
        await db.SaveChangesAsync(ct);
        await bus.PublishAsync(RoutingKeys.PlaceChanged, new PlaceChangedEvent(placeId), ct);
        if (acceptedScreened is not null)
            await bus.PublishAsync(RoutingKeys.PlaceScreened, new PlaceScreenedEvent(acceptedScreened, Core.Community.ScreeningState.Passed, Late: true), ct);
    }

    /// <summary>
    /// Bans the author of an item: the account can't post public content any more, and all of their reviews, photos,
    /// community places and active road reports are hidden. Returns false when the item has no author left (deleted account).
    /// </summary>
    public async Task<bool> BanAuthorAsync(ModerationKind kind, string id, CancellationToken ct)
    {
        Guid? author = kind switch
        {
            ModerationKind.Review => await db.Reviews.Where(r => r.Id == ParseGuid(id)).Select(r => r.UserId).FirstOrDefaultAsync(ct),
            ModerationKind.Photo => await db.Photos.Where(p => p.Id == ParseGuid(id)).Select(p => p.UserId).FirstOrDefaultAsync(ct),
            _ => await db.CommunityPlaces.Where(p => p.Id == id).Select(p => p.OwnerId).FirstOrDefaultAsync(ct),
        };
        if (author is not { } uid) return false;
        var now = clock.GetUtcNow();
        await db.Users.Where(u => u.Id == uid && u.BannedAt == null).ExecuteUpdateAsync(s => s.SetProperty(u => u.BannedAt, now), ct);
        var places = await db.Reviews.Where(r => r.UserId == uid).Select(r => r.PlaceId)
            .Concat(db.Photos.Where(p => p.UserId == uid).Select(p => p.PlaceId))
            .Concat(db.CommunityPlaces.Where(p => p.OwnerId == uid).Select(p => p.Id)).Distinct().ToListAsync(ct);
        await db.Reviews.Where(r => r.UserId == uid).ExecuteUpdateAsync(s => s.SetProperty(r => r.Status, ReviewStatus.Hidden), ct);
        await db.Photos.Where(p => p.UserId == uid && p.Status != PhotoStatus.Rejected)
            .ExecuteUpdateAsync(s => s.SetProperty(p => p.Status, PhotoStatus.Rejected).SetProperty(p => p.RejectReason, "author banned"), ct);
        await db.CommunityPlaces.Where(p => p.OwnerId == uid && (p.Status == PlaceStatus.Pending || p.Status == PlaceStatus.Published))
            .ExecuteUpdateAsync(s => s.SetProperty(p => p.Status, PlaceStatus.Hidden).SetProperty(p => p.UpdatedAt, now), ct);
        var reports = await db.Reports.Where(r => r.ReporterId == uid && r.Status == ReportStatus.Active).Select(r => r.Id).ToListAsync(ct);
        await db.Reports.Where(r => reports.Contains(r.Id))
            .ExecuteUpdateAsync(s => s.SetProperty(r => r.Status, ReportStatus.Expired).SetProperty(r => r.ExpiresAt, now), ct);
        foreach (var p in places) await bus.PublishAsync(RoutingKeys.PlaceChanged, new PlaceChangedEvent(p), ct);
        foreach (var r in reports) await bus.PublishAsync(RoutingKeys.ReportExpired, new ReportExpiredEvent(r), ct);
        return true;
    }

    /// <summary>Lifts a ban; hidden content stays hidden until restored item by item.</summary>
    public async Task<bool> UnbanAuthorAsync(ModerationKind kind, string id, CancellationToken ct)
    {
        Guid? author = kind switch
        {
            ModerationKind.Review => await db.Reviews.Where(r => r.Id == ParseGuid(id)).Select(r => r.UserId).FirstOrDefaultAsync(ct),
            ModerationKind.Photo => await db.Photos.Where(p => p.Id == ParseGuid(id)).Select(p => p.UserId).FirstOrDefaultAsync(ct),
            _ => await db.CommunityPlaces.Where(p => p.Id == id).Select(p => p.OwnerId).FirstOrDefaultAsync(ct),
        };
        if (author is not { } uid) return false;
        await db.Users.Where(u => u.Id == uid).ExecuteUpdateAsync(s => s.SetProperty(u => u.BannedAt, (DateTimeOffset?)null), ct);
        return true;
    }

    private static Guid ParseGuid(string id) => Guid.TryParse(id, out var g) ? g : throw new NotFoundException("Not found.");
}
