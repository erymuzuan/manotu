using Gimano.Core.Community;
using Gimano.Core.Contracts;
using Gimano.Core.Data;
using Gimano.Core.Domain;
using Gimano.Core.Geo;
using Gimano.Core.Places;
using Gimano.Core.Routing;
using Gimano.Core.Search;
using Microsoft.EntityFrameworkCore;

namespace Gimano.Api.Services;

public sealed class PlaceService(GimanoDbContext db, PlaceSearchIndex index, TimeProvider clock, ILogger<PlaceService> logger, IssueDirectory issues, AuthorHandles handles)
{
    public async Task<IReadOnlyList<PlaceSummary>> SearchAsync(SearchQuery q, CancellationToken ct)
    {
        IReadOnlyList<PlaceHit> hits;
        try
        {
            hits = await index.SearchAsync(q, ct);
        }
        catch (Exception ex) when (ex is SearchUnavailableException or HttpRequestException)
        {
            logger.LogWarning("OpenSearch unavailable ({Message}); falling back to Postgres search", ex.Message);
            hits = await FallbackSearchAsync(q, ct);
        }
        var limit = Math.Clamp(q.Limit, 1, SearchQueryBuilder.MaxLimit);
        return SearchResults.Dedupe(hits, h => h.Name, h => (h.Lat, h.Lng), limit)
            .Select(h => new PlaceSummary(h.Id, h.Name, h.Category, h.Address, h.Lat, h.Lng, Distance(q.Lat, q.Lng, h.Lat, h.Lng), h.Brand,
                h.Source, PublicStatus(h.Status), h.Rating, h.ReviewCount, MediaKeys.Url(h.ThumbKey))).ToList();
    }

    /// <summary>Only pending/published are part of the public contract.</summary>
    private static PlaceStatus? PublicStatus(PlaceStatus? s) => s is PlaceStatus.Pending or PlaceStatus.Published ? s : null;

    private async Task<IReadOnlyList<PlaceHit>> FallbackSearchAsync(SearchQuery q, CancellationToken ct)
    {
        var pattern = "%" + q.Q.Trim().Replace("%", "").Replace("_", "") + "%";
        var limit = Math.Clamp(q.Limit, 1, SearchQueryBuilder.MaxLimit);
        var query = db.Places.AsNoTracking().Where(p => EF.Functions.ILike(p.Name, pattern) || (p.Brand != null && EF.Functions.ILike(p.Brand, pattern)));
        if (q.Category is { } cat) query = query.Where(p => p.Category == cat);
        if (q.Country is { } c) query = query.Where(p => p.Country == c);

        var community = db.CommunityPlaces.AsNoTracking().Where(p => EF.Functions.ILike(p.Name, pattern)
            && (p.Status == PlaceStatus.Published || (p.Status == PlaceStatus.Pending && q.Viewer != null && p.OwnerId == q.Viewer)));
        if (q.Category is { } cat2) community = community.Where(p => p.Category == cat2);

        if (q.Lat is { } lat && q.Lng is { } lng)
        {
            var pt = new GeoPoint(lat, lng).ToPoint();
            query = query.OrderBy(p => p.Location.Distance(pt));
            community = community.OrderBy(p => p.Location.Distance(pt));
        }
        else query = query.OrderByDescending(p => p.Popularity);
        var rows = await query.Take(limit).ToListAsync(ct);
        var crow = await community.Take(limit).ToListAsync(ct);
        return crow.Select(p => new PlaceHit(p.Id, p.Name, p.Category, p.Address, p.Location.Y, p.Location.X, null, 0, PlaceSource.Community, p.Status))
            .Concat(rows.Select(p => new PlaceHit(p.Id, p.Name, p.Category, p.Address, p.Location.Y, p.Location.X, p.Brand, 0)))
            .Take(limit).ToList();
    }

    /// <summary>Complaints on places: confirmed permanently closed → hidden; others → a badge (docs/api.md "Issues").</summary>
    public async Task<List<PlaceSummary>> ApplyIssuesAsync(IEnumerable<PlaceSummary> results, string lang, CancellationToken ct)
    {
        var s = await issues.GetAsync(ct);
        return ApplyIssues(results, s, lang, TimeZoneInfo.ConvertTime(clock.GetUtcNow(), ValhallaMapper.MalaysiaTime).DateTime);
    }

    /// <summary>
    /// Hides confirmed-closed places, adds badges, and makes <c>openNow</c> agree with the place card: false while closed,
    /// and computed from confirmed corrected opening hours when there are some (as <see cref="GetAsync"/> does).
    /// </summary>
    internal static List<PlaceSummary> ApplyIssues(IEnumerable<PlaceSummary> results, IssueDirectory.Snapshot s, string lang, DateTime localNow)
    {
        if (s.PlaceBadges.Count == 0) return results.ToList();
        return results.Where(r => !s.ClosedPlaces.Contains(r.Id))
            .Select(r => IssueDirectory.Badge(s, r.Id, lang) is { } b
                ? r with
                {
                    Badge = b,
                    OpenNow = s.IsClosedNow(r.Id) ? false : s.Hours.TryGetValue(r.Id, out var hours) ? OpeningHours.IsOpen(hours, localNow) : r.OpenNow,
                }
                : r).ToList();
    }

    public async Task<IReadOnlyList<PlaceSummary>> NearbyAsync(GeoPoint at, PlaceCategory? category, double radiusM, int limit, Guid? viewer, CancellationToken ct, string lang = "en")
    {
        var pt = at.ToPoint();
        var query = db.Places.AsNoTracking().Where(p => p.Location.IsWithinDistance(pt, radiusM));
        if (category is { } c) query = query.Where(p => p.Category == c);
        var rows = await query.OrderBy(p => p.Location.Distance(pt)).Take(limit).ToListAsync(ct);

        // Pending places are shown nearby so that people there can verify them ("Is this place here?").
        var cq = db.CommunityPlaces.AsNoTracking().Where(p => p.Location.IsWithinDistance(pt, radiusM)
            && (p.Status == PlaceStatus.Published || p.Status == PlaceStatus.Pending));
        if (category is { } c2) cq = cq.Where(p => p.Category == c2);
        var crow = await cq.OrderBy(p => p.Location.Distance(pt)).Take(limit).ToListAsync(ct);

        var ids = rows.Select(r => r.Id).Concat(crow.Select(r => r.Id)).ToList();
        var agg = await PlaceDocuments.AggregatesAsync(db, ids, ct);
        var local = TimeZoneInfo.ConvertTime(clock.GetUtcNow(), ValhallaMapper.MalaysiaTime).DateTime;
        return rows.Select(p => ToSummary(p, at.Lat, at.Lng, agg.GetValueOrDefault(p.Id)) with { OpenNow = OpeningHours.IsOpen(p.OpeningHours, local) })
            .Concat(crow.Select(p => ToSummary(p, at.Lat, at.Lng, agg.GetValueOrDefault(p.Id)) with { OpenNow = OpeningHours.IsOpen(p.OpeningHours, local) }))
            .OrderBy(s => s.DistanceM).Take(limit)
            .ToList() is var list ? await ApplyIssuesAsync(list, lang, ct) : [];
    }

    public async Task<PlaceDto?> GetAsync(string id, double? lat, double? lng, Guid? viewer, CancellationToken ct, string lang = "en")
    {
        var dto = await GetRawAsync(id, lat, lng, viewer, ct);
        if (dto is null) return null;
        var s = await issues.GetAsync(ct);
        var local = TimeZoneInfo.ConvertTime(clock.GetUtcNow(), ValhallaMapper.MalaysiaTime).DateTime;
        NavigationPoint? nav = s.NavPoints.TryGetValue(id, out var ni)
            && double.TryParse(ni.Payload.GetValueOrDefault("navLat"), System.Globalization.NumberStyles.Float, System.Globalization.CultureInfo.InvariantCulture, out var nla)
            && double.TryParse(ni.Payload.GetValueOrDefault("navLng"), System.Globalization.NumberStyles.Float, System.Globalization.CultureInfo.InvariantCulture, out var nlo)
            ? new NavigationPoint(nla, nlo, ni.Id)
            : await db.PlaceEntrances.AsNoTracking().FirstOrDefaultAsync(e => e.PlaceId == id, ct) is { } en
                ? new NavigationPoint(en.Location.Y, en.Location.X, null, en.Source, en.Kind) : null;
        // Confirmed corrected opening hours replace the OSM ones until the map catches up.
        var hours = s.Hours.TryGetValue(id, out var h) ? h : dto.OpeningHours;
        return dto with
        {
            Badge = IssueDirectory.Badge(s, id, lang), NavigationPoint = nav,
            OpeningHours = hours,
            // Temporarily (or confirmed permanently) closed: not open now, whatever the hours say.
            OpenNow = s.IsClosedNow(id) ? false : hours == dto.OpeningHours ? dto.OpenNow : OpeningHours.IsOpen(hours, local),
        };
    }

    private async Task<PlaceDto?> GetRawAsync(string id, double? lat, double? lng, Guid? viewer, CancellationToken ct)
    {
        var local = TimeZoneInfo.ConvertTime(clock.GetUtcNow(), ValhallaMapper.MalaysiaTime).DateTime;
        var agg = (await PlaceDocuments.AggregatesAsync(db, [id], ct)).GetValueOrDefault(id);
        var photos = await RecentPhotosAsync(id, ct);

        if (CommunityPlace.IsCommunityId(id))
        {
            var c = await db.CommunityPlaces.AsNoTracking().Include(x => x.Owner).FirstOrDefaultAsync(x => x.Id == id, ct);
            if (c is null || !CommunityRules.IsVisibleTo(c.Status, c.OwnerId, viewer)) return null;
            return ToDto(c, lat, lng, agg, photos, local, handles.For(c.OwnerId));
        }

        var p = await db.Places.AsNoTracking().FirstOrDefaultAsync(x => x.Id == id, ct);
        if (p is null) return null;
        return new PlaceDto(p.Id, p.Name, p.Category, p.Address, p.Location.Y, p.Location.X, Distance(lat, lng, p.Location.Y, p.Location.X), p.Brand,
            p.Phone, p.Website, p.OpeningHours, OpeningHours.IsOpen(p.OpeningHours, local), p.Amenities, p.Tags, p.OsmType, p.OsmId,
            PlaceSource.Osm, null, agg?.Rating, agg?.ReviewCount ?? 0, MediaKeys.Url(agg?.ThumbKey), null, null, 0, photos);
    }

    internal static PlaceDto ToDto(CommunityPlace c, double? lat, double? lng, PlaceAggregates? agg, IReadOnlyList<PhotoDto> photos, DateTime local, string? ownerHandle = null) =>
        new(c.Id, c.Name, c.Category, c.Address, c.Location.Y, c.Location.X, Distance(lat, lng, c.Location.Y, c.Location.X), null,
            c.Phone, c.Website, c.OpeningHours, OpeningHours.IsOpen(c.OpeningHours, local), c.Amenities, new Dictionary<string, string>(), null, null,
            PlaceSource.Community, c.Status, agg?.Rating, agg?.ReviewCount ?? 0, MediaKeys.Url(agg?.ThumbKey),
            c.Description, c.Owner is null ? new AddedBy("Pemandu Manotu") : new AddedBy(c.Owner.DisplayName, ownerHandle), c.VerifiedCount, photos,
            HeldForReview: c.HeldForReview);

    public async Task<IReadOnlyList<PhotoDto>> RecentPhotosAsync(string placeId, CancellationToken ct, int take = 10)
    {
        var rows = await db.Photos.AsNoTracking().Include(p => p.User)
            .Where(p => p.PlaceId == placeId && p.Status == PhotoStatus.Published)
            .OrderByDescending(p => p.Id).Take(take).ToListAsync(ct);
        return rows.Select(p => PhotoService.ToDto(p, handles)).ToList();
    }

    public static PlaceSummary ToSummary(Place p, double? lat, double? lng, PlaceAggregates? agg = null) =>
        new(p.Id, p.Name, p.Category, p.Address, p.Location.Y, p.Location.X, Distance(lat, lng, p.Location.Y, p.Location.X), p.Brand,
            PlaceSource.Osm, null, agg?.Rating, agg?.ReviewCount ?? 0, MediaKeys.Url(agg?.ThumbKey));

    public static PlaceSummary ToSummary(CommunityPlace p, double? lat, double? lng, PlaceAggregates? agg = null) =>
        new(p.Id, p.Name, p.Category, p.Address, p.Location.Y, p.Location.X, Distance(lat, lng, p.Location.Y, p.Location.X), null,
            PlaceSource.Community, PublicStatus(p.Status), agg?.Rating, agg?.ReviewCount ?? 0, MediaKeys.Url(agg?.ThumbKey));

    private static double? Distance(double? lat, double? lng, double pLat, double pLng) =>
        lat is { } a && lng is { } b ? Math.Round(GeoMath.HaversineM(a, b, pLat, pLng)) : null;
}
