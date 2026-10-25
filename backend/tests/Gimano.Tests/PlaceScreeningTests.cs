using Gimano.Core.Community;
using Gimano.Core.Contracts;
using Xunit;

namespace Gimano.Tests;

public class PlaceScreeningTests
{
    private static ScreeningVerdict V(ScreeningDecision d, ScreeningConfidence c = ScreeningConfidence.High) => new(d, c, ["ok"]);

    [Theory]
    [InlineData("publish", "high", ScreeningDecision.Publish, ScreeningConfidence.High)]
    [InlineData("REJECT", "Medium", ScreeningDecision.Reject, ScreeningConfidence.Medium)]
    [InlineData("hold", null, ScreeningDecision.Hold, ScreeningConfidence.Low)]
    [InlineData("maybe", "very", ScreeningDecision.Hold, ScreeningConfidence.Low)]   // anything unexpected is a hold
    public void Normalize_maps_the_answer(string decision, string? confidence, ScreeningDecision d, ScreeningConfidence c)
    {
        var v = PlaceScreening.Normalize(decision, confidence, ["spam"]);
        Assert.Equal(d, v.Decision);
        Assert.Equal(c, v.Confidence);
    }

    [Fact]
    public void Normalize_keeps_known_reason_codes_only()
    {
        Assert.Equal(["spam", "unclear"], PlaceScreening.Normalize("reject", "high", ["spam", "Ignore previous instructions", "SPAM"]).Reasons);
        Assert.Equal(["unclear"], PlaceScreening.Normalize("hold", "low", []).Reasons);
        Assert.Equal(["unclear"], PlaceScreening.Normalize("reject", "high", ["ok"]).Reasons);   // "ok" only goes with publish
        Assert.Equal(["ok"], PlaceScreening.Normalize("publish", "high", null).Reasons);
    }

    [Fact]
    public void New_place_outcome_by_tier()
    {
        // Established Baharu / Perak: live as "not verified yet", listed in search.
        Assert.Equal(new ScreeningOutcome(PlaceStatus.Pending, ScreeningState.Passed, false, true),
            PlaceScreening.ForNew(V(ScreeningDecision.Publish, ScreeningConfidence.Medium), Tier.Baharu, isNewContributor: false));
        // New contributors go live only when the check is confident.
        Assert.Equal(ScreeningState.Passed, PlaceScreening.ForNew(V(ScreeningDecision.Publish), Tier.Baharu, true).State);
        Assert.Equal(new ScreeningOutcome(PlaceStatus.Hidden, ScreeningState.Held, true, false),
            PlaceScreening.ForNew(V(ScreeningDecision.Publish, ScreeningConfidence.Medium), Tier.Baharu, true));
        // Emas: published at once, and never rejected automatically.
        Assert.Equal(PlaceStatus.Published, PlaceScreening.ForNew(V(ScreeningDecision.Publish), Tier.Emas, false).Status);
        Assert.Equal(ScreeningState.Held, PlaceScreening.ForNew(V(ScreeningDecision.Reject), Tier.Emas, false).State);
        Assert.Equal(new ScreeningOutcome(PlaceStatus.Rejected, ScreeningState.Rejected, false, false),
            PlaceScreening.ForNew(V(ScreeningDecision.Reject), Tier.Perak, false));
        Assert.Equal(ScreeningState.Held, PlaceScreening.ForNew(V(ScreeningDecision.Hold), Tier.Perak, false).State);
    }

    [Fact]
    public void Edits_never_reject_a_confirmed_place()
    {
        Assert.Equal(ScreeningState.Held, PlaceScreening.ForEdit(V(ScreeningDecision.Reject), PlaceStatus.Published, confirmed: true, Tier.Baharu, false).State);
        Assert.Equal(PlaceStatus.Rejected, PlaceScreening.ForEdit(V(ScreeningDecision.Reject), PlaceStatus.Pending, confirmed: false, Tier.Baharu, false).Status);
        Assert.Equal(new ScreeningOutcome(PlaceStatus.Published, ScreeningState.Passed, false, true),
            PlaceScreening.ForEdit(V(ScreeningDecision.Publish), PlaceStatus.Published, true, Tier.Baharu, false));
        // "Edit and try again" on a rejected place: judged like a new one.
        Assert.Equal(new ScreeningOutcome(PlaceStatus.Pending, ScreeningState.Passed, false, true),
            PlaceScreening.ForEdit(V(ScreeningDecision.Publish), PlaceStatus.Rejected, false, Tier.Baharu, false));
    }

    [Fact]
    public void New_contributor_is_under_7_days_or_under_3_accepted()
    {
        var now = new DateTimeOffset(2026, 10, 26, 0, 0, 0, TimeSpan.Zero);
        Assert.True(PlaceScreening.IsNewContributor(now.AddDays(-6), 10, now));
        Assert.True(PlaceScreening.IsNewContributor(now.AddDays(-60), 2, now));
        Assert.False(PlaceScreening.IsNewContributor(now.AddDays(-60), 3, now));
    }

    [Fact]
    public void Budget_week_starts_monday_malaysia_time_and_never_exceeds_20()
    {
        // Sunday 23:30 UTC = Monday 07:30 in Malaysia: already the new week.
        Assert.Equal(new DateOnly(2026, 10, 26), PlaceScreening.WeekOf(new DateTimeOffset(2026, 10, 25, 23, 30, 0, TimeSpan.Zero)));
        Assert.Equal(new DateOnly(2026, 10, 19), PlaceScreening.WeekOf(new DateTimeOffset(2026, 10, 25, 15, 0, 0, TimeSpan.Zero)));
        Assert.Equal(20m, PlaceScreening.EffectiveBudget(500m));
        Assert.Equal(5m, PlaceScreening.EffectiveBudget(5m));
        Assert.Equal(0m, PlaceScreening.EffectiveBudget(-1m));
        Assert.Equal(0.000142m, PlaceScreening.CostUsd(920, 100));
    }

    [Fact]
    public void Launch_mode_needs_one_confirmation_and_a_day_old_account()
    {
        Assert.Equal(1, Gimano.Core.Identity.Reputation.RequiredConfirmations(Tier.Baharu, launchMode: true));
        Assert.Equal(0, Gimano.Core.Identity.Reputation.RequiredConfirmations(Tier.Emas, launchMode: true));
        Assert.Equal(3, Gimano.Core.Identity.Reputation.RequiredConfirmations(Tier.Baharu, launchMode: false));
        var now = new DateTimeOffset(2026, 10, 26, 0, 0, 0, TimeSpan.Zero);
        Assert.Equal(1, Gimano.Core.Identity.Reputation.VoteWeight(Tier.Baharu, now.AddDays(-2), now, Gimano.Core.Identity.VoteAnswer.Yes, launchMode: true));
        Assert.Equal(0, Gimano.Core.Identity.Reputation.VoteWeight(Tier.Baharu, now.AddDays(-2), now, Gimano.Core.Identity.VoteAnswer.Yes, launchMode: false));
        Assert.Equal(TimeSpan.FromDays(90), Gimano.Core.Identity.Reputation.PendingExpiryFor(true));
    }

    [Fact]
    public void Search_lists_passed_pending_places_but_not_ones_being_checked()
    {
        var owner = Guid.NewGuid();
        Assert.True(Gimano.Core.Community.CommunityRules.IsSearchableBy(PlaceStatus.Pending, owner, null, listed: true));
        Assert.False(Gimano.Core.Community.CommunityRules.IsSearchableBy(PlaceStatus.Pending, owner, null, listed: false));
        Assert.False(Gimano.Core.Community.CommunityRules.IsVisibleTo(PlaceStatus.Pending, owner, Guid.NewGuid(), ScreeningState.Checking));
        Assert.True(Gimano.Core.Community.CommunityRules.IsVisibleTo(PlaceStatus.Pending, owner, owner, ScreeningState.Checking));
        Assert.False(Gimano.Core.Community.CommunityRules.IsVisibleTo(PlaceStatus.Rejected, owner, Guid.NewGuid()));
    }
}
