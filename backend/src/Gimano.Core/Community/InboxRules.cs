using Gimano.Core.Contracts;
using Gimano.Core.Routing;

namespace Gimano.Core.Community;

/// <summary>Inbox texts (BM/EN by the user's locale), daily aggregation keys, retention and timeline paging.</summary>
public static class InboxRules
{
    public static readonly TimeSpan Retention = TimeSpan.FromDays(90);

    /// <summary>
    /// Announcements a user can see: within retention and not expired. Used for both the page and the unread count, so an
    /// expired announcement can't leave an unread badge with nothing behind it.
    /// </summary>
    public static System.Linq.Expressions.Expression<Func<Domain.Announcement, bool>> VisibleAnnouncement(DateTimeOffset now)
    {
        var since = now - Retention;
        return a => a.CreatedAt > since && (a.ExpiresAt == null || a.ExpiresAt > now);
    }
    public const int PageSize = 30;

    public static bool IsMalay(string? locale) => locale is null || locale.StartsWith("ms", StringComparison.OrdinalIgnoreCase);

    /// <summary>"report_thanked:2026-10-23" (Malaysia date) for kinds aggregated per day; null for one-off items.</summary>
    public static string? AggregateKey(InboxKind kind, DateTimeOffset at) => kind switch
    {
        InboxKind.ReportThanked or InboxKind.ReviewHelpful =>
            $"{GimanoJson.ToWire(kind)}:{TimeZoneInfo.ConvertTime(at, ValhallaMapper.MalaysiaTime):yyyy-MM-dd}",
        _ => null,
    };

    public static (string Title, string Body) Text(InboxKind kind, int count, string? locale, string? subject = null)
    {
        var ms = IsMalay(locale);
        var s = subject ?? "";
        return kind switch
        {
            InboxKind.ReportThanked => ms
                ? (count == 1 ? "Seorang pemandu berterima kasih kepada anda" : $"{count} pemandu berterima kasih kepada anda", "Laporan anda membantu pemandu lain hari ini.")
                : (count == 1 ? "A driver thanked you" : $"{count} drivers thanked you", "Your reports helped other drivers today."),
            InboxKind.ReviewHelpful => ms
                ? (count == 1 ? "Seseorang mendapati ulasan anda membantu" : $"{count} orang mendapati ulasan anda membantu", s)
                : (count == 1 ? "Someone found your review helpful" : $"{count} people found your review helpful", s),
            InboxKind.PlacePublished => ms
                ? ($"{s} kini disahkan", "Tempat yang anda tambah telah disahkan oleh pengguna lain dan kini boleh dicari.")
                : ($"{s} is now verified", "Other users confirmed the place you added; it now appears in search."),
            InboxKind.PlaceRejected => ms
                ? ($"{s} disembunyikan untuk semakan", "Beberapa pengguna melaporkan tempat ini tidak wujud atau di lokasi salah.")
                : ($"{s} is hidden for review", "Several users reported that this place doesn't exist or is in the wrong location."),
            InboxKind.PlaceExpired => ms
                ? ($"{s} tamat tempoh pengesahan", "Tiada cukup pengesahan dalam 30 hari. Anda boleh menambahnya semula.")
                : ($"{s} expired unverified", "Not enough people confirmed it within 30 days. You can add it again."),
            InboxKind.PlaceHeld => ms
                ? ($"{s}: seorang penyelenggara akan menyemak", "Biasanya dalam 24 jam. Hanya anda yang nampak tempat ini sehingga itu.")
                : ($"{s}: a maintainer will check it", "Usually within 24 hours. Until then only you can see it."),
            InboxKind.PlaceNotAccepted => ms
                ? ($"{s} tidak diterima", "Buka tempat ini untuk melihat sebabnya. Anda boleh menyuntingnya atau meminta semakan.")
                : ($"{s} was not accepted", "Open it to see why. You can edit it or ask for a review."),
            InboxKind.PlaceLive => ms
                ? ($"{s} kini di peta", "Belum disahkan: pemandu berdekatan akan diminta mengesahkannya.")
                : ($"{s} is now on the map", "Not verified yet: drivers nearby will be asked to confirm it."),
            InboxKind.ContentPublished => ms
                ? ($"Catatan anda di {s} kini disiarkan", "Ia lulus semakan dan semua orang boleh melihatnya.")
                : ($"Your post at {s} is now live", "It passed the check and everyone can see it."),
            InboxKind.ContentHeld => ms
                ? ($"Catatan anda di {s}: seorang penyelenggara akan menyemak", "Biasanya dalam 24 jam. Sehingga itu hanya anda yang nampak.")
                : ($"Your post at {s}: a maintainer will check it", "Usually within 24 hours. Until then only you can see it."),
            InboxKind.ContentRejected => ms
                ? ($"Catatan anda di {s} tidak diterima", "Buka untuk melihat sebabnya. Anda boleh meminta semakan sekali.")
                : ($"Your post at {s} was not accepted", "Open it to see why. You can ask for a review once."),
            InboxKind.EditAccepted => ms
                ? ("Cadangan suntingan anda diterima", s)
                : ("Your suggested edit was accepted", s),
            InboxKind.FeedbackStatus => ms
                ? ("Maklum balas anda telah dikemas kini", $"Status: {s}")
                : ("Your feedback was updated", $"Status: {s}"),
            InboxKind.IssueConfirmed => ms
                ? ($"Laporan anda disahkan: {s}", "Pemandu lain mengesahkannya. Laluan kini mengambil kira laporan ini.")
                : ($"Your report was confirmed: {s}", "Other drivers confirmed it. Routes now take it into account."),
            InboxKind.IssueRefuted => ms
                ? ($"Laporan anda tidak lagi aktif: {s}", "Pemandu lain atau aliran trafik menunjukkan ia sudah tiada. Terima kasih kerana melapor.")
                : ($"Your report is no longer active: {s}", "Other drivers or traffic flow show it has cleared. Thanks for reporting."),
            InboxKind.IssueResolved => ms
                ? ($"Peta telah dibetulkan: {s}", "Data peta kini sepadan dengan laporan anda. Terima kasih!")
                : ($"The map was fixed: {s}", "The map data now matches your report. Thank you!"),
            _ => (s, ""),
        };
    }

    public const string LegacyUpdateKey = "legacy-update";

    /// <summary>Kinds whose text needs the subject (place name/status); legacy rows without one keep their stored text.</summary>
    private static bool NeedsSubject(InboxKind k) => k is InboxKind.ReviewHelpful or InboxKind.PlacePublished or InboxKind.PlaceRejected
        or InboxKind.PlaceHeld or InboxKind.PlaceNotAccepted or InboxKind.PlaceLive
        or InboxKind.ContentPublished or InboxKind.ContentHeld or InboxKind.ContentRejected
        or InboxKind.PlaceExpired or InboxKind.EditAccepted or InboxKind.FeedbackStatus
        or InboxKind.IssueConfirmed or InboxKind.IssueRefuted or InboxKind.IssueResolved;

    /// <summary>Title/body in the reader's language ("en"/"ms", from Accept-Language), re-rendered from kind, count and subject.</summary>
    public static (string Title, string Body) Render(Domain.InboxItem i, string lang)
    {
        if (i.AggregateKey == LegacyUpdateKey) return LegacyUpdateText(lang);
        if (i.Kind == InboxKind.Announcement || (NeedsSubject(i.Kind) && i.Subject is null)) return (i.Title, i.Body);
        return Text(i.Kind, i.Count, lang, i.Subject);
    }

    /// <summary>Shown to key-less legacy accounts (0.1.0 apps can't sign requests).</summary>
    public static (string Title, string Body) LegacyUpdateText(string? locale) => IsMalay(locale)
        ? ("Kemas kini Manotu untuk melindungi akaun anda",
           "Versi baharu menandatangani sumbangan anda supaya tiada sesiapa boleh menyamar sebagai anda. Selepas kemas kini, tahap Perak dan Emas boleh dicapai.")
        : ("Update Manotu to protect your account",
           "The new version signs your contributions so nobody can impersonate you. After updating, the Perak and Emas tiers become available.");

    /// <summary>Merges the user's items and announcements, newest first, keyset-paged by (createdAt, id).</summary>
    public static (List<InboxItemDto> Page, string? Next) Merge(IEnumerable<InboxItemDto> items, IEnumerable<InboxItemDto> announcements, int pageSize = PageSize)
    {
        var all = items.Concat(announcements).OrderByDescending(i => i.CreatedAt).ThenByDescending(i => i.Id).ToList();
        var page = all.Take(pageSize).ToList();
        var next = all.Count > pageSize ? CommunityRules.EncodeCursor(page[^1].CreatedAt.UtcTicks, page[^1].Id) : null;
        return (page, next);
    }

    public static (DateTimeOffset At, Guid Id)? DecodeCursor(string? cursor) =>
        CommunityRules.DecodeCursor(cursor) is [var t, var id] && long.TryParse(t, out var ticks) && Guid.TryParse(id, out var g)
            ? (new DateTimeOffset(ticks, TimeSpan.Zero), g) : null;
}
