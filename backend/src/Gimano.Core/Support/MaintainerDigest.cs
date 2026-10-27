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
    public bool IsQuiet => FeedbackNew == 0 && FeedbackUntriaged == 0 && CrashGroupsNew == 0 && CrashGroupsRegressed == 0 && CrashGroupsOpen == 0 && ModerationWaiting == 0;
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
        // Appeals waiting for a decision and reports on map (OSM) places are in the queue too.
        var appeals = await db.ContentAppeals.AsNoTracking().CountAsync(a => a.Status == AppealStatus.Pending, ct);
        var osmFlagged = await db.OsmPlaceFlags.AsNoTracking().Select(f => f.PlaceId).Distinct().CountAsync(ct);
        var oldestAppeal = await db.ContentAppeals.AsNoTracking().Where(a => a.Status == AppealStatus.Pending)
            .OrderBy(a => a.CreatedAt).Select(a => (DateTimeOffset?)a.CreatedAt).FirstOrDefaultAsync(ct);
        var oldestOsmFlag = await db.OsmPlaceFlags.AsNoTracking().OrderBy(f => f.CreatedAt).Select(f => (DateTimeOffset?)f.CreatedAt).FirstOrDefaultAsync(ct);

        // Age: since a held place was added, or since the first flag on a visible flagged review or place.
        var oldestHeld = await db.CommunityPlaces.AsNoTracking().Where(p => p.Status == PlaceStatus.Hidden && p.HeldForReview)
            .OrderBy(p => p.CreatedAt).Select(p => (DateTimeOffset?)p.CreatedAt).FirstOrDefaultAsync(ct);
        var oldestReviewFlag = await db.ReviewFlags.AsNoTracking()
            .Where(f => db.Reviews.Any(r => r.Id == f.ReviewId && r.Status == ReviewStatus.Published && r.FlagCount > 0))
            .OrderBy(f => f.CreatedAt).Select(f => (DateTimeOffset?)f.CreatedAt).FirstOrDefaultAsync(ct);
        var oldestPlaceFlag = await db.PlaceFlags.AsNoTracking()
            .Where(f => db.CommunityPlaces.Any(p => p.Id == f.PlaceId && p.FlagCount > 0 && (p.Status == PlaceStatus.Pending || p.Status == PlaceStatus.Published)))
            .OrderBy(f => f.CreatedAt).Select(f => (DateTimeOffset?)f.CreatedAt).FirstOrDefaultAsync(ct);
        var oldest = new[] { oldestHeld, oldestReviewFlag, oldestPlaceFlag, oldestAppeal, oldestOsmFlag }.Where(t => t is not null).Min();

        return new DigestCounts(
            byCategory.Sum(c => c.Count), byCategory.ToDictionary(c => c.Key, c => c.Count),
            await untriaged.CountAsync(ct), now - oldestUntriaged,
            crashesNew, regressed, open,
            reviews + photos + places + appeals + osmFlagged, held, now - oldest);
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
        if (parts.Count == 0 && c.FeedbackUntriaged > 0) parts.Add($"{c.FeedbackUntriaged} feedback awaiting triage");
        if (parts.Count == 0 && c.CrashGroupsOpen > 0) parts.Add($"{c.CrashGroupsOpen} crash groups open");
        var subject = $"Manotu {day}: {(parts.Count == 0 ? "all quiet" : string.Join(" · ", parts))}";

        var categories = string.Join(", ", c.FeedbackNewByCategory.Where(kv => kv.Value > 0).OrderByDescending(kv => kv.Value)
            .Select(kv => $"{kv.Value} {GimanoJson.ToWire(kv.Key).Replace('_', ' ')}"));
        var rows = new List<(string Label, string Value)>
        {
            ("New feedback (24 h)", c.FeedbackNew == 0 ? "0" : $"{c.FeedbackNew} ({categories})"),
            ("Feedback not yet triaged", $"{c.FeedbackUntriaged}{Age(c.OldestUntriaged)}"),
            ("New crash groups (24 h)", $"{c.CrashGroupsNew}"),
            ("Open crash groups (includes regressions)", $"{c.CrashGroupsOpen}"),
            ("Regressed crash groups", $"{c.CrashGroupsRegressed}"),
            ("Moderation waiting", $"{c.ModerationWaiting}{Age(c.OldestModeration)}"),
            ("Places held for review (included above)", $"{c.PlacesHeld}"),
        };
        foreach (var category in Enum.GetValues<FeedbackCategory>())
            rows.Add(($"New {GimanoJson.ToWire(category).Replace('_', ' ')} feedback (24 h)", c.FeedbackNewByCategory.GetValueOrDefault(category).ToString(CultureInfo.InvariantCulture)));
        return Render(subject, rows, backOfficeUrl,
            c.ModerationWaiting > 0 ? "We promise to act on reported content within 24 hours." : null);
    }

    public static Message ModerationAlert(DigestCounts c, string backOfficeUrl)
    {
        var hours = (int)Math.Floor(c.OldestModeration!.Value.TotalHours);
        var subject = $"Manotu: a moderation item has waited {hours} h ({c.ModerationWaiting} waiting)";
        return Render(subject, [("Moderation waiting", $"{c.ModerationWaiting}{Age(c.OldestModeration)}"), ("Places held for review (included above)", $"{c.PlacesHeld}")],
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

        var html = new StringBuilder("""
            <!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"></head>
            <body style="margin:0;padding:0;background:#F5F8FD;color:#0B1B3A;font-family:Arial,Helvetica,sans-serif">
            <table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="background:#F5F8FD"><tr><td align="center" style="padding:24px 12px">
            <table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="max-width:640px;background:#FFFFFF;border:1px solid #DCE5F2;border-radius:16px;overflow:hidden">
            <tr><td style="padding:24px;background:#0047AB;color:#FFFFFF;font-size:28px;font-weight:bold">Manotu<span style="display:block;margin-top:8px;font-size:14px;font-weight:normal">Maintainer report</span></td></tr>
            <tr><td style="padding:24px">
            """);
        html.Append("<h1 style=\"margin:0 0 12px;font-size:22px;line-height:1.35\">").Append(WebUtility.HtmlEncode(subject)).Append("</h1>")
            .Append("<p style=\"margin:0 0 24px;color:#3A4A66;font-size:14px;line-height:1.6\">New activity covers the last 24 hours. Queue counts are current totals. Dates use Malaysia time (UTC+8).</p>")
            .Append("<table width=\"100%\" cellpadding=\"0\" cellspacing=\"0\" style=\"border-collapse:collapse;font-size:14px;line-height:1.5\"><caption style=\"text-align:left;font-size:18px;font-weight:bold;padding-bottom:12px\">Feedback, bugs &amp; moderation</caption>")
            .Append("<thead><tr style=\"background:#EAF1FC\"><th scope=\"col\" align=\"left\" style=\"padding:12px;border-bottom:2px solid #0047AB\">Metric</th><th scope=\"col\" align=\"right\" style=\"padding:12px;border-bottom:2px solid #0047AB\">Count / age</th></tr></thead><tbody>");
        for (var i = 0; i < rows.Count; i++)
        {
            var (label, value) = rows[i];
            html.Append("<tr style=\"background:").Append(i % 2 == 0 ? "#FFFFFF" : "#F5F8FD")
                .Append("\"><th scope=\"row\" align=\"left\" style=\"padding:12px;border-bottom:1px solid #DCE5F2;font-weight:normal;color:#3A4A66\">")
                .Append(WebUtility.HtmlEncode(label)).Append("</th><td align=\"right\" style=\"padding:12px;border-bottom:1px solid #DCE5F2;font-weight:bold\">")
                .Append(WebUtility.HtmlEncode(value)).Append("</td></tr>");
        }
        html.Append("</tbody></table>");
        if (note is not null) html.Append("<p style=\"padding:12px;background:#FFF4DF;color:#674400;font-size:14px;line-height:1.6\">").Append(WebUtility.HtmlEncode(note)).Append("</p>");
        html.Append("<table role=\"presentation\" cellpadding=\"0\" cellspacing=\"0\" style=\"margin-top:24px\"><tr><td bgcolor=\"#0047AB\" style=\"border-radius:8px;padding:14px 20px\"><a style=\"color:#FFFFFF;font-size:16px;font-weight:bold;text-decoration:none;display:inline-block\" href=\"")
            .Append(WebUtility.HtmlEncode(url)).Append("\">Open the back office</a></td></tr></table>")
            .Append("<p style=\"font-size:12px;line-height:1.6;word-break:break-word\"><a style=\"color:#0047AB\" href=\"").Append(WebUtility.HtmlEncode(url)).Append("\">").Append(WebUtility.HtmlEncode(url)).Append("</a></p>")
            .Append("</td></tr><tr><td style=\"padding:20px 24px;background:#EAF1FC;color:#3A4A66;font-size:12px;line-height:1.6\">Counts only. Message text, contacts and locations stay in the back office.</td></tr></table></td></tr></table></body></html>");
        return new Message(subject, text.ToString(), html.ToString());
    }
}
