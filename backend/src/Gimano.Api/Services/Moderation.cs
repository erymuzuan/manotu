using Gimano.Core.Community;
using Gimano.Core.Contracts;
using Gimano.Core.Data;
using Gimano.Core.Domain;
using Gimano.Core.Messaging;
using Microsoft.EntityFrameworkCore;

namespace Gimano.Api.Services;

public enum ModerationKind { Review, Photo, Place, Appeal }

public sealed record ModerationFlag(FlagReason Reason, DateTimeOffset? At);

/// <summary>
/// One item in the moderation queue. The author appears only as display name + opaque handle (never the user id); act on
/// the author through the item ("ban the author of this review").
/// </summary>
public sealed record ModerationItem(ModerationKind Kind, string Id, string? PlaceId, string Status, int FlagCount,
    IReadOnlyList<ModerationFlag> Flags, string? Text, string? MediaUrl, string? AuthorName, string? AuthorRef,
    bool AuthorBanned, DateTimeOffset CreatedAt, bool Held = false, IReadOnlyList<string>? Reasons = null, string? AppealNote = null,
    IReadOnlyList<string>? EvidenceUrls = null, string? AppealKind = null, int? Rating = null, IReadOnlyList<string>? SuggestedWarnings = null);

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
    /// Reviews, photos and notes are paused while <c>SuspendedUntil</c> is in the future (3 AI rejections in 24 h; the same pause as for places).
    /// </summary>
    public static User EnsureNotPaused(User user, DateTimeOffset now) => user.SuspendedUntil is { } until && until > now
        ? throw new PostingPausedException(until, $"Posting is paused until {until:yyyy-MM-dd HH:mm} UTC because several of your posts were not accepted.")
        : user;

    /// <summary>
    /// The appeal note is compulsory: trimmed, 1 to 200 characters, friendly and without links. Anything else is 400 <c>note_required</c>.
    /// </summary>
    public static string CheckAppealNote(string? note)
    {
        var n = note?.Trim();
        if (string.IsNullOrEmpty(n)) throw new ApiCodeException(400, "note_required", "Please tell us, in a few words, why this should be reviewed.");
        if (n.Length > PlaceScreening.MaxAppealLength) throw new ApiCodeException(400, "note_required", $"The note is at most {PlaceScreening.MaxAppealLength} characters.");
        if (TextFilter.Default.Check(n, rejectLinks: true) != TextVerdict.Ok) throw new ApiCodeException(400, "note_required", "Please keep the note friendly and without links.");
        return n;
    }

    /// <summary>
    /// Flagged (or hidden) items, most-flagged first. state=flagged: visible items with at least one flag (to review);
    /// state=hidden: hidden by flags or a moderator (to restore or confirm).
    /// </summary>
    public async Task<IReadOnlyList<ModerationItem>> QueueAsync(ModerationKind? kind, bool hidden, CancellationToken ct)
    {
        var items = new List<ModerationItem>();
        if (kind is null or ModerationKind.Review)
        {
            // Hidden = flags, moderator hides and held content; reviews still "checking" or not accepted by the AI (nobody appealed) are not for a person yet.
            var q = db.Reviews.AsNoTracking().Include(r => r.User).Where(r => hidden
                ? r.Status == ReviewStatus.Hidden && r.ModerationState != ContentState.Checking && r.ModerationState != ContentState.Rejected
                : r.Status == ReviewStatus.Published && r.FlagCount > 0);
            foreach (var r in await q.OrderByDescending(r => r.FlagCount).ThenByDescending(r => r.CreatedAt).Take(200).ToListAsync(ct))
            {
                var flags = await db.ReviewFlags.AsNoTracking().Where(f => f.ReviewId == r.Id).Select(f => new ModerationFlag(f.Reason, f.CreatedAt)).ToListAsync(ct);
                items.Add(new ModerationItem(ModerationKind.Review, r.Id.ToString(), r.PlaceId, GimanoJson.ToWire(r.Status), r.FlagCount, flags, r.Text, null,
                    r.User?.DisplayName, handles.For(r.UserId), r.User?.BannedAt is not null, r.CreatedAt, r.HeldForReview,
                    ContentScreening.Split(r.ModerationReasons), r.AppealNote, EvidenceUrls(ModerationKind.Review, r.Id.ToString(), r.AppealEvidence)));
            }
        }
        if (kind is null or ModerationKind.Photo)
        {
            var q = db.Photos.AsNoTracking().Include(p => p.User).Where(p => hidden
                ? (p.Status == PhotoStatus.Rejected && p.FlagCount > 0) || p.ModerationState == ContentState.Held
                : p.Status == PhotoStatus.Published && p.FlagCount > 0);
            foreach (var p in await q.OrderByDescending(p => p.FlagCount).ThenByDescending(p => p.CreatedAt).Take(200).ToListAsync(ct))
            {
                var flags = await db.PhotoFlags.AsNoTracking().Where(f => f.PhotoId == p.Id).Select(f => new ModerationFlag(f.Reason, null)).ToListAsync(ct);
                items.Add(new ModerationItem(ModerationKind.Photo, p.Id.ToString(), p.PlaceId, GimanoJson.ToWire(p.Status), p.FlagCount, flags, p.Caption,
                    MediaKeys.Url(p.Key), p.User?.DisplayName, handles.For(p.UserId), p.User?.BannedAt is not null, p.CreatedAt,
                    p.ModerationState == ContentState.Held, ContentScreening.Split(p.ModerationReasons), p.AppealNote,
                    EvidenceUrls(ModerationKind.Photo, p.Id.ToString(), p.AppealEvidence)));
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
        if ((kind is null or ModerationKind.Place) && !hidden) items.AddRange(await OsmFlagItemsAsync(ct));
        if ((kind is null or ModerationKind.Appeal) && hidden) items.AddRange(await AppealItemsAsync(ct));
        return items.OrderByDescending(i => i.Held).ThenByDescending(i => i.FlagCount).ThenByDescending(i => i.CreatedAt).ToList();
    }

    /// <summary>
    /// Evidence images of an appeal: only maintainers (X-Admin-Key) can fetch them, from <c>GET /api/v1/admin/moderation/{kind}/{id}/evidence/{n}</c>.
    /// </summary>
    internal static IReadOnlyList<string>? EvidenceUrls(ModerationKind kind, string id, string? keys) =>
        AppealEvidence.Split(keys) is { Count: > 0 } k
            ? k.Select((_, i) => $"/api/v1/admin/moderation/{GimanoJson.ToWire(kind)}/{id}/evidence/{i}").ToList() : null;

    /// <summary>Appeals from POST /appeals that wait for a maintainer. Author: display name and opaque handle only.</summary>
    private async Task<List<ModerationItem>> AppealItemsAsync(CancellationToken ct)
    {
        var rows = await db.ContentAppeals.AsNoTracking().Where(a => a.Status == AppealStatus.Pending).OrderBy(a => a.CreatedAt).Take(200).ToListAsync(ct);
        var ids = rows.Select(a => a.UserId).Distinct().ToList();
        var users = await db.Users.AsNoTracking().Where(u => ids.Contains(u.Id)).Select(u => new { u.Id, u.DisplayName, Banned = u.BannedAt != null }).ToDictionaryAsync(u => u.Id, ct);
        var photoIds = rows.Where(a => a.Kind == AppealKind.Photo).Select(a => a.RefusalId).ToList();
        var photoKeys = await db.Photos.AsNoTracking().Where(p => photoIds.Contains(p.Id)).Select(p => new { p.Id, p.Key }).ToDictionaryAsync(p => p.Id, p => p.Key, ct);
        return rows.Select(a => new ModerationItem(ModerationKind.Appeal, a.Id.ToString(), a.PlaceId, "pending", 0, [], a.Text,
            a.Kind == AppealKind.Photo ? MediaKeys.Url(photoKeys.GetValueOrDefault(a.RefusalId)) : null,
            users.GetValueOrDefault(a.UserId)?.DisplayName, handles.For(a.UserId), users.GetValueOrDefault(a.UserId)?.Banned ?? false, a.CreatedAt, true,
            ContentScreening.Split(a.Reasons), a.Note, EvidenceUrls(ModerationKind.Appeal, a.Id.ToString(), a.EvidenceKeys), GimanoJson.ToWire(a.Kind), a.Rating)).ToList();
    }

    /// <summary>
    /// Reports on map (OSM) places: one item per place, with the public name, the reasons and the warnings users suggest. There is no author
    /// and nothing about the reporters. A maintainer fixes the map data upstream and dismisses the item (restore).
    /// </summary>
    private async Task<List<ModerationItem>> OsmFlagItemsAsync(CancellationToken ct)
    {
        var flags = await db.OsmPlaceFlags.AsNoTracking().OrderBy(f => f.CreatedAt).Take(1000).ToListAsync(ct);
        var ids = flags.Select(f => f.PlaceId).Distinct().Take(200).ToList();
        var names = await db.Places.AsNoTracking().Where(p => ids.Contains(p.Id)).Select(p => new { p.Id, p.Name }).ToDictionaryAsync(p => p.Id, p => p.Name, ct);
        return ids.Select(id =>
        {
            var mine = flags.Where(f => f.PlaceId == id).ToList();
            return new ModerationItem(ModerationKind.Place, id, id, "osm", mine.Count, mine.Select(f => new ModerationFlag(f.Reason, f.CreatedAt)).ToList(),
                names.GetValueOrDefault(id), null, null, null, false, mine.Min(f => f.CreatedAt),
                SuggestedWarnings: PlaceWarnings.Normalize(mine.SelectMany(f => PlaceWarnings.Split(f.SuggestedWarnings))));
        }).ToList();
    }

    /// <summary>The evidence image <paramref name="index"/> of an appeal (new appeal, or an older review/photo appeal); null when there is none.</summary>
    public async Task<byte[]?> EvidenceAsync(ModerationKind kind, string id, int index, IMediaStore media, CancellationToken ct)
    {
        string? keys = kind switch
        {
            ModerationKind.Appeal => await db.ContentAppeals.AsNoTracking().Where(a => a.Id == ParseGuid(id)).Select(a => a.EvidenceKeys).FirstOrDefaultAsync(ct),
            ModerationKind.Review => await db.Reviews.AsNoTracking().Where(r => r.Id == ParseGuid(id)).Select(r => r.AppealEvidence).FirstOrDefaultAsync(ct),
            ModerationKind.Photo => await db.Photos.AsNoTracking().Where(p => p.Id == ParseGuid(id)).Select(p => p.AppealEvidence).FirstOrDefaultAsync(ct),
            _ => null,
        };
        var all = AppealEvidence.Split(keys);
        return index >= 0 && index < all.Count ? await media.GetAsync(all[index], ct) : null;
    }

    /// <summary>Hides an item (review hidden, photo rejected, place hidden).</summary>
    public async Task HideAsync(ModerationKind kind, string id, CancellationToken ct)
    {
        string? placeId = null, rejectedHeld = null;
        (string Kind, string Id, string Place)? contentRejected = null;
        switch (kind)
        {
            case ModerationKind.Review:
                var r = await db.Reviews.FirstOrDefaultAsync(x => x.Id == ParseGuid(id), ct) ?? throw new NotFoundException("Review not found.");
                // A review the AI check held and a maintainer refuses: its author hears "not accepted" (and may appeal once).
                if (r.ModerationState == ContentState.Held) { r.ModerationState = ContentState.Rejected; r.ModeratedAt = clock.GetUtcNow(); contentRejected = ("review", r.Id.ToString(), r.PlaceId); }
                r.Status = ReviewStatus.Hidden; r.HeldForReview = false; placeId = r.PlaceId;
                break;
            case ModerationKind.Photo:
                var p = await db.Photos.FirstOrDefaultAsync(x => x.Id == ParseGuid(id), ct) ?? throw new NotFoundException("Photo not found.");
                if (p.ModerationState == ContentState.Held) { p.ModerationState = ContentState.Rejected; p.ModeratedAt = clock.GetUtcNow(); contentRejected = ("photo", p.Id.ToString(), p.PlaceId); }
                p.Status = PhotoStatus.Rejected; p.RejectReason = "moderation"; placeId = p.PlaceId;
                break;
            case ModerationKind.Appeal:
                await DenyAppealAsync(id, ct);
                return;
            case ModerationKind.Place:
                if (!CommunityPlace.IsCommunityId(id)) throw new ConflictException("A map (OSM) place can't be hidden here: fix the map data, then dismiss the reports (restore).");
                var c = await db.CommunityPlaces.FirstOrDefaultAsync(x => x.Id == id, ct) ?? throw new NotFoundException("Place not found.");
                // A held place the maintainer refuses: the owner gets the usual "not published" Inbox note.
                if (c.HeldForReview) rejectedHeld = c.Id;
                c.Status = PlaceStatus.Hidden; c.HeldForReview = false; c.UpdatedAt = clock.GetUtcNow(); placeId = c.Id;
                break;
        }
        await db.SaveChangesAsync(ct);
        if (placeId is not null) await bus.PublishAsync(RoutingKeys.PlaceChanged, new PlaceChangedEvent(placeId), ct);
        if (rejectedHeld is not null) await bus.PublishAsync(RoutingKeys.PlaceVerified, new PlaceVerifiedEvent(rejectedHeld, PlaceStatus.Hidden), ct);
        if (contentRejected is { } cr) await bus.PublishAsync(RoutingKeys.ContentScreened, new ContentScreenedEvent(cr.Kind, cr.Id, cr.Place, ContentState.Rejected, Late: true), ct);
    }

    /// <summary>Restores an item a moderator found fine (also "dismiss": its flags are cleared, so it leaves the queue).</summary>
    public async Task RestoreAsync(ModerationKind kind, string id, CancellationToken ct, string? adminActor = null)
    {
        await using var transaction = kind == ModerationKind.Place && CommunityPlace.IsCommunityId(id)
            ? await db.Database.BeginTransactionAsync(ct) : null;
        if (transaction is not null)
            await db.Database.ExecuteSqlInterpolatedAsync($"SELECT pg_advisory_xact_lock(hashtextextended({"place-restore:" + id}, 0))", ct);
        string placeId;
        string? acceptedScreened = null;
        (string Kind, string Id)? contentApproved = null;
        switch (kind)
        {
            case ModerationKind.Appeal:
                await ApproveAppealAsync(id, ct);
                return;
            case ModerationKind.Review:
            {
                var gid = ParseGuid(id);
                var r = await db.Reviews.FirstOrDefaultAsync(x => x.Id == gid, ct) ?? throw new NotFoundException("Review not found.");
                if (r.ModerationState is ContentState.Held or ContentState.Rejected) { r.ModerationState = ContentState.Passed; r.ModerationReasons = null; r.ModeratedAt = clock.GetUtcNow(); contentApproved = ("review", r.Id.ToString()); }
                r.Status = ReviewStatus.Published; r.FlagCount = 0; r.HeldForReview = false; placeId = r.PlaceId;
                await db.ReviewFlags.Where(f => f.ReviewId == gid).ExecuteDeleteAsync(ct);
                break;
            }
            case ModerationKind.Photo:
            {
                var gid = ParseGuid(id);
                var p = await db.Photos.Include(x => x.User).FirstOrDefaultAsync(x => x.Id == gid, ct) ?? throw new NotFoundException("Photo not found.");
                if (p.Key is null) throw new ConflictException("This photo was never processed.");
                if (p.ModerationState is ContentState.Held or ContentState.Rejected)
                {
                    // Not published before (held or not accepted by the check): the uploader earns the +2 now, like an auto-published photo.
                    if (p.User is { } uploader) uploader.Points += CommunityRules.Points.Photo;
                    p.ModerationState = ContentState.Passed; p.ModerationReasons = null; p.ModeratedAt = clock.GetUtcNow(); contentApproved = ("photo", p.Id.ToString());
                }
                p.Status = PhotoStatus.Published; p.RejectReason = null; p.FlagCount = 0; placeId = p.PlaceId;
                await db.PhotoFlags.Where(f => f.PhotoId == gid).ExecuteDeleteAsync(ct);
                break;
            }
            default:
            {
                if (!CommunityPlace.IsCommunityId(id))
                {
                    // Reports on a map (OSM) place: dismissed (nothing else changes; map data is fixed upstream).
                    if (await db.OsmPlaceFlags.Where(f => f.PlaceId == id).ExecuteDeleteAsync(ct) == 0) throw new NotFoundException("Place not found.");
                    return;
                }
                var c = await db.CommunityPlaces.FirstOrDefaultAsync(x => x.Id == id, ct) ?? throw new NotFoundException("Place not found.");
                await db.Entry(c).ReloadAsync(ct);
                var before = $"status={c.Status} screening={c.ScreeningState} listed={c.Listed}";
                // Back to what it was before the flags: published once verified, otherwise still waiting for verification.
                if (c.Status is PlaceStatus.Hidden or PlaceStatus.Rejected) c.Status = c.ResolvedAt is null ? PlaceStatus.Pending : PlaceStatus.Published;
                // A place the AI check held or rejected that a maintainer accepts goes live like a passed one, and its owner hears it.
                if (c.ScreeningState is Core.Community.ScreeningState.Held or Core.Community.ScreeningState.Rejected
                    || (c.Status == PlaceStatus.Pending && c.ScreeningState == Core.Community.ScreeningState.None))
                {
                    c.ScreeningState = Core.Community.ScreeningState.Passed;
                    c.ScreenedAt = clock.GetUtcNow();
                    c.Listed = c.Status == PlaceStatus.Pending;
                    acceptedScreened = c.Id;
                }
                c.FlagCount = 0; c.HeldForReview = false; c.UpdatedAt = clock.GetUtcNow(); placeId = c.Id;
                db.AuditLog.Add(new AuditEntry
                {
                    At = clock.GetUtcNow(), Actor = adminActor ?? "moderation-service", ActorKind = adminActor is null ? "system" : "admin",
                    Action = "place.restore", TargetType = "community_place", TargetId = c.Id,
                    Detail = $"{before} -> status={c.Status} screening={c.ScreeningState} listed={c.Listed}",
                });
                await db.PlaceFlags.Where(f => f.PlaceId == id).ExecuteDeleteAsync(ct);
                break;
            }
        }
        await db.SaveChangesAsync(ct);
        if (transaction is not null) await transaction.CommitAsync(ct);
        await bus.PublishAsync(RoutingKeys.PlaceChanged, new PlaceChangedEvent(placeId), ct);
        if (contentApproved is { } ca) await bus.PublishAsync(RoutingKeys.ContentScreened, new ContentScreenedEvent(ca.Kind, ca.Id, placeId, ContentState.Passed, Late: true), ct);
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
            ModerationKind.Appeal => await db.ContentAppeals.Where(a => a.Id == ParseGuid(id)).Select(a => (Guid?)a.UserId).FirstOrDefaultAsync(ct),
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
            ModerationKind.Appeal => await db.ContentAppeals.Where(a => a.Id == ParseGuid(id)).Select(a => (Guid?)a.UserId).FirstOrDefaultAsync(ct),
            _ => await db.CommunityPlaces.Where(p => p.Id == id).Select(p => p.OwnerId).FirstOrDefaultAsync(ct),
        };
        if (author is not { } uid) return false;
        await db.Users.Where(u => u.Id == uid).ExecuteUpdateAsync(s => s.SetProperty(u => u.BannedAt, (DateTimeOffset?)null), ct);
        return true;
    }

    /// <summary>
    /// Approve an appeal. Review: the review is created, published, for the author (+3 points), who hears Inbox <c>content_published</c>.
    /// Photo and place: the existing approve paths (<see cref="RestoreAsync"/>), so a photo earns its +2 and a place goes live.
    /// </summary>
    private async Task ApproveAppealAsync(string id, CancellationToken ct)
    {
        var a = await db.ContentAppeals.FirstOrDefaultAsync(x => x.Id == ParseGuid(id), ct) ?? throw new NotFoundException("Appeal not found.");
        if (a.Status != AppealStatus.Pending) throw new ConflictException("This appeal was already decided.");
        var now = clock.GetUtcNow();
        a.Status = AppealStatus.Approved;
        a.DecidedAt = now;
        switch (a.Kind)
        {
            case AppealKind.Review:
            {
                if (await db.Reviews.AnyAsync(r => r.PlaceId == a.PlaceId && r.UserId == a.UserId, ct))
                    throw new ConflictException("The author already has a review at this place.");
                var user = await db.Users.FirstOrDefaultAsync(u => u.Id == a.UserId, ct) ?? throw new NotFoundException("The author's account was deleted.");
                var review = new Review
                {
                    PlaceId = a.PlaceId, UserId = a.UserId, Rating = a.Rating ?? 5, Text = a.Text, Status = ReviewStatus.Published,
                    ModerationState = ContentState.Passed, ModeratedAt = now, CreatedAt = now,
                };
                db.Reviews.Add(review);
                user.Points += CommunityRules.Points.Review;
                a.ReviewId = review.Id;
                await db.SaveChangesAsync(ct);
                await bus.PublishAsync(RoutingKeys.PlaceChanged, new PlaceChangedEvent(a.PlaceId), ct);
                await bus.PublishAsync(RoutingKeys.ContentScreened, new ContentScreenedEvent("review", review.Id.ToString(), a.PlaceId, ContentState.Passed, Late: true), ct);
                break;
            }
            case AppealKind.Photo:
                await db.SaveChangesAsync(ct);
                try { await RestoreAsync(ModerationKind.Photo, a.RefusalId.ToString(), ct); } catch (NotFoundException) { /* the photo was deleted meanwhile */ }
                break;
            default:
                await db.SaveChangesAsync(ct);
                try { await RestoreAsync(ModerationKind.Place, a.PlaceId, ct); } catch (NotFoundException) { /* the place was deleted meanwhile */ }
                break;
        }
    }

    /// <summary>Deny an appeal: the decision stands. The author hears Inbox <c>content_rejected</c> with <c>canAppeal=false</c>; nothing is published.</summary>
    private async Task DenyAppealAsync(string id, CancellationToken ct)
    {
        var a = await db.ContentAppeals.FirstOrDefaultAsync(x => x.Id == ParseGuid(id), ct) ?? throw new NotFoundException("Appeal not found.");
        if (a.Status != AppealStatus.Pending) throw new ConflictException("This appeal was already decided.");
        a.Status = AppealStatus.Denied;
        a.DecidedAt = clock.GetUtcNow();
        await db.SaveChangesAsync(ct);
        var subjectId = a.Kind == AppealKind.Place ? a.PlaceId : a.RefusalId.ToString();
        await bus.PublishAsync(RoutingKeys.ContentScreened,
            new ContentScreenedEvent(GimanoJson.ToWire(a.Kind), subjectId, a.PlaceId, ContentState.Rejected, Late: true, AppealId: a.Id), ct);
    }

    private static Guid ParseGuid(string id) => Guid.TryParse(id, out var g) ? g : throw new NotFoundException("Not found.");
}
