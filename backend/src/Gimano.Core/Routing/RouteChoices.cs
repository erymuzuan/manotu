using Gimano.Core.Contracts;
using Gimano.Core.Geo;

namespace Gimano.Core.Routing;

/// <summary>
/// Which alternatives are worth offering before a drive, and why (docs/api.md, "Route options"). Input is ranked
/// (fastest with traffic first); output keeps that order for the shown routes, then the hidden ones.
/// </summary>
public static class RouteChoices
{
    public const int MaxShown = 3;
    /// <summary>Trips at least this long (by road) open the preview with the route list and no countdown.</summary>
    public const double LongTripM = 10_000;
    public const double MaxSlowdown = 1.4;
    public const decimal TollSavingKeepsSlowRoute = 3m;
    public const double SameRoadShare = 0.8;
    public const double SameRoadWithinM = 30;
    public const double ClearlyWorseS = 300;
    public const double ClearlyWorseM = 2_000;
    public const decimal ClearlyWorseMyr = 1m;
    public const decimal LowerTollMinMyr = 1m;
    public const double ViaRoadMinM = 2_000;
    public const double ViaRoadOthersMaxM = 500;

    public static IReadOnlyList<RouteDto> Annotate(IReadOnlyList<RouteDto> ranked)
    {
        if (ranked.Count == 0) return ranked;
        var lines = ranked.Select(r => Polyline.Decode(r.Polyline)).ToList();
        var best = ranked[0];
        var shown = new List<(RouteDto Route, IReadOnlyList<GeoPoint> Line)> { (best, lines[0]) };
        var hidden = new List<RouteDto>();
        for (var i = 1; i < ranked.Count; i++)
        {
            var r = ranked[i];
            var why = HideReason(r, lines[i], best, shown);
            if (why is null && shown.Count >= MaxShown) why = RouteHidden.Slower;
            if (why is null) shown.Add((r, lines[i])); else hidden.Add(r with { Hidden = why, Reasons = [], ViaRoads = [] });
        }

        var kept = shown.Select(s => s.Route).ToList();
        var roads = kept.Select(RoadLengths).ToList();
        var result = new List<RouteDto>(ranked.Count);
        for (var i = 0; i < kept.Count; i++)
        {
            var via = ViaRoads(i, roads);
            result.Add(kept[i] with { Reasons = kept.Count > 1 ? ReasonsFor(kept[i], kept, via) : [], ViaRoads = via });
        }
        result.AddRange(hidden);
        return result;
    }

    /// <summary>Fewer than two routes worth showing on a long motor trip: worth asking Valhalla for more.</summary>
    public static bool WantsMore(IReadOnlyList<RouteDto> annotated) =>
        annotated.Count > 0 && annotated.Count(r => r.Hidden is null) < 2 && annotated[0].DistanceM >= LongTripM
        && ValhallaMapper.IsMotorised(annotated[0].Vehicle);

    internal static RouteHidden? HideReason(RouteDto r, IReadOnlyList<GeoPoint> line, RouteDto best,
        IReadOnlyList<(RouteDto Route, IReadOnlyList<GeoPoint> Line)> shown)
    {
        if (shown.Any(s => SharedShare(line, s.Line) > SameRoadShare)) return RouteHidden.SameRoad;
        var saving = Toll(best) is { } tb && Toll(r) is { } tr ? tb - tr : 0m;
        if (r.TrafficDurationS > best.TrafficDurationS * MaxSlowdown && saving < TollSavingKeepsSlowRoute) return RouteHidden.Slower;
        foreach (var (k, _) in shown)
            if (r.TrafficDurationS >= k.TrafficDurationS + ClearlyWorseS && r.DistanceM >= k.DistanceM + ClearlyWorseM
                && Toll(r) is { } mine && Toll(k) is { } theirs && mine >= theirs + ClearlyWorseMyr)
                return RouteHidden.Worse;
        return null;
    }

    internal static List<RouteReason> ReasonsFor(RouteDto r, IReadOnlyList<RouteDto> shown, IReadOnlyList<string> via)
    {
        var best = shown[0];
        var list = new List<RouteReason>();
        if (ReferenceEquals(r, best)) list.Add(RouteReason.Fastest);

        var byDistance = shown.OrderBy(s => s.DistanceM).ToList();
        if (ReferenceEquals(byDistance[0], r)
            && byDistance[1].DistanceM - r.DistanceM >= Math.Max(1_000, byDistance[1].DistanceM * 0.05))
            list.Add(RouteReason.Shortest);

        if (!ReferenceEquals(r, best))
        {
            if (!r.HasTolls && best.HasTolls) list.Add(RouteReason.NoTolls);
            else if (Toll(best) is { } tb && Toll(r) is { } tr && tb - tr >= LowerTollMinMyr) list.Add(RouteReason.LowerToll);
            if (best.Alerts.Count > 0 && r.Alerts.Count < best.Alerts.Count) list.Add(RouteReason.FewerReports);
            if (list.Count == 0 && via.Count > 0) list.Add(RouteReason.OtherMainRoad);
        }
        return list;
    }

    /// <summary>Known total toll in RM: 0 without tolls, null when a plaza on the route has no known fare.</summary>
    public static decimal? Toll(RouteDto r) => !r.HasTolls ? 0m : r.TollFareComplete ? r.TollEstimateMyr : null;

    /// <summary>Metres per main road (display ref, else street name) on the route.</summary>
    internal static Dictionary<string, double> RoadLengths(RouteDto r)
    {
        var d = new Dictionary<string, double>();
        foreach (var m in r.Legs.SelectMany(l => l.Maneuvers))
        {
            var key = m.RoadRef is { } rr ? ValhallaMapper.DisplayRef(rr) : m.StreetName;
            if (key is null || m.DistanceM <= 0) continue;
            d[key] = d.GetValueOrDefault(key) + m.DistanceM;
        }
        return d;
    }

    internal static List<string> ViaRoads(int index, IReadOnlyList<Dictionary<string, double>> roads)
    {
        if (roads.Count < 2) return [];
        return roads[index]
            .Where(kv => kv.Value >= ViaRoadMinM
                         && roads.Where((_, j) => j != index).All(o => o.GetValueOrDefault(kv.Key) < ViaRoadOthersMaxM))
            .OrderByDescending(kv => kv.Value).Take(2).Select(kv => kv.Key).ToList();
    }

    /// <summary>Share of <paramref name="a"/>'s length (sampled ≤ 300 times) within 30 m of <paramref name="b"/>.</summary>
    internal static double SharedShare(IReadOnlyList<GeoPoint> a, IReadOnlyList<GeoPoint> b)
    {
        if (a.Count < 2 || b.Count < 2) return 0;
        var length = GeoMath.LengthM(a);
        if (length <= 0) return 1;
        var step = Math.Max(50, length / 300);
        var box = BBox.Of(b).Expand(SameRoadWithinM);
        int near = 0, total = 0;
        for (var m = step / 2; m < length; m += step)
        {
            var p = Issues.IssueGeometry.PointAt(a, m);
            total++;
            if (box.Contains(p.Lat, p.Lng) && GeoMath.ProjectOnLine(b, p).DistanceM <= SameRoadWithinM) near++;
        }
        return total == 0 ? 0 : (double)near / total;
    }

    /// <summary>
    /// Two ~300 m boxes on the fastest route's main road, a third and two thirds along it: excluding them makes Valhalla
    /// look for a route that leaves that road (a near-copy is then hidden as <see cref="RouteHidden.SameRoad"/>).
    /// </summary>
    public static IReadOnlyList<IReadOnlyList<(double Lng, double Lat)>> MainRoadDetourRings(RouteDto best)
    {
        var line = Polyline.Decode(best.Polyline);
        var main = RoadLengths(best).OrderByDescending(kv => kv.Value).Select(kv => kv.Key).FirstOrDefault();
        if (main is null || line.Count < 2) return [];
        var ms = best.Legs.SelectMany(l => l.Maneuvers)
            .Where(m => (m.RoadRef is { } rr ? ValhallaMapper.DisplayRef(rr) : m.StreetName) == main && m.EndShapeIndex > m.BeginShapeIndex)
            .OrderByDescending(m => m.DistanceM).FirstOrDefault();
        if (ms is null) return [];
        var stretch = line.Skip(ms.BeginShapeIndex).Take(ms.EndShapeIndex - ms.BeginShapeIndex + 1).ToList();
        var len = GeoMath.LengthM(stretch);
        if (len < 1_000) return [];
        return new[] { len / 3, len * 2 / 3 }.Select(at => Square(Issues.IssueGeometry.PointAt(stretch, at), 150)).ToList();
    }

    private static IReadOnlyList<(double Lng, double Lat)> Square(GeoPoint c, double half)
    {
        var n = Issues.IssueGeometry.Offset(c, 0, half).Lat - c.Lat;
        var e = Issues.IssueGeometry.Offset(c, 90, half).Lng - c.Lng;
        var ring = new[] { (c.Lng - e, c.Lat - n), (c.Lng + e, c.Lat - n), (c.Lng + e, c.Lat + n), (c.Lng - e, c.Lat + n) };
        return ring.Append(ring[0]).Select(p => (Math.Round(p.Item1, 7), Math.Round(p.Item2, 7))).ToList();
    }
}
