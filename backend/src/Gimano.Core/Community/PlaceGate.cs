using Gimano.Core.Contracts;
using Gimano.Core.Data;
using Gimano.Core.Domain;
using Gimano.Core.Identity;
using Gimano.Core.Messaging;
using Microsoft.EntityFrameworkCore;
using Microsoft.Extensions.Options;

namespace Gimano.Core.Community;

/// <summary>
/// Runs the AI check on a community place and applies the answer (PlaceScreening.ForNew / ForEdit): the API calls it while the
/// app waits (4 s), the worker for places still "checking". Saves and publishes the place's events.
/// </summary>
public sealed class PlaceGate(GimanoDbContext db, IPlaceScreener screener, IEventPublisher bus, TimeProvider clock, IOptions<VettingOptions> vetting,
    BrandWatchlistService? brands = null)
{
    public const double NearbyRadiusM = 150;
    public bool Enabled => screener.Enabled;
    public bool LaunchMode => vetting.Value.LaunchMode;

    /// <summary>Checks <paramref name="place"/> (its owner loaded). Returns false when there was no answer and it stays "checking".</summary>
    public async Task<bool> RunAsync(CommunityPlace place, bool isEdit, TimeSpan? wait, bool late, CancellationToken ct)
    {
        var matches = brands is null ? [] : (await brands.MatcherAsync(ct)).Match(place.Name, place.Description, place.Website);
        var input = await InputAsync(place, isEdit, ct) with { Brands = matches.Count == 0 ? null : matches };
        var holdByBrand = matches.Any(m => m.PlaceMode == BrandPlaceMode.Hold);
        ScreeningResult result;
        using (var cts = CancellationTokenSource.CreateLinkedTokenSource(ct))
        {
            if (wait is { } w) cts.CancelAfter(w);
            try { result = await screener.ScreenAsync(input, cts.Token); }
            catch (OperationCanceledException) when (!ct.IsCancellationRequested) { result = ScreeningResult.Failed; }
        }
        if (result.Verdict is not { } v)
        {
            if (!result.Unavailable) return false;
            // Off or over budget: the plain vetting rules (as before the check existed).
            if (holdByBrand) await FinishAsync(place, PlaceStatus.Hidden, ScreeningState.Held, held: true, listed: false, null, late, ct, WarningsFor(place, null, matches));
            else await FinishAsync(place, isEdit ? place.Status : PlainStatus(place), ScreeningState.Skipped, held: false, listed: false, null, late, ct, WarningsFor(place, null, matches));
            return true;
        }
        var owner = place.Owner;
        var tier = owner?.Tier ?? Tier.Baharu;
        var isNew = owner is null || PlaceScreening.IsNewContributor(owner.JoinedAt, owner.PlacesAccepted, clock.GetUtcNow());
        var outcome = isEdit ? PlaceScreening.ForEdit(v, place.Status, place.ResolvedAt is not null, tier, isNew) : PlaceScreening.ForNew(v, tier, isNew);
        // A watchlist brand set to "hold" (online gambling, loans, investment) never goes live on the model's say-so; rejections stand.
        if (holdByBrand && outcome.State != ScreeningState.Rejected && outcome.State != ScreeningState.Held)
            outcome = new ScreeningOutcome(PlaceStatus.Hidden, ScreeningState.Held, true, false);
        await FinishAsync(place, outcome.Status, outcome.State, outcome.HeldForReview, outcome.Listed, v, late, ct, WarningsFor(place, v, matches));
        return true;
    }

    /// <summary>Still no answer after an hour: a maintainer decides instead (design B6).</summary>
    public Task GiveUpAsync(CommunityPlace place, CancellationToken ct) =>
        FinishAsync(place, PlaceStatus.Hidden, ScreeningState.Held, held: true, listed: false, null, late: true, ct, WarningsFor(place, null, []));

    /// <summary>The owner's tags, the AI check's sensitive_* codes and the watchlist brands' groups (docs/content-safety.md "Place warnings").</summary>
    internal static IReadOnlyList<string>? WarningsFor(CommunityPlace place, ScreeningVerdict? v, IReadOnlyList<BrandMatch> matches) =>
        PlaceWarnings.Merge(PlaceWarnings.Split(place.OwnerWarnings), v is null ? null : PlaceWarnings.FromReasonCodes(v.Reasons), matches.Select(m => m.Warning));

    private PlaceStatus PlainStatus(CommunityPlace p) => p.Owner?.Tier == Tier.Emas ? PlaceStatus.Published : PlaceStatus.Pending;

    private async Task FinishAsync(CommunityPlace place, PlaceStatus status, ScreeningState state, bool held, bool listed, ScreeningVerdict? v,
        bool late, CancellationToken ct, IReadOnlyList<string>? warnings = null)
    {
        var now = clock.GetUtcNow();
        var before = place.Status;
        place.Warnings = PlaceWarnings.Join(warnings);
        var owner = place.Owner;
        place.Status = status;
        place.ScreeningState = state;
        place.HeldForReview = held || (place.HeldForReview && status == PlaceStatus.Hidden);
        place.Listed = listed && status == PlaceStatus.Pending;
        place.ScreeningReasons = v is null ? null : string.Join(',', v.Reasons);
        place.ScreeningConfidence = v?.Confidence;
        place.ScreenedAt = now;
        place.UpdatedAt = now;

        // Emas places publish at once; 10 % also go to a local audit (as before the check existed).
        if (status == PlaceStatus.Published && before != PlaceStatus.Published && place.ResolvedAt is null)
        {
            place.AuditOpen = Reputation.PickForAudit(Random.Shared.NextDouble);
            if (!place.AuditOpen) { place.ResolvedAt = now; if (owner is not null) owner.PlacesAccepted++; }
            if (owner is not null) owner.Points += CommunityRules.Points.PlacePublished;
        }
        // Three AI rejections in 24 hours pause adding for 24 hours (lifted by itself; design B5).
        if (state == ScreeningState.Rejected && owner is not null)
        {
            var since = now - PlaceScreening.RejectionWindow;
            var recent = await db.CommunityPlaces.CountAsync(p => p.OwnerId == owner.Id && p.Id != place.Id
                && p.ScreeningState == ScreeningState.Rejected && p.ScreenedAt > since, ct) + 1;
            if (recent >= PlaceScreening.RejectionsToPause && !(owner.SuspendedUntil > now + PlaceScreening.PauseFor))
                owner.SuspendedUntil = now + PlaceScreening.PauseFor;
        }
        await db.SaveChangesAsync(ct);
        await bus.PublishAsync(RoutingKeys.PlaceChanged, new PlaceChangedEvent(place.Id), ct);
        if (state is ScreeningState.Passed or ScreeningState.Held or ScreeningState.Rejected)
            await bus.PublishAsync(RoutingKeys.PlaceScreened, new PlaceScreenedEvent(place.Id, state, late), ct);
    }

    /// <summary>The public fields plus the names of public places within 150 m (OSM and community; never the place itself).</summary>
    private async Task<ScreeningInput> InputAsync(CommunityPlace p, bool isEdit, CancellationToken ct)
    {
        var pt = p.Location;
        var osm = await db.Places.AsNoTracking().Where(x => x.Location.IsWithinDistance(pt, NearbyRadiusM))
            .OrderBy(x => x.Location.Distance(pt)).Select(x => x.Name).Take(10).ToListAsync(ct);
        var community = await db.CommunityPlaces.AsNoTracking()
            .Where(x => x.Id != p.Id && (x.Status == PlaceStatus.Pending || x.Status == PlaceStatus.Published) && x.Location.IsWithinDistance(pt, NearbyRadiusM))
            .OrderBy(x => x.Location.Distance(pt)).Select(x => x.Name).Take(10).ToListAsync(ct);
        string? differentFrom = null;
        if (p.SaidDifferentFrom is { } id)
            differentFrom = CommunityPlace.IsCommunityId(id)
                ? await db.CommunityPlaces.AsNoTracking().Where(x => x.Id == id).Select(x => x.Name).FirstOrDefaultAsync(ct)
                : await db.Places.AsNoTracking().Where(x => x.Id == id).Select(x => x.Name).FirstOrDefaultAsync(ct);
        return new ScreeningInput(p.Name, p.Category, p.Description, p.OpeningHours, p.Phone, p.Website,
            osm.Concat(community).Where(n => !string.IsNullOrWhiteSpace(n)).Distinct().Take(12).ToList(), differentFrom, isEdit);
    }
}
