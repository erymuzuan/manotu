using System.Text.Json;
using Gimano.Core.Contracts;
using Gimano.Core.Geo;
using Gimano.Core.Routing;

namespace Gimano.Tests;

public class RouteChoicesTests
{
    // Straight east-west lines at different latitudes near Shah Alam; ~0.009° lat ≈ 1 km apart.
    private static List<GeoPoint> Line(double lat, double fromLng = 101.50, double toLng = 101.70, int n = 50) =>
        Enumerable.Range(0, n).Select(i => new GeoPoint(lat, fromLng + (toLng - fromLng) * i / (n - 1))).ToList();

    private static RouteDto Route(string id, double minutes, double km, List<GeoPoint> line, decimal? toll = 0m, bool fareKnown = true,
        int alerts = 0, params (string Road, double Km)[] roads)
    {
        var maneuvers = roads.Select((r, i) => new ManeuverDto(ManeuverType.Straight, "", r.Road.StartsWith("Jalan") ? r.Road : null, null,
            r.Road.StartsWith("Jalan") ? null : r.Road, r.Km * 1000, 60, i, i + 1, null, null)).ToList();
        var alertList = Enumerable.Range(0, alerts).Select(i =>
            new AlertOnRoute(Guid.NewGuid(), ReportType.Hazard, null, line[1].Lat, line[1].Lng, null, null, new ReportedBy("x", "ok"),
                DateTimeOffset.UnixEpoch, DateTimeOffset.UnixEpoch, 0, 0, 100)).ToList();
        return new RouteDto(id, RouteLabel.Alternative, minutes * 60, km * 1000, minutes * 60, "", "Typical traffic", Vehicle.Car,
            HasTolls: toll is not 0m, TollEstimateMyr: toll, TollFareComplete: fareKnown, Tolls: [], Polyline: Polyline.Encode(line),
            Bbox: [], Legs: [new RouteLeg(minutes * 60, km * 1000, new LegEnd(0, 0, null), maneuvers)], TrafficSegments: [], Alerts: alertList);
    }

    [Fact]
    public void Shah_Alam_to_KLCC_keeps_three_routes_with_reasons()
    {
        // Our backend, 26 Oct: 43 min E5 RM 8.56 · 57 min FT2 RM 3.00 · 58 min NKVE RM 4.06.
        var e5 = Route("e5", 43, 41.3, Line(3.00), 8.56m, roads: [("E5", 30), ("Jalan Ampang", 5)]);
        var ft2 = Route("ft2", 57, 32.0, Line(3.02), 3.00m, roads: [("FT2", 25), ("Jalan Ampang", 5)]);
        var nkve = Route("nkve", 58, 56.3, Line(3.04), 4.06m, roads: [("E1", 40), ("Jalan Ampang", 5)]);

        var r = RouteChoices.Annotate([e5, ft2, nkve]);

        Assert.All(r, x => Assert.Null(x.Hidden));
        Assert.Equal([RouteReason.Fastest], r[0].Reasons);
        Assert.Equal([RouteReason.Shortest, RouteReason.LowerToll], r[1].Reasons);
        Assert.Equal([RouteReason.LowerToll], r[2].Reasons);
        Assert.Equal(["E5"], r[0].ViaRoads);
        Assert.Equal(["FT2"], r[1].ViaRoads);
        Assert.Equal(["E1"], r[2].ViaRoads);
    }

    [Fact]
    public void Almost_the_same_road_is_hidden_and_listed_last()
    {
        var a = Route("a", 29, 12.8, Line(2.20), roads: [("FT143", 10)]);
        var copy = Route("b", 30, 15.1, Line(2.2001), roads: [("FT143", 12)]);
        var other = Route("c", 34, 17.0, Line(2.23), roads: [("M107", 14)]);

        var r = RouteChoices.Annotate([a, copy, other]);

        Assert.Equal(["a", "c", "b"], r.Select(x => x.Id));
        Assert.Equal(RouteHidden.SameRoad, r[2].Hidden);
        Assert.Equal([RouteReason.OtherMainRoad], r[1].Reasons);
        Assert.Equal(["M107"], r[1].ViaRoads);
    }

    [Fact]
    public void Much_slower_route_is_hidden_unless_it_saves_toll()
    {
        var best = Route("best", 20, 15, Line(3.00), 5.00m);
        var slow = Route("slow", 30, 14, Line(3.03), 4.50m);
        var slowButCheap = Route("cheap", 30, 18, Line(3.06), 1.00m);

        var r = RouteChoices.Annotate([best, slow, slowButCheap]);

        Assert.Equal(RouteHidden.Slower, r.Single(x => x.Id == "slow").Hidden);
        Assert.Null(r.Single(x => x.Id == "cheap").Hidden);
        Assert.Contains(RouteReason.LowerToll, r.Single(x => x.Id == "cheap").Reasons!);
    }

    [Fact]
    public void Clearly_worse_needs_time_distance_and_toll_together()
    {
        var best = Route("best", 30, 20, Line(3.00), 2.00m);
        var worse = Route("worse", 36, 23, Line(3.03), 3.50m);
        var tollFree = Route("free", 36, 23, Line(3.06), 0m);

        var r = RouteChoices.Annotate([best, worse, tollFree]);

        Assert.Equal(RouteHidden.Worse, r.Single(x => x.Id == "worse").Hidden);
        Assert.Null(r.Single(x => x.Id == "free").Hidden);
        Assert.Equal([RouteReason.NoTolls], r.Single(x => x.Id == "free").Reasons);
    }

    [Fact]
    public void Unknown_fares_never_count_as_cheaper_or_worse()
    {
        var best = Route("best", 30, 20, Line(3.00), 6.00m);
        var unknown = Route("u", 36, 23, Line(3.03), 1.00m, fareKnown: false, roads: [("E9", 15)]);

        var r = RouteChoices.Annotate([best, unknown]);

        Assert.Null(r[1].Hidden);
        Assert.DoesNotContain(RouteReason.LowerToll, r[1].Reasons!);
        Assert.Equal([RouteReason.OtherMainRoad], r[1].Reasons);
    }

    [Fact]
    public void Fewer_reports_is_a_reason()
    {
        var best = Route("best", 30, 20, Line(3.00), alerts: 2);
        var calm = Route("calm", 33, 21, Line(3.03), alerts: 0);

        var r = RouteChoices.Annotate([best, calm]);

        Assert.Equal([RouteReason.FewerReports], r[1].Reasons);
    }

    [Fact]
    public void A_single_route_has_no_reasons_and_long_motor_trips_want_more()
    {
        var only = Route("only", 30, 25, Line(3.00));
        var r = RouteChoices.Annotate([only]);
        Assert.Empty(r[0].Reasons!);
        Assert.True(RouteChoices.WantsMore(r));

        var shortTrip = RouteChoices.Annotate([Route("s", 10, 6, Line(3.00))]);
        Assert.False(RouteChoices.WantsMore(shortTrip));
    }

    [Fact]
    public void At_most_three_are_shown()
    {
        var routes = Enumerable.Range(0, 4).Select(i => Route($"r{i}", 30 + i, 20 + i * 0.1, Line(3.00 + i * 0.03))).ToList();
        var r = RouteChoices.Annotate(routes);
        Assert.Equal(3, r.Count(x => x.Hidden is null));
        Assert.Equal(RouteHidden.Slower, r[3].Hidden);
    }

    [Fact]
    public void Detour_rings_sit_on_the_main_road_a_third_and_two_thirds_along()
    {
        var line = Line(3.00, n: 31);
        var maneuvers = new List<ManeuverDto> { new(ManeuverType.Straight, "", null, null, "E5", 20_000, 600, 0, 30, null, null) };
        var best = Route("best", 30, 22, line) with { Legs = [new RouteLeg(1800, 22_000, new LegEnd(0, 0, null), maneuvers)] };

        var rings = RouteChoices.MainRoadDetourRings(best);

        Assert.Equal(2, rings.Count);
        Assert.All(rings, ring => Assert.Equal(5, ring.Count));
        var centre = rings[0].Take(4).Average(p => p.Lng);
        Assert.InRange(centre, 101.56, 101.58);
    }

    [Fact]
    public void New_fields_serialise_as_snake_case()
    {
        var r = RouteChoices.Annotate([Route("a", 43, 41, Line(3.0), 8m), Route("b", 57, 32, Line(3.03), 3m)]);
        var json = JsonSerializer.Serialize(r[1], GimanoJson.Options);
        Assert.Contains("\"reasons\":[\"shortest\",\"lower_toll\"]", json);
        Assert.Contains("\"hidden\":null", json);
    }
}
