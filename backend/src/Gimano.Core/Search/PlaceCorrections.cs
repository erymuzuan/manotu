using Gimano.Core.Contracts;
using Gimano.Core.Data;
using Gimano.Core.Domain;
using Gimano.Core.Geo;
using Microsoft.EntityFrameworkCore;

namespace Gimano.Core.Search;

/// <summary>Accepted suggestions are the durable overlay; imports rematerialize them after refreshing source facts.</summary>
public static class PlaceCorrections
{
    public static void Apply(Place place, SuggestEditRequest edit)
    {
        // JSON dictionaries use reference change tracking: replace before editing.
        place.Tags = new Dictionary<string, string>(place.Tags);
        if (edit.Name is { Length: > 0 } name && name != place.Name)
        {
            place.Tags["old_name"] = string.Join(";", (place.Tags.GetValueOrDefault("old_name") ?? "").Split(';', StringSplitOptions.RemoveEmptyEntries).Append(place.Name).Distinct(StringComparer.OrdinalIgnoreCase));
            place.Name = name;
        }
        if (edit.Category is { } category) place.Category = category;
        if (edit.Lat is { } lat && edit.Lng is { } lng)
        {
            place.Location = new GeoPoint(lat, lng).ToPoint();
            place.Country = Places.CountryResolver.Resolve(lat, lng);
            foreach (var key in place.Tags.Keys.Where(k => (k.StartsWith("manotu:locality", StringComparison.Ordinal) || k == "manotu:admin_names")).ToArray()) place.Tags.Remove(key);
        }
        if (edit.Address is { } address) place.Address = address;
        if (edit.Description is { } description) place.Tags["manotu:description"] = description;
        if (edit.Phone is { } phone) place.Phone = phone;
        if (edit.Website is { } website) place.Website = website;
        if (edit.OpeningHours is { } hours) place.OpeningHours = hours;
        if (edit.Closed is { } closed) place.Tags["manotu:closed"] = closed ? "yes" : "no";
        place.Tags["manotu:community_updated"] = "yes";
    }

    public static async Task ReplayAsync(GimanoDbContext db, CancellationToken ct)
    {
        var edits = await db.PlaceSuggestions.AsNoTracking().Where(s => s.Status == SuggestionStatus.Applied)
            .OrderBy(s => s.AppliedAt ?? s.CreatedAt).ThenBy(s => s.Id).ToListAsync(ct);
        foreach (var group in edits.Where(s => !CommunityPlace.IsCommunityId(s.PlaceId)).GroupBy(s => s.PlaceId))
        {
            var place = await db.Places.FirstOrDefaultAsync(p => p.Id == group.Key, ct);
            if (place is null) continue;
            foreach (var edit in group) Apply(place, edit.Changes);
        }
        await db.SaveChangesAsync(ct);
        db.ChangeTracker.Clear();
    }
}
