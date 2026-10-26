using Gimano.Api.Auth;
using Gimano.Core.Community;
using Gimano.Core.Contracts;
using Gimano.Core.Data;
using Microsoft.AspNetCore.Http.HttpResults;
using Microsoft.EntityFrameworkCore;

namespace Gimano.Api.Endpoints;

/// <summary>Inbox: notifications about the user's own public contributions + broadcast announcements (docs/api.md "Inbox").</summary>
public static class InboxEndpoints
{
    public static RouteGroupBuilder MapInbox(this RouteGroupBuilder api)
    {
        var g = api.MapGroup("/me/inbox").WithTags("Inbox").RequireAuthorization();
        g.MapGet("", List);
        g.MapPost("/read", MarkRead);
        return api;
    }

    private static async Task<Results<Ok<InboxPage>, NotFound>> List(string? cursor, HttpContext http, GimanoDbContext db, TimeProvider clock, CancellationToken ct)
    {
        var uid = http.User.RequiredUserId();
        var user = await db.Users.AsNoTracking().FirstOrDefaultAsync(u => u.Id == uid, ct);
        if (user is null) return TypedResults.NotFound();
        await EnsureLegacyNoticeAsync(db, user, clock.GetUtcNow(), ct);
        var now = clock.GetUtcNow();
        var since = now - InboxRules.Retention;
        var c = InboxRules.DecodeCursor(cursor);
        var readUpTo = user.InboxReadUpTo ?? DateTimeOffset.MinValue;
        var take = InboxRules.PageSize + 1;

        var iq = db.InboxItems.AsNoTracking().Where(i => i.UserId == uid && i.CreatedAt > since);
        var aq = db.Announcements.AsNoTracking().Where(InboxRules.VisibleAnnouncement(now));
        if (c is { } cur)
        {
            iq = iq.Where(i => i.CreatedAt < cur.At || (i.CreatedAt == cur.At && i.Id.CompareTo(cur.Id) < 0));
            aq = aq.Where(a => a.CreatedAt < cur.At || (a.CreatedAt == cur.At && a.Id.CompareTo(cur.Id) < 0));
        }
        var items = await iq.OrderByDescending(i => i.CreatedAt).ThenByDescending(i => i.Id).Take(take).ToListAsync(ct);
        var anns = await aq.OrderByDescending(a => a.CreatedAt).ThenByDescending(a => a.Id).Take(take).ToListAsync(ct);
        var lang = http.Lang();
        var ms = lang == Gimano.Core.Community.L10n.Ms;

        var (page, next) = InboxRules.Merge(
            items.Select(i =>
            {
                var (title, body) = InboxRules.Render(i, lang);
                var content = i.Kind is InboxKind.ContentPublished or InboxKind.ContentHeld or InboxKind.ContentRejected;
                return new InboxItemDto(i.Id, i.Kind, title, body, i.RefType, i.RefId, i.CreatedAt, i.CreatedAt <= readUpTo, i.Count,
                    content ? i.RefType : null, content ? i.RefId : null, content ? i.PlaceId : null,
                    content ? ContentScreening.Split(i.Reasons) : null, content ? i.CanAppeal ?? false : null);
            }),
            anns.Select(a => new InboxItemDto(a.Id, InboxKind.Announcement, ms ? a.TitleMs ?? a.Title : a.Title, ms ? a.BodyMs ?? a.Body : a.Body,
                a.Url is null ? null : "url", a.Url, a.CreatedAt, a.CreatedAt <= readUpTo)));

        var unread = await db.InboxItems.CountAsync(i => i.UserId == uid && i.CreatedAt > since && i.CreatedAt > readUpTo, ct)
                     + await db.Announcements.Where(InboxRules.VisibleAnnouncement(now)).CountAsync(a => a.CreatedAt > readUpTo, ct);
        return TypedResults.Ok(new InboxPage(page, next, unread));
    }

    /// <summary>Key-less legacy accounts get one "update to protect your account" item (removed once a key is attached).</summary>
    internal static async Task EnsureLegacyNoticeAsync(GimanoDbContext db, Gimano.Core.Domain.User user, DateTimeOffset now, CancellationToken ct)
    {
        if (await db.UserKeys.AnyAsync(k => k.UserId == user.Id && k.RevokedAt == null, ct)) return;
        if (await db.InboxItems.AnyAsync(i => i.UserId == user.Id && i.AggregateKey == InboxRules.LegacyUpdateKey, ct)) return;
        var (title, body) = InboxRules.LegacyUpdateText(user.Locale);
        db.InboxItems.Add(new Gimano.Core.Domain.InboxItem
        {
            UserId = user.Id, Kind = InboxKind.Announcement, Title = title, Body = body, AggregateKey = InboxRules.LegacyUpdateKey, CreatedAt = now,
        });
        try { await db.SaveChangesAsync(ct); } catch (DbUpdateException) { /* concurrent insert: already there */ }
    }

    /// <summary>Marks everything created at or before <c>upTo</c> as read (monotonic; never moves backwards).</summary>
    private static async Task<NoContent> MarkRead(InboxReadRequest req, HttpContext http, GimanoDbContext db, TimeProvider clock, CancellationToken ct)
    {
        var uid = http.User.RequiredUserId();
        var upTo = req.UpTo > clock.GetUtcNow() ? clock.GetUtcNow() : req.UpTo;
        await db.Users.Where(u => u.Id == uid && (u.InboxReadUpTo == null || u.InboxReadUpTo < upTo))
            .ExecuteUpdateAsync(s => s.SetProperty(u => u.InboxReadUpTo, upTo), ct);
        return TypedResults.NoContent();
    }
}
