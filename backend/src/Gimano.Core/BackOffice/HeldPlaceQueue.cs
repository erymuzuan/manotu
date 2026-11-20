using Gimano.Core.Community;
using Gimano.Core.Contracts;
using Gimano.Core.Data;
using Gimano.Core.Geo;
using Gimano.Core.Places;
using Microsoft.EntityFrameworkCore;

namespace Gimano.Core.BackOffice;

public sealed record HeldPlaceView(string Id, string Name, PlaceCategory Category, string Country, string? Locality,
    DateTimeOffset CreatedAt, IReadOnlyList<string> Reasons, string? Description, string? AppealNote,
    string? SimilarPlaceId, string? SimilarPlaceName);

/// <summary>Review data for signed-in maintainers. Contributor identities, contact fields and exact pins stay server-side.</summary>
public sealed class HeldPlaceQueue(GimanoDbContext db)
{
    public const int PageSize = 25;

    public async Task<(int Total, IReadOnlyList<HeldPlaceView> Items)> ListAsync(int offset, CancellationToken ct = default)
    {
        var held = db.CommunityPlaces.AsNoTracking().Where(p => p.Status == PlaceStatus.Hidden && p.HeldForReview);
        var total = await held.CountAsync(ct);
        var places = await held.OrderBy(p => p.CreatedAt).ThenBy(p => p.Id).Skip(offset).Take(PageSize)
            .Select(p => new
            {
                p.Id, p.Name, p.Category, p.Country, p.Location, p.CreatedAt, p.ScreeningReasons, p.Description, p.AppealNote,
                Locality = db.AdminAreas.Where(a => a.Geom.Intersects(p.Location))
                    .OrderByDescending(a => a.AdminLevel).ThenBy(a => a.Id).Select(a => a.Name).FirstOrDefault(),
                Blocked = db.RestrictedAreas.Any(a => a.Geom.IsWithinDistance(p.Location, RestrictedAreaRules.BlockM)),
                Near = db.RestrictedAreas.Any(a => a.Geom.IsWithinDistance(p.Location, RestrictedAreaRules.ReviewM)),
            }).ToListAsync(ct);
        var ids = places.Select(p => p.Id).ToArray();
        var flags = (await db.PlaceFlags.Where(f => ids.Contains(f.PlaceId))
            .Select(f => new { f.PlaceId, f.Reason }).Distinct().ToListAsync(ct)).ToLookup(f => f.PlaceId, f => f.Reason);
        var result = new List<HeldPlaceView>(places.Count);
        foreach (var p in places)
        {
            var reasons = ContentScreening.Split(p.ScreeningReasons).Concat(flags[p.Id].Select(GimanoJson.ToWire)).ToList();
            if (p.Blocked) reasons.Add("Inside restricted area or its buffer");
            else if (p.Near) reasons.Add("Near restricted area");
            var sensitive = RestrictedAreaRules.HasSensitiveTerm(p.Name, p.Description);
            if (sensitive) reasons.Add("Contains sensitive wording");

            CommunityRules.NearbyName? similar = null;
            if (!p.Blocked && !sensitive)
            {
                var map = await db.Places.Where(o => o.Location.IsWithinDistance(p.Location, CommunityRules.DuplicateRadiusM))
                    .Select(o => new { o.Id, o.Name, o.Location, o.Tags }).ToListAsync(ct);
                var community = db.CommunityPlaces.Where(c => c.Id != p.Id && !c.HeldForReview
                        && (c.Status == PlaceStatus.Published || (c.Status == PlaceStatus.Pending && c.Listed))
                        && c.Location.IsWithinDistance(p.Location, CommunityRules.DuplicateRadiusM))
                    .Select(c => new { c.Id, c.Name, c.Location });
                var candidates = map.Where(o => o.Tags.GetValueOrDefault("manotu:closed") != "yes")
                    .Select(o => new { o.Id, o.Name, o.Location }).Concat(await community.ToListAsync(ct))
                    .Select(c => new CommunityRules.NearbyName(c.Id, c.Name, c.Location.Y, c.Location.X));
                similar = CommunityRules.FindDuplicate(p.Name, new GeoPoint(p.Location.Y, p.Location.X), candidates);
            }

            result.Add(new HeldPlaceView(p.Id, p.Name, p.Category, p.Country, p.Locality, p.CreatedAt,
                reasons.Distinct().ToArray(), p.Description, p.AppealNote, similar?.Id, similar?.Name));
        }
        return (total, result);
    }
}
