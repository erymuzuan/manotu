using Gimano.Core.Contracts;
using Gimano.Core.Data;
using Gimano.Core.Domain;
using Gimano.Core.Geo;
using Gimano.Core.Messaging;
using Gimano.Core.Places;
using Gimano.Core.Search;
using Microsoft.EntityFrameworkCore;

namespace Gimano.Api.Services;

/// <summary>Maintainer acceptance is explicit. Suggestions alone never change published facts.</summary>
public sealed class PlaceCorrectionService(GimanoDbContext db, PlaceSearchIndex index, IEventPublisher bus, RestrictedAreaService restricted, TimeProvider clock, IssueDirectory issues, Npgsql.NpgsqlDataSource dataSource)
{
    public async Task<bool> AcceptAsync(Guid id, CancellationToken ct)
    {
        await using var rebuildLock = await SearchRebuildLock.AcquireAsync(dataSource, true, ct);
        var suggestion = await db.PlaceSuggestions.FirstOrDefaultAsync(s => s.Id == id, ct);
        if (suggestion is null) return false;
        if (suggestion.Status == SuggestionStatus.Rejected) throw new ValidationException("status", "Rejected suggestions cannot be applied.");
        if (suggestion.StreetOriginalName is not null)
        {
            suggestion.Status = SuggestionStatus.Applied;
            suggestion.AppliedAt ??= clock.GetUtcNow();
            await db.SaveChangesAsync(ct);
            var street = await PlaceDocuments.ForIdAsync(db, suggestion.PlaceId, ct);
            if (street is not null) await index.BulkIndexAsync([street], ct);
            await bus.PublishAsync(RoutingKeys.PlaceChanged, new PlaceChangedEvent(suggestion.PlaceId), ct);
            return true;
        }
        if (CommunityPlace.IsCommunityId(suggestion.PlaceId)) return await AcceptCommunityAsync(suggestion, ct);
        var place = await db.Places.FirstOrDefaultAsync(p => p.Id == suggestion.PlaceId, ct);
        if (place is null) return false;
        var edit = suggestion.Changes;
        if ((edit.Lat is null) != (edit.Lng is null)) throw new ValidationException("lat", "Both coordinates are required.");
        if (edit.Lat is { } lat && edit.Lng is { } lng)
        {
            if (!double.IsFinite(lat) || !double.IsFinite(lng) || !Core.Community.CommunityRules.InServiceArea(lat, lng)) throw new ValidationException("lat", "Location must be in MY, SG or BN.");
            await restricted.EnsureAllowedAsync(new GeoPoint(lat, lng), ct);
        }
        var tags = new Dictionary<string, string>(place.Tags) { ["name"] = edit.Name ?? place.Name };
        if (ImportEligibility.Exclusion(tags) is not null) throw new ValidationException("name", "Sensitive or personal residential records cannot be published.");
        if (suggestion.Status != SuggestionStatus.Applied)
        {
            PlaceCorrections.Apply(place, edit);
            suggestion.Status = SuggestionStatus.Applied;
            suggestion.AppliedAt = clock.GetUtcNow();
            await ResolveReopeningAsync(place.Id, edit, ct);
            await db.SaveChangesAsync(ct);
        }
        // Retry-safe: a failed index update can be retried after the accepted overlay was committed.
        var document = await PlaceDocuments.ForIdAsync(db, place.Id, ct);
        if (document is not null) await index.BulkIndexAsync([document], ct);
        await bus.PublishAsync(RoutingKeys.PlaceChanged, new PlaceChangedEvent(place.Id), ct);
        return true;
    }
    private async Task ResolveReopeningAsync(string placeId, SuggestEditRequest edit, CancellationToken ct)
    {
        if (edit.Closed != false) return;
        var closures = await db.Issues.Where(i => i.PlaceId == placeId && i.Kind == IssueKind.PlaceClosedPerm && i.State == IssueState.Confirmed).ToListAsync(ct);
        foreach (var closure in closures) closure.State = IssueState.Resolved;
        issues.Invalidate();
    }

    private async Task<bool> AcceptCommunityAsync(PlaceSuggestion suggestion, CancellationToken ct)
    {
        var place = await db.CommunityPlaces.FirstOrDefaultAsync(p => p.Id == suggestion.PlaceId, ct);
        if (place is null) return false;
        var edit = suggestion.Changes;
        if ((edit.Lat is null) != (edit.Lng is null)) throw new ValidationException("lat", "Both coordinates are required.");
        if (edit.Lat is { } lat && edit.Lng is { } lng)
        {
            if (!double.IsFinite(lat) || !double.IsFinite(lng) || !Core.Community.CommunityRules.InServiceArea(lat, lng)) throw new ValidationException("lat", "Location must be in MY, SG or BN.");
            await restricted.EnsureAllowedAsync(new GeoPoint(lat, lng), ct);
        }
        if (edit.Closed == false && (place.HeldForReview || place.ScreeningState is Core.Community.ScreeningState.Checking or Core.Community.ScreeningState.Held or Core.Community.ScreeningState.Rejected))
            throw new ValidationException("closed", "Complete the place's screening review before reopening it.");
        if (edit.Name is { } name) CommunityService.CheckName(name);
        if (suggestion.Status != SuggestionStatus.Applied)
        {
            if (edit.Name is { } n) place.Name = n;
            if (edit.Category is { } category) place.Category = category;
            if (edit.Lat is { } la && edit.Lng is { } lo) { place.Location = new GeoPoint(la, lo).ToPoint(); place.Country = CountryResolver.Resolve(la, lo); }
            if (edit.Address is { } address) place.Address = address;
            if (edit.Description is { } description) place.Description = description;
            if (edit.Phone is { } phone) place.Phone = phone;
            if (edit.Website is { } website) place.Website = website;
            if (edit.OpeningHours is { } hours) place.OpeningHours = hours;
            if (edit.Closed == true) place.Status = PlaceStatus.Closed;
            if (edit.Closed == false && place.Status == PlaceStatus.Closed) place.Status = PlaceStatus.Published;
            place.UpdatedAt = clock.GetUtcNow();
            suggestion.Status = SuggestionStatus.Applied;
            suggestion.AppliedAt = clock.GetUtcNow();
            await ResolveReopeningAsync(place.Id, edit, ct);
            await db.SaveChangesAsync(ct);
        }
        var document = await PlaceDocuments.ForIdAsync(db, place.Id, ct);
        if (document is not null) await index.BulkIndexAsync([document], ct);
        await bus.PublishAsync(RoutingKeys.PlaceChanged, new PlaceChangedEvent(place.Id), ct);
        return true;
    }

}
