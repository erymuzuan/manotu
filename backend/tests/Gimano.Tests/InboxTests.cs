using Gimano.Core.Community;
using Gimano.Core.Contracts;

namespace Gimano.Tests;

public class InboxTests
{
    [Fact]
    public void Thanks_and_helpful_aggregate_per_Malaysia_day()
    {
        // 23:30 UTC on the 22nd is 07:30 MYT on the 23rd.
        var t = new DateTimeOffset(2026, 10, 22, 23, 30, 0, TimeSpan.Zero);
        Assert.Equal("report_thanked:2026-10-23", InboxRules.AggregateKey(InboxKind.ReportThanked, t));
        Assert.Equal("review_helpful:2026-10-23", InboxRules.AggregateKey(InboxKind.ReviewHelpful, t));
        Assert.Null(InboxRules.AggregateKey(InboxKind.PlacePublished, t));
        Assert.NotEqual(InboxRules.AggregateKey(InboxKind.ReportThanked, t), InboxRules.AggregateKey(InboxKind.ReportThanked, t.AddDays(1)));
    }

    [Fact]
    public void Texts_count_and_follow_locale()
    {
        Assert.Equal("24 drivers thanked you", InboxRules.Text(InboxKind.ReportThanked, 24, "en-MY").Title);
        Assert.Equal("A driver thanked you", InboxRules.Text(InboxKind.ReportThanked, 1, "en").Title);
        Assert.Equal("24 pemandu berterima kasih kepada anda", InboxRules.Text(InboxKind.ReportThanked, 24, "ms-MY").Title);
        Assert.Equal("Kedai Mak Teh is now verified", InboxRules.Text(InboxKind.PlacePublished, 1, "en", "Kedai Mak Teh").Title);
        Assert.Contains("Kedai Mak Teh", InboxRules.Text(InboxKind.PlaceRejected, 1, "ms", "Kedai Mak Teh").Title);
        Assert.True(InboxRules.IsMalay(null)); // default language
    }

    private static InboxItemDto Item(int minutesAgo, InboxKind kind = InboxKind.ReportThanked) =>
        new(Guid.CreateVersion7(), kind, "t", "b", null, null, new DateTimeOffset(2026, 10, 23, 8, 0, 0, TimeSpan.Zero).AddMinutes(-minutesAgo), false);

    [Fact]
    public void Merges_items_and_announcements_newest_first_with_a_cursor()
    {
        var items = Enumerable.Range(0, 3).Select(i => Item(i * 10)).ToList();               // 0, 10, 20 min ago
        var anns = new[] { Item(5, InboxKind.Announcement), Item(25, InboxKind.Announcement) };
        var (page, next) = InboxRules.Merge(items, anns, pageSize: 3);
        Assert.Equal([InboxKind.ReportThanked, InboxKind.Announcement, InboxKind.ReportThanked], page.Select(p => p.Kind));
        Assert.NotNull(next);
        var c = InboxRules.DecodeCursor(next)!.Value;
        Assert.Equal(page[^1].CreatedAt, c.At);
        Assert.Equal(page[^1].Id, c.Id);

        var (all, none) = InboxRules.Merge(items, anns, pageSize: 10);
        Assert.Equal(5, all.Count);
        Assert.Null(none);
    }

    [Fact]
    public void Retention_is_90_days() => Assert.Equal(TimeSpan.FromDays(90), InboxRules.Retention);

    [Fact]
    public void Wire_kinds_match_the_contract() =>
        Assert.Equal(["place_published", "place_rejected", "report_thanked", "review_helpful", "edit_accepted", "feedback_status", "announcement", "place_expired", "issue_confirmed", "issue_refuted", "issue_resolved",
            "place_held", "place_not_accepted", "place_live"],
            Enum.GetValues<InboxKind>().Select(GimanoJson.ToWire));
}
