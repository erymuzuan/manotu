using System.Globalization;
using System.Text.Json.Nodes;
using Gimano.Core.Contracts;
using Gimano.Core.Data;
using Gimano.Core.Domain;
using Gimano.Core.Geo;
using Gimano.Core.Routing;
using Gimano.Core.Tolls;
using Gimano.Core.Traffic;
using Microsoft.EntityFrameworkCore;
using Microsoft.Extensions.Caching.Memory;

namespace Gimano.Api.Services;

public sealed class RouteService(
    ValhallaClient valhalla, ReportService reports, GeoLookup geo, GimanoDbContext db,
    IMemoryCache cache, TimeProvider clock, IssueDirectory issues)
{
    private static readonly TimeSpan CacheFor = TimeSpan.FromHours(3);

    private static readonly TimeSpan TariffCacheFor = TimeSpan.FromMinutes(10);

    /// <param name="cacheAs">The request stored for reroute (the original request, so <c>nextStopIndex</c> always indexes its waypoints).</param>
    public async Task<IReadOnlyList<RouteDto>> RouteAsync(RouteRequest req, Guid? userId, CancellationToken ct, double? originHeading = null, RouteRequest? cacheAs = null,
        string lang = "en")
    {
        var vehicle = req.Vehicle ?? Vehicle.Car;
        var snapshot = await issues.GetAsync(ct);
        var placeIds = new[] { req.Destination }.Concat(req.Waypoints ?? []).Select(p => p.PlaceId).OfType<string>().Distinct().ToList();
        var entrances = placeIds.Count == 0 ? new Dictionary<string, PlaceEntrance>()
            : await db.PlaceEntrances.AsNoTracking().Where(e => placeIds.Contains(e.PlaceId)).ToDictionaryAsync(e => e.PlaceId, ct);
        var routed = WithNavigationPoints(req, snapshot, entrances);
        var arrival = ArrivalPoint(req.Destination, snapshot, entrances);
        var excluded = Exclusions(routed, vehicle, snapshot);
        var candidates = await CandidatesAsync(routed, originHeading, excluded, ct);
        if (candidates.Count == 0) throw new NoRouteException("No route found.");

        var bbox = candidates.Select(c => BBox.Of(c.Points)).Aggregate((a, b) =>
            new BBox(Math.Min(a.MinLng, b.MinLng), Math.Min(a.MinLat, b.MinLat), Math.Max(a.MaxLng, b.MaxLng), Math.Max(a.MaxLat, b.MaxLat)))
            .Expand(200);

        var activeReports = await reports.ActiveInBBoxAsync(bbox, ct);
        var motorised = ValhallaMapper.IsMotorised(vehicle);
        List<JamLine> jams = motorised
            ? (await geo.JamsInBBoxAsync(bbox, ct)).Select(j => new JamLine(j.Level, j.SpeedKmh, GeoMath.FromLineString(j.Geom))).ToList()
            : [];

        IReadOnlyList<TollPlaza> plazas = [];
        IReadOnlyList<TollTariff> tariffs = [];
        if (motorised)
        {
            var bboxPoly = bbox.ToPolygon();
            plazas = (await db.Places.AsNoTracking()
                    .Where(p => p.Category == PlaceCategory.TollBooth && p.Location.Intersects(bboxPoly))
                    .Select(p => new { p.Id, p.Name, p.Location }).Take(5000).ToListAsync(ct))
                .Select(p => new TollPlaza(p.Id, p.Name, p.Location.Y, p.Location.X)).ToList();
            tariffs = plazas.Count > 0 ? await TariffsAsync(ct) : [];
        }

        var routes = RouteDecorator.Decorate(candidates, activeReports, jams, NewRouteId(req.Stored), vehicle, plazas, tariffs)
            .Select(r => r with { Issues = IssuesFor(r, excluded, snapshot, req.IgnoreIssues, lang), Arrival = arrival }).ToList();
        Remember(routes, cacheAs ?? req);

        // Privacy rule: destinations/recents are never recorded server-side (they live on the device). userId is not
        // used for anything persistent here; "store": false routes are not even kept in the in-memory reroute cache.
        return routes;
    }

    /// <summary>Stateless (<c>"store": false</c>) route ids start with <c>x-</c>: reroute answers 404 without a cache lookup.</summary>
    internal const string StatelessIdPrefix = "x-";

    internal static Func<string> NewRouteId(bool store) => store
        ? () => Guid.CreateVersion7().ToString("N")
        : () => StatelessIdPrefix + Guid.CreateVersion7().ToString("N");

    /// <summary>Keeps the request for reroute (3 h, in memory) — never for <c>"store": false</c>.</summary>
    internal void Remember(IEnumerable<RouteDto> routes, RouteRequest request)
    {
        if (!request.Stored) return;
        foreach (var r in routes) cache.Set(CacheKey(r.Id), request, CacheFor);
    }

    /// <summary>
    /// One Valhalla call (with alternates) normally; more than <see cref="ValhallaMapper.MaxLocationsPerRequest"/> stops
    /// are routed in consecutive chunks, joined into a single route (no alternates for multi-stop routes anyway).
    /// </summary>
    private async Task<IReadOnlyList<RouteCandidate>> CandidatesAsync(RouteRequest routed, double? originHeading,
        IReadOnlyList<IssueDirectory.RoadIssue> excluded, CancellationToken ct)
    {
        // A JsonNode can have one parent only: build the exclusion polygons per Valhalla request.
        JsonArray Exclude() => Gimano.Core.Issues.IssueGeometry.ToValhalla(excluded.Select(e => e.Ring));
        static List<LatLng> StopsOf(RouteRequest r) => (r.Waypoints ?? []).Append(r.Destination).ToList();

        var chunks = ValhallaMapper.SplitStops(routed);
        if (chunks.Count == 1)
        {
            var response = await valhalla.RouteAsync(ValhallaMapper.BuildRouteRequest(routed, originHeading, excludePolygons: Exclude()), ct);
            return ValhallaMapper.MapResponse(response, StopsOf(routed));
        }

        var parts = new List<RouteCandidate>();
        var departAt = routed.DepartAt;
        for (var i = 0; i < chunks.Count; i++)
        {
            var chunk = chunks[i] with { DepartAt = departAt };
            var response = await valhalla.RouteAsync(
                ValhallaMapper.BuildRouteRequest(chunk, i == 0 ? originHeading : null, excludePolygons: Exclude()), ct);
            var part = ValhallaMapper.MapResponse(response, StopsOf(chunk)).FirstOrDefault()
                ?? throw new NoRouteException("No route found.");
            parts.Add(part);
            departAt = departAt?.AddSeconds(part.DurationS);
        }
        return [ValhallaMapper.Join(parts)];
    }

    /// <summary>
    /// A place stop is routed to its navigation point (the display pin is unchanged): a confirmed entrance correction first,
    /// else the imported entrance (OSM entrance node, or the outline point nearest the road).
    /// </summary>
    internal static RouteRequest WithNavigationPoints(RouteRequest req, IssueDirectory.Snapshot s, IReadOnlyDictionary<string, PlaceEntrance>? entrances = null)
    {
        LatLng Nav(LatLng p) => NavigationPointFor(p, s, entrances) is { } n ? p with { Lat = n.Lat, Lng = n.Lng } : p;
        return req with { Destination = Nav(req.Destination), Waypoints = req.Waypoints?.Select(Nav).ToList() };
    }

    /// <summary>Where the route ends for a place destination; null when it ends at the given point.</summary>
    internal static NavigationPoint? ArrivalPoint(LatLng destination, IssueDirectory.Snapshot s, IReadOnlyDictionary<string, PlaceEntrance>? entrances) =>
        NavigationPointFor(destination, s, entrances);

    internal static NavigationPoint? NavigationPointFor(LatLng p, IssueDirectory.Snapshot s, IReadOnlyDictionary<string, PlaceEntrance>? entrances)
    {
        if (p.PlaceId is not { } id) return null;
        if (s.NavPoints.TryGetValue(id, out var i)
            && double.TryParse(i.Payload.GetValueOrDefault("navLat"), NumberStyles.Float, CultureInfo.InvariantCulture, out var la)
            && double.TryParse(i.Payload.GetValueOrDefault("navLng"), NumberStyles.Float, CultureInfo.InvariantCulture, out var lo))
            return new NavigationPoint(la, lo, i.Id);
        return entrances is not null && entrances.TryGetValue(id, out var e)
            ? new NavigationPoint(e.Location.Y, e.Location.X, null, e.Source, e.Kind) : null;
    }

    /// <summary>
    /// Confirmed closures / no-road (for this vehicle) around the trip, minus "Lalu juga" ones; nearest to the origin first,
    /// at most 60 (Valhalla's exclude-polygon perimeter limit).
    /// </summary>
    internal static List<IssueDirectory.RoadIssue> Exclusions(RouteRequest req, Vehicle vehicle, IssueDirectory.Snapshot s)
    {
        if (!ValhallaMapper.IsMotorised(vehicle) && vehicle != Vehicle.Bicycle) return [];
        var pts = new[] { req.Origin }.Concat(req.Waypoints ?? []).Append(req.Destination).ToList();
        var box = new BBox(pts.Min(p => p.Lng), pts.Min(p => p.Lat), pts.Max(p => p.Lng), pts.Max(p => p.Lat));
        var span = GeoMath.HaversineM(box.MinLat, box.MinLng, box.MaxLat, box.MaxLng);
        box = box.Expand(Math.Max(30_000, span * 0.3));
        var ignore = req.IgnoreIssues?.ToHashSet() ?? [];
        return s.Exclusions
            .Where(e => !ignore.Contains(e.Issue.Id) && e.Ring.Count > 0 && box.Contains(e.Mid.Lat, e.Mid.Lng)
                        && (e.Issue.Kind != IssueKind.RoadNotExist || e.Issue.Vehicle is null || e.Issue.Vehicle == vehicle))
            .OrderBy(e => GeoMath.HaversineM(req.Origin.Lat, req.Origin.Lng, e.Mid.Lat, e.Mid.Lng))
            .Take(Gimano.Core.Issues.IssueGeometry.MaxPolygons).ToList();
    }

    /// <summary>avoided: an applied exclusion within 1.5 km of the route; not avoided: any other open road issue on it (≤ 25 m).</summary>
    internal static List<RouteIssue> IssuesFor(RouteDto route, IReadOnlyList<IssueDirectory.RoadIssue> excluded, IssueDirectory.Snapshot s,
        IReadOnlyList<Guid>? ignored, string lang = "en")
    {
        var line = Polyline.Decode(route.Polyline);
        var result = new List<RouteIssue>();
        RouteIssue Dto(IssueDirectory.RoadIssue e, bool avoided, double? along) => new(
            e.Issue.Id, e.Issue.Kind, e.Issue.Subtype, e.Issue.State, avoided, Gimano.Core.Issues.IssueText.Summary(e.Issue, lang),
            e.Issue.StillVotes, e.Issue.LastEvidenceAt,
            e.Issue.WayId is { } w ? new IssueSegment(w, e.Issue.Seq ?? 0, e.Issue.RoadName, e.Issue.Highway, e.Issue.Direction) : null,
            e.Mid.Lat, e.Mid.Lng, along);
        foreach (var e in excluded)
            if (Gimano.Core.Issues.IssueGeometry.Near(line, e.Mid, Gimano.Core.Issues.IssueGeometry.AvoidedWithinM) is not null)
                result.Add(Dto(e, true, null));
        var ignoredSet = ignored?.ToHashSet() ?? [];
        foreach (var w in s.Warnings.Concat(s.Exclusions.Where(x => ignoredSet.Contains(x.Issue.Id))))
            if (Gimano.Core.Issues.IssueGeometry.Near(line, w.Mid, Gimano.Core.Issues.IssueGeometry.OnRouteWithinM) is { } hit)
                result.Add(Dto(w, false, Math.Round(hit.AlongM)));
        return result;
    }

    public async Task<IReadOnlyList<RouteDto>> RerouteAsync(string routeId, RerouteRequest r, Guid? userId, CancellationToken ct, string lang = "en")
    {
        if (routeId.StartsWith(StatelessIdPrefix, StringComparison.Ordinal)
            || !cache.TryGetValue(CacheKey(routeId), out RouteRequest? original) || original is null)
            throw new NotFoundException($"Route {routeId} is unknown or expired; request a new route.");
        var req = original with { Origin = new LatLng(r.Lat, r.Lng), Waypoints = RemainingStops(original.Waypoints, r.NextStopIndex), DepartAt = null };
        return await RouteAsync(req, userId, ct, r.Heading, cacheAs: original, lang: lang);
    }

    /// <summary>Stops not yet reached: <c>waypoints[nextStopIndex..]</c> (out-of-range → none left, negative → all).</summary>
    public static IReadOnlyList<LatLng> RemainingStops(IReadOnlyList<LatLng>? waypoints, int? nextStopIndex)
    {
        var all = waypoints ?? [];
        var from = Math.Clamp(nextStopIndex ?? 0, 0, all.Count);
        return all.Skip(from).ToList();
    }

    private async Task<IReadOnlyList<TollTariff>> TariffsAsync(CancellationToken ct) =>
        await cache.GetOrCreateAsync("toll-tariffs", async e =>
        {
            var rows = await db.TollRates.AsNoTracking().Where(t => t.MatchedPlaceIds.Count > 0).ToListAsync(ct);
            // An empty table (e.g. importer still running) is re-checked soon instead of cached for 10 minutes.
            e.AbsoluteExpirationRelativeToNow = rows.Count > 0 ? TariffCacheFor : TimeSpan.FromSeconds(30);
            return (IReadOnlyList<TollTariff>)rows.Select(TollRateCsv.ToTariff).ToList();
        }) ?? [];

    /// <summary>"Find the best time to leave": one Valhalla query per hour 06:00–22:00 local time.</summary>
    public async Task<IReadOnlyList<DepartureSlot>> DepartureTimesAsync(GeoPoint origin, GeoPoint dest, DateOnly? date, Vehicle vehicle, CancellationToken ct)
    {
        var today = DateOnly.FromDateTime(TimeZoneInfo.ConvertTime(clock.GetUtcNow(), ValhallaMapper.MalaysiaTime).DateTime);
        var day = date ?? today;
        var slots = Enumerable.Range(6, 17)
            .Select(h => new DateTimeOffset(day.ToDateTime(new TimeOnly(h, 0)), TimeSpan.FromHours(8)))
            .ToList();

        using var gate = new SemaphoreSlim(4);
        var tasks = slots.Select(async t =>
        {
            await gate.WaitAsync(ct);
            try
            {
                var req = new RouteRequest(new LatLng(origin.Lat, origin.Lng), new LatLng(dest.Lat, dest.Lng), [], vehicle, null, t, 0);
                var resp = await valhalla.RouteAsync(ValhallaMapper.BuildRouteRequest(req), ct);
                var c = ValhallaMapper.MapResponse(resp).FirstOrDefault();
                return c is null ? null : new DepartureSlot(t.ToUniversalTime(), c.DurationS);
            }
            finally { gate.Release(); }
        });
        return (await Task.WhenAll(tasks)).Where(s => s is not null).Cast<DepartureSlot>().ToList();
    }

    private static string CacheKey(string id) => "route:" + id;

    public static bool TryParseDate(string? s, out DateOnly? date)
    {
        date = null;
        if (string.IsNullOrWhiteSpace(s)) return true;
        if (DateOnly.TryParseExact(s, "yyyy-MM-dd", CultureInfo.InvariantCulture, DateTimeStyles.None, out var d)) { date = d; return true; }
        if (DateTimeOffset.TryParse(s, CultureInfo.InvariantCulture, DateTimeStyles.AssumeUniversal, out var dto))
        {
            date = DateOnly.FromDateTime(TimeZoneInfo.ConvertTime(dto, ValhallaMapper.MalaysiaTime).DateTime);
            return true;
        }
        return false;
    }
}
