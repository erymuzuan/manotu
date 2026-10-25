using System.Globalization;
using System.Net;
using System.Text;
using Gimano.Core.Contracts;
using Gimano.Core.Data;
using Gimano.Core.Domain;
using Gimano.Core.Routing;
using Microsoft.EntityFrameworkCore;

namespace Gimano.Core.Support;

/// <summary>
/// What the maintainer digest reports. Counts and ages only: never message text, contacts, names, ids or coordinates, so the
/// email stays inside the privacy rule (AGENTS.md) even though it leaves our servers.
/// </summary>
public sealed record DigestCounts(
    int FeedbackNew, IReadOnlyDictionary<FeedbackCategory, int> FeedbackNewByCategory, int FeedbackUntriaged, TimeSpan? OldestUntriaged,
    int CrashGroupsNew, int CrashGroupsRegressed, int CrashGroupsOpen,
    int ModerationWaiting, int PlacesHeld, TimeSpan? OldestModeration)
{
    public bool IsQuiet => FeedbackNew == 0 && FeedbackUntriaged == 0 && CrashGroupsNew == 0 && CrashGroupsRegressed == 0 && ModerationWaiting == 0;
}

/// <summary>Daily counts-only email to maintainers, plus an alert when a moderation item nears the 24-hour promise (docs/back-office.md).</summary>
public static class MaintainerDigest
{
    /// <summary>Alert when the oldest moderation item has waited this long (we promise action within 24 h).</summary>
    public static readonly TimeSpan ModerationAlertAge = TimeSpan.FromHours(20);
    /// <summary>At most one moderation alert per this period.</summary>
    public static readonly TimeSpan AlertCooldown = TimeSpan.FromHours(12);

    public static async Task<DigestCounts> CountAsync(GimanoDbContext db, DateTimeOffset now, CancellationToken ct)
    {
        var since = now.AddDays(-1);
        var byCategory = await db.Feedback.AsNoTracking().Where(f => f.CreatedAt > since)
            .GroupBy(f => f.Category).Select(g => new { g.Key, Count = g.Count() }).ToListAsync(ct);
        var untriaged = db.Feedback.AsNoTracking().Where(f => f.Status == FeedbackStatus.Received);
        var oldestUntriaged = await untriaged.OrderBy(f => f.CreatedAt).Select(f => (DateTimeOffset?)f.CreatedAt).FirstOrDefaultAsync(ct);

        var crashesNew = await db.CrashGroups.AsNoTracking().CountAsync(g => g.FirstSeen > since, ct);
        var regressed = await db.CrashGroups.AsNoTracking().CountAsync(g => g.Status == CrashGroupStatus.Regressed, ct);
        var open = await db.CrashGroups.AsNoTracking().CountAsync(g => g.Status == CrashGroupStatus.Open || g.Status == CrashGroupStatus.Regressed, ct);

        // The same predicates as the moderation queue (Gimano.Api Moderation.QueueAsync).
        var reviews = await db.Reviews.AsNoTracking().CountAsync(r => r.Status == ReviewStatus.Hidden || (r.Status == ReviewStatus.Published && r.FlagCount > 0), ct);
        var photos = await db.Photos.AsNoTracking().CountAsync(p => p.FlagCount > 0 && (p.Status == PhotoStatus.Rejected || p.Status == PhotoStatus.Published), ct);
        var places = await db.CommunityPlaces.AsNoTracking().CountAsync(p =>
            (p.Status == PlaceStatus.Hidden && (p.FlagCount > 0 || p.HeldForReview))
            || (p.FlagCount > 0 && (p.Status == PlaceStatus.Pending || p.Status == PlaceStatus.Published)), ct);
        var held = await db.CommunityPlaces.AsNoTracking().CountAsync(p => p.Status == PlaceStatus.Hidden && p.HeldForReview, ct);

        // Age: since a held place was added, or since the first flag on a visible flagged review or place.
        var oldestHeld = await db.CommunityPlaces.AsNoTracking().Where(p => p.Status == PlaceStatus.Hidden && p.HeldForReview)
            .OrderBy(p => p.CreatedAt).Select(p => (DateTimeOffset?)p.CreatedAt).FirstOrDefaultAsync(ct);
        var oldestReviewFlag = await db.ReviewFlags.AsNoTracking()
            .Where(f => db.Reviews.Any(r => r.Id == f.ReviewId && r.Status == ReviewStatus.Published && r.FlagCount > 0))
            .OrderBy(f => f.CreatedAt).Select(f => (DateTimeOffset?)f.CreatedAt).FirstOrDefaultAsync(ct);
        var oldestPlaceFlag = await db.PlaceFlags.AsNoTracking()
            .Where(f => db.CommunityPlaces.Any(p => p.Id == f.PlaceId && p.FlagCount > 0 && (p.Status == PlaceStatus.Pending || p.Status == PlaceStatus.Published)))
            .OrderBy(f => f.CreatedAt).Select(f => (DateTimeOffset?)f.CreatedAt).FirstOrDefaultAsync(ct);
        var oldest = new[] { oldestHeld, oldestReviewFlag, oldestPlaceFlag }.Where(t => t is not null).Min();

        return new DigestCounts(
            byCategory.Sum(c => c.Count), byCategory.ToDictionary(c => c.Key, c => c.Count),
            await untriaged.CountAsync(ct), now - oldestUntriaged,
            crashesNew, regressed, open,
            reviews + photos + places, held, now - oldest);
    }

    /// <summary>
    /// True when the daily digest is due: within the hour starting at <paramref name="sendAtHour"/> Malaysia time, and not yet sent
    /// that day. The one-hour window keeps a restarted worker from resending later in the day.
    /// </summary>
    public static bool DigestDue(DateTimeOffset now, int sendAtHour, DateOnly? lastSentDay)
    {
        var local = TimeZoneInfo.ConvertTime(now, ValhallaMapper.MalaysiaTime);
        return local.Hour == sendAtHour && lastSentDay != DateOnly.FromDateTime(local.DateTime);
    }

    public static DateOnly MalaysiaDay(DateTimeOffset now) => DateOnly.FromDateTime(TimeZoneInfo.ConvertTime(now, ValhallaMapper.MalaysiaTime).DateTime);

    /// <summary>True when a moderation item is close to the 24-hour promise and no alert went out in the last 12 hours.</summary>
    public static bool ModerationAlertDue(DigestCounts c, DateTimeOffset now, DateTimeOffset? lastAlert) =>
        c.ModerationWaiting > 0 && c.OldestModeration >= ModerationAlertAge && (lastAlert is null || now - lastAlert >= AlertCooldown);

    public sealed record Message(string Subject, string Text, string Html);

    public static Message Daily(DigestCounts c, DateTimeOffset now, string backOfficeUrl)
    {
        var day = TimeZoneInfo.ConvertTime(now, ValhallaMapper.MalaysiaTime).ToString("ddd d MMM", CultureInfo.InvariantCulture);
        var parts = new List<string>();
        if (c.FeedbackNew > 0) parts.Add($"{c.FeedbackNew} feedback");
        if (c.CrashGroupsRegressed > 0) parts.Add($"{c.CrashGroupsRegressed} crash regressed");
        else if (c.CrashGroupsNew > 0) parts.Add($"{c.CrashGroupsNew} new crash");
        if (c.ModerationWaiting > 0) parts.Add($"{c.ModerationWaiting} to moderate");
        var subject = $"Manotu {day}: {(parts.Count == 0 ? "all quiet" : string.Join(" · ", parts))}";

        var categories = string.Join(", ", c.FeedbackNewByCategory.Where(kv => kv.Value > 0).OrderByDescending(kv => kv.Value)
            .Select(kv => $"{kv.Value} {GimanoJson.ToWire(kv.Key)}"));
        var rows = new List<(string Label, string Value)>
        {
            ("New feedback (24 h)", c.FeedbackNew == 0 ? "0" : $"{c.FeedbackNew} ({categories})"),
            ("Feedback not yet triaged", $"{c.FeedbackUntriaged}{Age(c.OldestUntriaged)}"),
            ("New crash groups (24 h)", $"{c.CrashGroupsNew}"),
            ("Crash groups open / regressed", $"{c.CrashGroupsOpen} / {c.CrashGroupsRegressed}"),
            ("Moderation waiting", $"{c.ModerationWaiting}{Age(c.OldestModeration)}"),
            ("…of which places held for review", $"{c.PlacesHeld}"),
        };
        return Render(subject, rows, backOfficeUrl,
            c.ModerationWaiting > 0 ? "We promise to act on reported content within 24 hours." : null);
    }

    public static Message ModerationAlert(DigestCounts c, string backOfficeUrl)
    {
        var hours = (int)Math.Floor(c.OldestModeration!.Value.TotalHours);
        var subject = $"Manotu: a moderation item has waited {hours} h ({c.ModerationWaiting} waiting)";
        return Render(subject, [("Moderation waiting", $"{c.ModerationWaiting}{Age(c.OldestModeration)}"), ("…of which places held for review", $"{c.PlacesHeld}")],
            backOfficeUrl, "Our Terms, Apple 1.2 and the Play UGC policy promise action within 24 hours.");
    }

    private static string Age(TimeSpan? age) => age is not { } a ? ""
        : a.TotalHours < 1 ? ", oldest < 1 h"
        : a.TotalDays < 2 ? $", oldest {(int)a.TotalHours} h"
        : $", oldest {(int)a.TotalDays} days";

    private static Message Render(string subject, IReadOnlyList<(string Label, string Value)> rows, string url, string? note)
    {
        var text = new StringBuilder();
        foreach (var (l, v) in rows) text.Append(l).Append(": ").AppendLine(v);
        if (note is not null) text.AppendLine().AppendLine(note);
        text.AppendLine().Append("Back office: ").AppendLine(url);
        text.AppendLine().AppendLine("Counts only. Message text, contacts and locations stay in the back office.");

        var html = new StringBuilder("<div style=\"font-family:system-ui,sans-serif;color:#0B1B3A\"><table cellpadding=\"6\" style=\"border-collapse:collapse\">");
        foreach (var (l, v) in rows)
            html.Append("<tr><td style=\"color:#3A4A66\">").Append(WebUtility.HtmlEncode(l)).Append("</td><td><b>").Append(WebUtility.HtmlEncode(v)).Append("</b></td></tr>");
        html.Append("</table>");
        if (note is not null) html.Append("<p>").Append(WebUtility.HtmlEncode(note)).Append("</p>");
        html.Append("<p><a href=\"").Append(WebUtility.HtmlEncode(url)).Append("\">Open the back office</a></p>")
            .Append("<p style=\"color:#6B7A94;font-size:12px\">Counts only. Message text, contacts and locations stay in the back office.</p></div>");
        return new Message(subject, text.ToString(), html.ToString());
    }
}
