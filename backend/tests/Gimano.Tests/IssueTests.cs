using System.Text.Json.Nodes;
using Gimano.Api.Services;
using Gimano.Core.Contracts;
using Gimano.Core.Domain;
using Gimano.Core.Geo;
using Gimano.Core.Issues;
using Gimano.Core.Routing;

namespace Gimano.Tests;

/// <summary>Complaints v1 (docs/complaints.md): state machine, thresholds, expiry, geometry, route wiring, payloads.</summary>
public class IssueRulesTests
{
    private static readonly DateTimeOffset T0 = new(2026, 10, 23, 2, 0, 0, TimeSpan.Zero);

    private static Issue New(IssueKind kind, string? subtype = null, bool major = false) => new()
    {
        Kind = kind, Subtype = subtype, MajorRoad = major, State = IssueRules.InitialState(kind), CreatedAt = T0, LastEvidenceAt = T0,
        Location = new GeoPoint(3.1, 101.6).ToPoint(), ExpiresAt = IssueRules.InitialExpiry(kind, subtype, null, null, T0),
        WayId = 1, Seq = 0,
    };

    private static Issue Vote(Issue i, IssueAnswer a, double w, bool emas = false) { IssueRules.ApplyVote(i, a, w, emas, T0); return i; }

    [Theory]
    [InlineData("accident", 2)]
    [InlineData("flood", 6)]
    [InlineData("event", 12)]
    [InlineData("roadworks", 168)]
    [InlineData(null, 6)]
    public void Closure_expiry_by_subtype(string? subtype, int hours) =>
        Assert.Equal(T0.AddHours(hours), IssueRules.InitialExpiry(IssueKind.RoadClosedTemp, subtype, null, null, T0));

    [Fact]
    public void Duration_hints_and_until_dates()
    {
        // 02:00Z = 10:00 MYT → end of the Malaysian day is 16:00Z.
        Assert.Equal(new DateTimeOffset(2026, 10, 23, 16, 0, 0, TimeSpan.Zero), IssueRules.InitialExpiry(IssueKind.RoadClosedTemp, "accident", "today", null, T0));
        Assert.Equal(T0.AddDays(3), IssueRules.InitialExpiry(IssueKind.RoadClosedTemp, null, "few_days", null, T0));
        Assert.Equal(new DateTimeOffset(2026, 10, 30, 16, 0, 0, TimeSpan.Zero), IssueRules.ParseUntil("2026-10-30", T0));
        Assert.Null(IssueRules.ParseUntil("2026-10-01", T0));
        Assert.Equal(T0.AddDays(60), IssueRules.ParseUntil("2027-06-01", T0));   // capped at 60 days
        // Npgsql only writes UTC timestamps: every expiry must have offset 0.
        Assert.Equal(TimeSpan.Zero, IssueRules.ParseUntil("2026-10-30", T0)!.Value.Offset);
        Assert.Equal(TimeSpan.Zero, IssueRules.InitialExpiry(IssueKind.RoadClosedTemp, null, "today", null, T0)!.Value.Offset);
        Assert.Equal(IssueState.Reported, IssueRules.InitialState(IssueKind.OddRoute));
        Assert.Equal(IssueState.Suspected, IssueRules.InitialState(IssueKind.RoadClosedTemp));
    }

    [Fact]
    public void One_report_never_closes_a_road_two_weighted_votes_do()
    {
        var i = Vote(New(IssueKind.RoadClosedTemp, "accident"), IssueAnswer.Still, 1);
        Assert.Equal(IssueState.Suspected, IssueRules.Next(i, IssueEvidence.None, T0.AddMinutes(5)));
        Vote(i, IssueAnswer.Still, 1);
        Assert.Equal(IssueState.Confirmed, IssueRules.Next(i, IssueEvidence.None, T0.AddMinutes(5)));
    }

    [Fact]
    public void Emas_or_passive_evidence_confirms_a_normal_closure()
    {
        var emas = Vote(New(IssueKind.RoadClosedTemp), IssueAnswer.Still, 2, emas: true);
        Assert.Equal(IssueState.Confirmed, IssueRules.Next(emas, IssueEvidence.None, T0));

        var passive = Vote(New(IssueKind.RoadClosedTemp), IssueAnswer.Still, 1);
        var busyRoadNobodyPassed = new IssueEvidence(0, 0, BaselinePerDay: 200);
        Assert.Equal(IssueState.Suspected, IssueRules.Next(passive, busyRoadNobodyPassed, T0.AddMinutes(10)));   // window not over
        Assert.Equal(IssueState.Confirmed, IssueRules.Next(passive, busyRoadNobodyPassed, T0.AddMinutes(31)));
        Assert.Equal(IssueState.Suspected, IssueRules.Next(passive, new IssueEvidence(0, 0, 2), T0.AddMinutes(31)));  // quiet road: no evidence
    }

    [Fact]
    public void Major_roads_need_three_weighted_votes_and_passive_evidence()
    {
        var i = New(IssueKind.RoadClosedTemp, "accident", major: true);
        Vote(i, IssueAnswer.Still, 2, emas: true); Vote(i, IssueAnswer.Still, 1);
        Assert.Equal(IssueState.Suspected, IssueRules.Next(i, IssueEvidence.None, T0.AddMinutes(40)));          // 3 votes, no passive
        Assert.Equal(IssueState.Confirmed, IssueRules.Next(i, new IssueEvidence(0, 0, 500), T0.AddMinutes(40)));
        Assert.Equal(3, IssueRules.Required(i));
        Assert.True(IssueRules.IsMajor("motorway") && IssueRules.IsMajor("trunk_link") && !IssueRules.IsMajor("residential"));
    }

    [Fact]
    public void No_road_needs_votes_and_no_traffic_for_14_days()
    {
        var i = Vote(Vote(New(IssueKind.RoadNotExist, "gate"), IssueAnswer.Still, 1), IssueAnswer.Still, 1);
        Assert.Equal(IssueState.Suspected, IssueRules.Next(i, new IssueEvidence(0, 3, 0), T0));
        Assert.Equal(IssueState.Confirmed, IssueRules.Next(i, new IssueEvidence(0, 0, 0), T0));
    }

    [Fact]
    public void Map_says_one_way_but_two_way_never_changes_routing_and_needs_emas_plus_traffic()
    {
        var i = Vote(New(IssueKind.OnewayWrongOpenDir), IssueAnswer.Still, 1);
        Assert.Equal(IssueState.Suspected, IssueRules.Next(i, new IssueEvidence(0, 9, 0), T0));
        Vote(i, IssueAnswer.Still, 2, emas: true);
        Assert.Equal(IssueState.Confirmed, IssueRules.Next(i, new IssueEvidence(0, 9, 0), T0));
        Assert.False(IssueRules.ExcludesRouting(IssueKind.OnewayWrongOpenDir));
        Assert.False(IssueRules.ExcludesRouting(IssueKind.OnewayWrongClosedDir));   // v1: warn only
        Assert.True(IssueRules.ExcludesRouting(IssueKind.RoadClosedTemp) && IssueRules.ExcludesRouting(IssueKind.RoadNotExist));
    }

    [Fact]
    public void Traffic_flowing_again_or_two_cleared_votes_refute()
    {
        var i = Vote(Vote(New(IssueKind.RoadClosedTemp), IssueAnswer.Still, 1), IssueAnswer.Still, 1);
        Assert.Equal(IssueState.Refuted, IssueRules.Next(i, new IssueEvidence(5, 5, 0), T0.AddHours(1)));
        Assert.Equal(IssueState.Confirmed, IssueRules.Next(i, new IssueEvidence(4, 4, 0), T0.AddHours(1)));

        var v = Vote(New(IssueKind.RoadClosedTemp), IssueAnswer.Still, 1);
        Vote(v, IssueAnswer.Cleared, 1); Vote(v, IssueAnswer.Cleared, 1);
        Assert.Equal(IssueState.Refuted, IssueRules.Next(v, IssueEvidence.None, T0));
    }

    [Fact]
    public void Places_closed_permanently_need_three_or_emas_and_reopen_with_two_still_open()
    {
        var i = New(IssueKind.PlaceClosedPerm);
        Vote(i, IssueAnswer.Still, 1); Vote(i, IssueAnswer.Still, 1);
        Assert.Equal(IssueState.Suspected, IssueRules.Next(i, IssueEvidence.None, T0));
        Vote(i, IssueAnswer.Still, 1);
        Assert.Equal(IssueState.Confirmed, IssueRules.Next(i, IssueEvidence.None, T0));
        IssueRules.Transition(i, IssueState.Confirmed, T0, "test");
        Vote(i, IssueAnswer.Cleared, 1.5); Vote(i, IssueAnswer.Cleared, 1.5);   // "masih buka"
        Assert.Equal(IssueState.Refuted, IssueRules.Next(i, IssueEvidence.None, T0));
        Assert.Equal(IssueState.Confirmed, IssueRules.Next(Vote(New(IssueKind.PlaceClosedPerm), IssueAnswer.Still, 2, true), IssueEvidence.None, T0));
    }

    [Fact]
    public void Expiry_and_extension_by_confirmations()
    {
        var i = Vote(New(IssueKind.RoadClosedTemp, "accident"), IssueAnswer.Still, 1);
        Assert.Equal(IssueState.Expired, IssueRules.Next(i, IssueEvidence.None, T0.AddHours(2)));
        IssueRules.ApplyVote(i, IssueAnswer.Still, 1, false, T0.AddMinutes(90));
        Assert.Equal(T0.AddMinutes(90).AddHours(2), i.ExpiresAt);
        var feedback = New(IssueKind.OddRoute);
        Assert.Equal(IssueState.Reported, IssueRules.Next(feedback, IssueEvidence.None, T0.AddDays(10)));
        Assert.Equal(IssueState.Expired, IssueRules.Next(feedback, IssueEvidence.None, T0.AddDays(91)));
    }

    [Fact]
    public void Transitions_are_audited_and_terminal_states_stick()
    {
        var i = New(IssueKind.TurnNotAllowed);
        Assert.True(IssueRules.Transition(i, IssueState.Confirmed, T0, "votes 2"));
        Assert.Equal(T0, i.ConfirmedAt);
        Assert.Contains("suspected→confirmed (votes 2)", i.History[^1]);
        IssueRules.Transition(i, IssueState.Refuted, T0, "votes cleared 2");
        Assert.Equal(T0, i.ClosedAt);
        Vote(i, IssueAnswer.Still, 5);
        Assert.Equal(IssueState.Refuted, IssueRules.Next(i, IssueEvidence.None, T0.AddDays(400)));
    }

    [Theory]
    [InlineData(IssueAnswer.Still, IssueState.Confirmed, true)]
    [InlineData(IssueAnswer.Cleared, IssueState.Confirmed, false)]
    [InlineData(IssueAnswer.Cleared, IssueState.Refuted, true)]
    [InlineData(IssueAnswer.Still, IssueState.Refuted, false)]
    [InlineData(IssueAnswer.Unsure, IssueState.Confirmed, null)]
    [InlineData(IssueAnswer.Still, IssueState.Expired, null)]
    public void Vote_agreement_for_accuracy(IssueAnswer a, IssueState s, bool? agreed) => Assert.Equal(agreed, IssueRules.Agreed(a, s));

    [Fact]
    public void Stored_coordinates_are_coarse_and_new_road_traces_are_trimmed()
    {
        Assert.Equal(3.14784, IssueRules.Round5m(3.147851), 5);
        Assert.Equal(3.15, IssueRules.Round1km(3.1478));
        var trace = Enumerable.Range(0, 101).Select(k => (3.1 + k * 0.0001, 101.6)).ToList();   // ~1.1 km north
        var t = IssueRules.TrimTrace(trace);
        Assert.True(GeoMath.HaversineM(trace[0].Item1, trace[0].Item2, t[0].Lat, t[0].Lng) >= 200);
        Assert.True(GeoMath.HaversineM(trace[^1].Item1, trace[^1].Item2, t[^1].Lat, t[^1].Lng) >= 200);
        Assert.Empty(IssueRules.TrimTrace(trace.Take(30).ToList()));   // < 400 m: nothing left
    }

    [Theory]
    [InlineData("""{"navLat":3.1196,"navLng":101.6214}""")]
    [InlineData("""{"navLat":"3.1196","navLng":"101.6214"}""")]
    public void Entrance_coordinates_accept_numbers_and_numeric_strings(string json)
    {
        var p = IssueService.ValidatePayload(IssueKind.PlaceEntranceWrong, JsonNode.Parse(json)!.AsObject(), T0);
        Assert.Equal("3.11960", p["navLat"].PadRight(7, '0'));
        Assert.StartsWith("101.6214", p["navLng"]);
    }

    [Theory]
    [InlineData("""{"toLat":3.1196,"toLng":101.6214}""")]
    [InlineData("""{"toLat":"3.1196","toLng":"101.6214"}""")]
    public void Turn_targets_accept_numbers_and_numeric_strings(string json)
    {
        var p = IssueService.ValidatePayload(IssueKind.TurnNotAllowed, JsonNode.Parse(json)!.AsObject(), T0);
        Assert.StartsWith("3.1196", p["toLat"]);
        Assert.StartsWith("101.6214", p["toLng"]);
    }

    [Fact]
    public void Non_numeric_coordinates_are_rejected_and_strings_work_elsewhere()
    {
        Assert.Throws<ValidationException>(() => IssueService.ValidatePayload(IssueKind.PlaceEntranceWrong, JsonNode.Parse("""{"navLat":"abc","navLng":"101.6"}""")!.AsObject(), T0));
        var odd = IssueService.ValidatePayload(IssueKind.OddRoute, JsonNode.Parse("""{"fromLat":"3.147851","fromLng":"101.615312"}""")!.AsObject(), T0);
        Assert.Equal("3.15", odd["fromLat"]);
        var trace = IssueService.ValidatePayload(IssueKind.NewRoad, new JsonObject { ["trace"] = new JsonArray(Enumerable.Range(0, 60)
            .Select(k => (JsonNode)new JsonArray((3.1 + k * 0.0002).ToString(System.Globalization.CultureInfo.InvariantCulture), "101.6")).ToArray()) }, T0);
        Assert.Contains(';', trace["trace"]);
    }

    [Fact]
    public void Payloads_are_validated_and_normalised()
    {
        var p = IssueService.ValidatePayload(IssueKind.OddRoute, JsonNode.Parse("""{"fromLat":3.147851,"fromLng":101.615312,"toLat":3.0,"toLng":101.7,"chosen":"LDP"}""")!.AsObject(), T0);
        Assert.Equal("3.15", p["fromLat"]);
        Assert.Equal("101.62", p["fromLng"]);
        Assert.Throws<ValidationException>(() => IssueService.ValidatePayload(IssueKind.PlaceClosedTemp, JsonNode.Parse("""{"until":"2020-01-01"}""")!.AsObject(), T0));
        Assert.Equal("2026-11-01", IssueService.ValidatePayload(IssueKind.PlaceClosedTemp, JsonNode.Parse("""{"until":"2026-11-01"}""")!.AsObject(), T0)["until"]);
        Assert.Throws<ValidationException>(() => IssueService.ValidatePayload(IssueKind.PlaceEntranceWrong, new JsonObject(), T0));
        var nav = IssueService.ValidatePayload(IssueKind.PlaceEntranceWrong, JsonNode.Parse("""{"navLat":3.1,"navLng":101.6}""")!.AsObject(), T0);
        Assert.Equal("3.1", nav["navLat"]);
        Assert.Equal("Mo-Fr 09:00-18:00", IssueService.ValidatePayload(IssueKind.PlaceHoursWrong, JsonNode.Parse("""{"openingHours":"Mo-Fr 09:00-18:00"}""")!.AsObject(), T0)["openingHours"]);
        var nr = IssueService.ValidatePayload(IssueKind.NewRoad, new JsonObject { ["trace"] = new JsonArray(Enumerable.Range(0, 60).Select(k => (JsonNode)new JsonArray(3.1 + k * 0.0002, 101.6)).ToArray()) }, T0);
        Assert.True(nr["trace"].Split(';').Length < 60);
    }
}

public class IssueGeometryTests
{
    private static readonly List<GeoPoint> Line = Enumerable.Range(0, 11).Select(k => new GeoPoint(3.1 + k * 0.0002, 101.6)).ToList(); // ~222 m

    [Fact]
    public void Exclusion_box_sits_mid_segment_away_from_the_junctions()
    {
        var ring = IssueGeometry.ExclusionRing(Line);
        Assert.Equal(5, ring.Count);
        Assert.Equal(ring[0], ring[^1]);
        foreach (var (lng, lat) in ring)
        {
            Assert.True(GeoMath.HaversineM(lat, lng, Line[0].Lat, Line[0].Lng) > 50, "away from the start junction");
            Assert.True(GeoMath.HaversineM(lat, lng, Line[^1].Lat, Line[^1].Lng) > 50, "away from the end junction");
            Assert.True(GeoMath.HaversineM(lat, lng, 3.101, 101.6) < 40, "around the middle");
        }
        var json = IssueGeometry.ToValhalla([ring]);
        Assert.Equal(5, json[0]!.AsArray().Count);
        Assert.Equal(2, json[0]![0]!.AsArray().Count);   // [lng, lat]
        Assert.Equal(5, IssueGeometry.ExclusionRing([new GeoPoint(3.1, 101.6), new GeoPoint(3.10002, 101.6)]).Count);   // short segment
    }

    [Fact]
    public void Valhalla_request_carries_exclude_polygons_only_when_there_are_some()
    {
        var req = new RouteRequest(new LatLng(3.1, 101.6), new LatLng(3.2, 101.7), null, Vehicle.Car, null, null, 0);
        Assert.Null(ValhallaMapper.BuildRouteRequest(req)["exclude_polygons"]);
        var body = ValhallaMapper.BuildRouteRequest(req, excludePolygons: IssueGeometry.ToValhalla([IssueGeometry.ExclusionRing(Line)]));
        Assert.Single(body["exclude_polygons"]!.AsArray());
    }
}

public class IssueRoutingTests
{
    private static readonly List<GeoPoint> Seg = Enumerable.Range(0, 11).Select(k => new GeoPoint(3.12 + k * 0.0002, 101.62)).ToList();

    private static IssueDirectory.RoadIssue Road(IssueKind kind, IssueState state, Vehicle? vehicle = null, List<GeoPoint>? line = null)
    {
        line ??= Seg;
        var i = new Issue { Kind = kind, State = state, Vehicle = vehicle, WayId = 7, Seq = 0, RoadName = "Jalan SS 2/24", Location = line[line.Count / 2].ToPoint() };
        return new IssueDirectory.RoadIssue(i, line, IssueGeometry.PointAt(line, GeoMath.LengthM(line) / 2), IssueGeometry.ExclusionRing(line));
    }

    private static IssueDirectory.Snapshot Snap(IReadOnlyList<IssueDirectory.RoadIssue> ex, IReadOnlyList<IssueDirectory.RoadIssue> warn, Issue? nav = null) =>
        new(ex, warn, new Dictionary<string, Issue>(), new HashSet<string>(),
            nav is null ? new Dictionary<string, Issue>() : new Dictionary<string, Issue> { [nav.PlaceId ?? "n1"] = nav }, new Dictionary<string, string>(), DateTimeOffset.UtcNow);

    [Fact]
    public void Confirmed_closures_near_the_trip_become_exclusions_unless_ignored_or_for_another_vehicle()
    {
        var closed = Road(IssueKind.RoadClosedTemp, IssueState.Confirmed);
        var carOnly = Road(IssueKind.RoadNotExist, IssueState.Confirmed, Vehicle.Car);
        var far = Road(IssueKind.RoadClosedTemp, IssueState.Confirmed, line: [new GeoPoint(5.4, 100.3), new GeoPoint(5.401, 100.3)]);
        var s = Snap([closed, carOnly, far], []);
        var req = new RouteRequest(new LatLng(3.10, 101.60), new LatLng(3.15, 101.65), null, Vehicle.Car, null, null, 0);

        Assert.Equal(2, RouteService.Exclusions(req, Vehicle.Car, s).Count);                         // far one (Penang) not
        Assert.Single(RouteService.Exclusions(req, Vehicle.Motorcycle, s));                            // no-road was reported for cars
        Assert.Single(RouteService.Exclusions(req with { IgnoreIssues = [closed.Issue.Id] }, Vehicle.Car, s));   // "Lalu juga"
        Assert.Empty(RouteService.Exclusions(req, Vehicle.Walk, s));
    }

    [Fact]
    public void Route_lists_avoided_and_on_route_issues()
    {
        var avoided = Road(IssueKind.RoadClosedTemp, IssueState.Confirmed);
        var warn = Road(IssueKind.RoadClosedTemp, IssueState.Suspected, line: Enumerable.Range(0, 5).Select(k => new GeoPoint(3.13, 101.62 + k * 0.0002)).ToList());
        var routeLine = new List<GeoPoint> { new(3.13, 101.60), new(3.13, 101.65) };   // passes the suspected one; ~1 km from the closed one
        var dto = new RouteDto("r", RouteLabel.Best, 600, 5000, 600, "", "", Vehicle.Car, false, null, true, [], Polyline.Encode(routeLine), [], [], [], []);
        var issues = RouteService.IssuesFor(dto, [avoided], Snap([avoided], [warn]), null);
        Assert.Contains(issues, i => i.Id == avoided.Issue.Id && i.Avoided && i.Summary.Contains("Jalan SS 2/24"));
        Assert.Contains(issues, i => i.Id == warn.Issue.Id && !i.Avoided && i.DistanceAlongRouteM > 0);
    }

    [Fact]
    public void A_confirmed_entrance_correction_moves_the_routing_destination()
    {
        var nav = new Issue { Kind = IssueKind.PlaceEntranceWrong, State = IssueState.Confirmed, PlaceId = "n1", Location = new GeoPoint(3.1, 101.6).ToPoint(),
            Payload = new() { ["navLat"] = "3.10011", ["navLng"] = "101.60022" } };
        var req = new RouteRequest(new LatLng(3.0, 101.5), new LatLng(3.1, 101.6, "n1", "Kedai"), null, Vehicle.Car, null, null, 0);
        var routed = RouteService.WithNavigationPoints(req, Snap([], [], nav));
        Assert.Equal(3.10011, routed.Destination.Lat);
        Assert.Equal(101.60022, routed.Destination.Lng);
        Assert.Equal("n1", routed.Destination.PlaceId);
    }

    [Fact]
    public void An_imported_entrance_is_the_routing_destination_unless_a_correction_is_confirmed()
    {
        var entrances = new Dictionary<string, PlaceEntrance>
        {
            ["w9"] = new() { PlaceId = "w9", Location = new GeoPoint(3.2001, 101.7002).ToPoint(), Source = "osm_entrance", Kind = "main" },
        };
        var req = new RouteRequest(new LatLng(3.0, 101.5), new LatLng(3.2, 101.7, "w9", "Mall"), null, Vehicle.Car, null, null, 0);
        var routed = RouteService.WithNavigationPoints(req, Snap([], []), entrances);
        Assert.Equal((3.2001, 101.7002, "w9"), (routed.Destination.Lat, routed.Destination.Lng, routed.Destination.PlaceId));
        var arrival = RouteService.ArrivalPoint(req.Destination, Snap([], []), entrances);
        Assert.Equal(("osm_entrance", "main", (Guid?)null), (arrival!.Source, arrival.Kind, arrival.IssueId));

        // A dropped pin (no placeId) is routed as it is.
        Assert.Null(RouteService.ArrivalPoint(new LatLng(3.2, 101.7), Snap([], []), entrances));

        // A confirmed correction wins over the imported entrance.
        var nav = new Issue { Kind = IssueKind.PlaceEntranceWrong, State = IssueState.Confirmed, PlaceId = "w9", Location = new GeoPoint(3.2, 101.7).ToPoint(),
            Payload = new() { ["navLat"] = "3.2003", ["navLng"] = "101.7004" } };
        Assert.Equal(("confirmed", 3.2003), (RouteService.ArrivalPoint(req.Destination, Snap([], [], nav), entrances)!.Source,
            RouteService.WithNavigationPoints(req, Snap([], [], nav), entrances).Destination.Lat));
    }

    [Theory]
    [InlineData("main", "main")]
    [InlineData("yes", "yes")]
    [InlineData("exit", null)]
    [InlineData("emergency", null)]
    public void Entrance_kinds(string value, string? expected) =>
        Assert.Equal(expected, Gimano.Importer.OsmImporter.EntranceKind(new Dictionary<string, string> { ["entrance"] = value }));

    [Fact]
    public void Best_entrance_prefers_main_then_yes_then_others_then_service()
    {
        var kinds = new Dictionary<long, string> { [2] = "service", [3] = "yes", [4] = "main" };
        Assert.Equal(4, Gimano.Importer.OsmImporter.BestEntrance([1, 2, 3, 4, 1], kinds));
        Assert.Equal(3, Gimano.Importer.OsmImporter.BestEntrance([1, 2, 3, 1], kinds));
        Assert.Null(Gimano.Importer.OsmImporter.BestEntrance([1, 5, 1], kinds));
    }
}
