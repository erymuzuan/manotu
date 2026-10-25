using System.Text.Json;
using System.Text.Json.Nodes;
using Gimano.Api.Endpoints;
using Gimano.Api.Services;
using Gimano.Core.Contracts;
using Gimano.Core.Domain;
using Gimano.Core.Geo;
using Gimano.Core.Routing;
using Gimano.Core.Support;
using Gimano.Core.Tolls;
using Gimano.Core.Traffic;
using Gimano.Importer;

namespace Gimano.Tests;

public class TravelModeTests
{
    private static RouteRequest Req(Vehicle v, AvoidOptions? avoid = null, IReadOnlyList<LatLng>? waypoints = null) =>
        new(new LatLng(3.118, 101.619), new LatLng(3.1176, 101.6773), waypoints ?? [], v, avoid, null, 2);

    [Theory]
    [InlineData(Vehicle.Car, "auto")]
    [InlineData(Vehicle.Motorcycle, "motorcycle")]
    [InlineData(Vehicle.Bicycle, "bicycle")]
    [InlineData(Vehicle.Walk, "pedestrian")]
    public void Vehicles_map_to_valhalla_costings(Vehicle v, string costing)
    {
        Assert.Equal(costing, ValhallaMapper.Costing(v));
        Assert.Equal(costing, ValhallaMapper.BuildRouteRequest(Req(v))["costing"]!.GetValue<string>());
    }

    [Theory]
    [InlineData(Vehicle.Bicycle)]
    [InlineData(Vehicle.Walk)]
    public void Avoid_options_are_ignored_for_bicycle_and_walk(Vehicle v)
    {
        var body = ValhallaMapper.BuildRouteRequest(Req(v, new AvoidOptions(true, true, true)));
        var opts = body["costing_options"]![ValhallaMapper.Costing(v)]!.AsObject();
        Assert.False(opts.ContainsKey("use_tolls"));
        Assert.False(opts.ContainsKey("toll_booth_penalty"));
        Assert.False(opts.ContainsKey("use_highways"));
    }

    [Fact]
    public void Walk_and_cycle_vehicles_parse_from_the_wire()
    {
        Assert.Equal(Vehicle.Walk, JsonSerializer.Deserialize<Vehicle>("\"walk\"", GimanoJson.Options));
        Assert.Equal(Vehicle.Bicycle, JsonSerializer.Deserialize<Vehicle>("\"bicycle\"", GimanoJson.Options));
    }

    [Fact]
    public void Bicycle_routes_have_no_traffic_and_no_tolls_and_echo_vehicle()
    {
        var c = ValhallaMapper.MapResponse(ValhallaMappingTests.SampleResponse(withAlternate: false));
        var pts = c[0].Points;
        var jam = new JamLine(4, 5, [pts[1], pts[2]]);
        var plaza = new TollPlaza("n1", "Plaza Tol X", pts[2].Lat, pts[2].Lng);
        var tariff = new TollTariff("Plaza Tol X", "E23", TollSystem.Open, null, 0m, 1.6m, "https://example.org", ["n1"]);

        var bike = RouteDecorator.Decorate(c, [], [jam], () => "b", Vehicle.Bicycle, [plaza], [tariff])[0];
        Assert.Equal(Vehicle.Bicycle, bike.Vehicle);
        Assert.Empty(bike.TrafficSegments);
        Assert.Equal(bike.DurationS, bike.TrafficDurationS);
        Assert.Empty(bike.Tolls);
        Assert.False(bike.HasTolls);
        Assert.True(bike.TollFareComplete);

        var car = RouteDecorator.Decorate(c, [], [jam], () => "c", Vehicle.Car, [plaza], [tariff])[0];
        Assert.Equal(Vehicle.Car, car.Vehicle);
        Assert.NotEmpty(car.TrafficSegments);
        Assert.True(car.HasTolls);
        Assert.Equal(1.6m, car.TollEstimateMyr);
    }
}

public class MultiStopTests
{
    [Fact]
    public void Waypoints_are_break_stops_and_become_legs_with_names()
    {
        var wp = new LatLng(3.1579, 101.7116, null, "KLCC");
        var body = ValhallaMapper.BuildRouteRequest(new RouteRequest(new LatLng(3.118, 101.619), new LatLng(3.1176, 101.6773), [wp], Vehicle.Car, null, null, 2));
        Assert.All(body["locations"]!.AsArray(), l => Assert.Equal("break", l!["type"]!.GetValue<string>()));
        Assert.Null(body["alternates"]);

        var stops = new[] { wp, new LatLng(3.1176, 101.6773, null, "Mid Valley") };
        var r = ValhallaMapper.MapResponse(ValhallaMappingTests.SampleResponse(withAlternate: false, twoLegs: true), stops)[0];
        Assert.Equal(2, r.Legs.Count);
        Assert.Equal("KLCC", r.Legs[0].To.Name);
        Assert.Equal(3.1579, r.Legs[0].To.Lat);
        Assert.Equal("Mid Valley", r.Legs[1].To.Name);
        Assert.Equal(120.5, r.Legs[0].DurationS);
        Assert.Equal(750, r.Legs[0].DistanceM);
        Assert.Equal(1600, r.Legs[1].DistanceM);
        Assert.Equal(r.DistanceM, r.Legs.Sum(l => l.DistanceM), 1);
    }

    [Fact]
    public void Leg_end_falls_back_to_the_last_shape_vertex()
    {
        var r = ValhallaMapper.MapResponse(ValhallaMappingTests.SampleResponse(withAlternate: false))[0];
        Assert.Equal(r.Points[^1].Lat, r.Legs[0].To.Lat, 6);
        Assert.Null(r.Legs[0].To.Name);
    }

    [Fact]
    public void Alerts_on_route_cover_all_legs()
    {
        var r = ValhallaMapper.MapResponse(ValhallaMappingTests.SampleResponse(withAlternate: false, twoLegs: true))[0];
        var onLeg2 = r.Points[^2];
        var report = new ReportDto(Guid.NewGuid(), ReportType.Hazard, null, onLeg2.Lat, onLeg2.Lng, null, null,
            new ReportedBy("x", "happy"), DateTimeOffset.UtcNow, DateTimeOffset.UtcNow.AddHours(1), 0, 0);
        var route = RouteDecorator.Decorate([r], [report], [], () => "id")[0];
        Assert.Single(route.Alerts);
        Assert.True(route.Alerts[0].DistanceAlongRouteM > r.Legs[0].DistanceM * 0.9);
    }

    [Theory]
    [InlineData(null, 3)]
    [InlineData(0, 3)]
    [InlineData(1, 2)]
    [InlineData(3, 0)]
    [InlineData(9, 0)]
    [InlineData(-1, 3)]
    public void Reroute_keeps_the_remaining_stops(int? next, int remaining)
    {
        var wps = new[] { new LatLng(1, 1, null, "a"), new LatLng(2, 2, null, "b"), new LatLng(3, 3, null, "c") };
        var left = RouteService.RemainingStops(wps, next);
        Assert.Equal(remaining, left.Count);
        if (remaining > 0) Assert.Equal(wps[^1], left[^1]);
    }

    [Fact]
    public void Route_json_matches_the_new_contract()
    {
        var c = ValhallaMapper.MapResponse(ValhallaMappingTests.SampleResponse(withAlternate: false));
        var json = JsonSerializer.Serialize(RouteDecorator.Decorate(c, [], [], () => "x", Vehicle.Walk)[0], GimanoJson.Options);
        var n = JsonNode.Parse(json)!;
        Assert.Equal("walk", n["vehicle"]!.GetValue<string>());
        Assert.True(n["tollFareComplete"]!.GetValue<bool>());
        Assert.Empty(n["tolls"]!.AsArray());
        var leg = n["legs"]![0]!;
        Assert.NotNull(leg["durationS"]);
        Assert.NotNull(leg["distanceM"]);
        Assert.NotNull(leg["to"]!["lat"]);
    }
}

public class TollCalculatorTests
{
    // A straight eastbound route along lat 3.0 from lng 101.00 to 101.10 (~11 km).
    private static readonly GeoPoint[] Route = Enumerable.Range(0, 11).Select(i => new GeoPoint(3.0, 101.0 + i * 0.01)).ToArray();

    private static TollPlaza P(string id, string name, double lng, double latOffset = 0) => new(id, name, 3.0 + latOffset, lng);

    [Fact]
    public void Open_plaza_is_priced_by_vehicle_class()
    {
        var plazas = new[] { P("n1", "Plaza Tol Damansara (B)", 101.025) };
        var tariffs = new[] { new TollTariff("Plaza Tol Damansara", "E23", TollSystem.Open, null, 0.00m, 1.60m, "https://src", ["n1"]) };

        var car = TollCalculator.Compute(Route, plazas, tariffs, Vehicle.Car);
        var t = Assert.Single(car.Tolls);
        Assert.Equal(1.60m, t.FareMyr);
        Assert.Equal("Plaza Tol Damansara", t.Name);
        Assert.Equal("E23", t.Highway);
        Assert.Equal("https://src", t.Source);
        Assert.Equal(TollSystem.Open, t.System);
        Assert.InRange(t.DistanceAlongRouteM!.Value, 2700, 2860);   // 0.025° of longitude at 3° N ≈ 2.78 km
        Assert.Equal(1.60m, car.EstimateMyr);
        Assert.True(car.FareComplete);

        Assert.Equal(0.00m, TollCalculator.Compute(Route, plazas, tariffs, Vehicle.Motorcycle).EstimateMyr);
    }

    [Fact]
    public void Lane_nodes_of_one_plaza_count_once_and_plazas_are_in_travel_order()
    {
        var plazas = new[]
        {
            P("n3", "Plaza Tol Kedua", 101.080),
            P("n1", "Plaza Tol Pertama A1", 101.020, 0.00005),
            P("n2", "Plaza Tol Pertama A2", 101.0202, -0.00005),
        };
        var r = TollCalculator.Compute(Route, plazas, [], Vehicle.Car);
        Assert.Equal(["Plaza Tol Pertama", "Plaza Tol Kedua"], r.Tolls.Select(t => t.Name));
    }

    [Fact]
    public void Booth_lines_of_one_named_plaza_a_few_hundred_metres_apart_are_one_toll()
    {
        // Real case: Plaza Tol Pantai (A) and (B) on Kerinchi Link, ~240 m apart along the route.
        var plazas = new[] { P("n1", "Plaza Tol Pantai (A)", 101.0300), P("n2", "Plaza Tol Pantai (B)", 101.0322) };
        var tariffs = new[] { new TollTariff("Plaza Tol Pantai (A)", "E23", TollSystem.Open, null, null, 2.50m, "https://src", ["n1", "n2"]) };
        var r = TollCalculator.Compute(Route, plazas, tariffs, Vehicle.Car);
        Assert.Single(r.Tolls);
        Assert.Equal(2.50m, r.EstimateMyr);
        Assert.True(r.FareComplete);
    }

    [Fact]
    public void Unknown_fares_make_the_estimate_partial()
    {
        var plazas = new[] { P("n1", "Plaza Tol A", 101.02), P("n2", "Plaza Tol B", 101.06) };
        var tariffs = new[] { new TollTariff("Plaza Tol A", "E11", TollSystem.Open, null, null, 2.10m, "https://src", ["n1"]) };
        var r = TollCalculator.Compute(Route, plazas, tariffs, Vehicle.Car);
        Assert.Equal(2, r.Tolls.Count);
        Assert.Null(r.Tolls[1].FareMyr);
        Assert.Equal(2.10m, r.EstimateMyr);
        Assert.False(r.FareComplete);

        // Class 0 unknown in the table → not assumed free.
        var moto = TollCalculator.Compute(Route, plazas, tariffs, Vehicle.Motorcycle);
        Assert.Null(moto.EstimateMyr);
        Assert.False(moto.FareComplete);
    }

    [Fact]
    public void Plazas_off_the_route_are_ignored()
    {
        var r = TollCalculator.Compute(Route, [P("n1", "Plaza Tol Jauh", 101.05, 0.001)], [], Vehicle.Car); // ~110 m away
        Assert.Empty(r.Tolls);
        Assert.Null(r.EstimateMyr);
        Assert.True(r.FareComplete);
    }

    [Fact]
    public void Closed_system_is_priced_by_entry_exit_pair()
    {
        var plazas = new[] { P("n1", "Plaza Tol Sungai Besi", 101.01), P("n2", "Plaza Tol Seremban", 101.09) };
        var tariffs = new[] { new TollTariff("Plaza Tol Seremban", "E2", TollSystem.ClosedExit, "Sungai Besi", null, 7.70m, "https://plus", ["n2"]) };
        var r = TollCalculator.Compute(Route, plazas, tariffs, Vehicle.Car);
        Assert.Equal(TollSystem.ClosedEntry, r.Tolls[0].System);
        Assert.Equal(0m, r.Tolls[0].FareMyr);
        Assert.Equal(TollSystem.ClosedExit, r.Tolls[1].System);
        Assert.Equal(7.70m, r.Tolls[1].FareMyr);
        Assert.Equal(7.70m, r.EstimateMyr);
        Assert.True(r.FareComplete);
    }

    [Fact]
    public void Closed_exit_without_a_known_entry_has_no_fare()
    {
        var plazas = new[] { P("n2", "Plaza Tol Seremban", 101.09) };
        var tariffs = new[] { new TollTariff("Plaza Tol Seremban", "E2", TollSystem.ClosedExit, "Sungai Besi", null, 7.70m, "https://plus", ["n2"]) };
        var r = TollCalculator.Compute(Route, plazas, tariffs, Vehicle.Car);
        Assert.Null(r.Tolls[0].FareMyr);
        Assert.False(r.FareComplete);
    }

    [Theory]
    [InlineData("Plaza Tol Damansara (B)", "damansara")]
    [InlineData("Plaza Toll PLUS Damansara", "damansara")]
    [InlineData("Alam Damai Toll Plaza B1", "alam damai")]
    [InlineData("Plaza Tol Sungai Besi", "sg besi")]
    [InlineData("Plaza Tol Sg Besi", "sg besi")]
    [InlineData("Plaza Tol Dato' Keramat", "dato keramat")]
    [InlineData("Plaza Tol Jambatan Pulau Pinang (A)", "jambatan pulau pinang")]
    public void Normalises_plaza_names(string name, string key) => Assert.Equal(key, TollCalculator.NormalizeName(name));

    [Theory]
    [InlineData("Plaza Tol Pantai (A)", "Plaza Tol Pantai")]
    [InlineData("Alam Damai Toll Plaza B1", "Alam Damai Toll Plaza")]
    [InlineData("Plaza Tol Penchala", "Plaza Tol Penchala")]
    public void Display_name_drops_lane_suffixes(string name, string display) => Assert.Equal(display, TollCalculator.DisplayName(name));
}

public class TollRateCsvTests
{
    private const string Csv = """
        plaza_osm_id,name,highway,lat,lng,system,entry_plaza,class0_myr,class1_myr,effective_date,source_url,notes
        n100,Plaza Tol Damansara,E23,3.1300,101.6300,open,,0.00,1.60,2024-01-01,https://example.org/sprint,"direction: both, TnG"
        ,Plaza Tol Penchala,E11,3.1500,101.6200,open,,,2.10,2023-06-01,https://example.org/ldp,
        ,Plaza Tol Seremban,E2,,,closed_exit,Sungai Besi,,7.70,2024-01-01,https://example.org/plus,
        ,Plaza Tol Hilang,E99,,,open,,,1.00,2024-01-01,https://example.org/x,
        ,Plaza Tol Tanpa Sumber,E1,,,open,,,1.00,2024-01-01,,
        ,Plaza Tol Salah,E1,,,sideways,,,1.00,2024-01-01,https://example.org/x,
        """;

    [Fact]
    public void Parses_rows_and_rejects_unsourced_or_invalid_ones()
    {
        var r = TollRateCsv.Parse(Csv);
        Assert.Equal(4, r.Rows.Count);
        Assert.Equal(2, r.Errors.Count);
        Assert.Contains(r.Errors, e => e.Contains("source_url"));
        Assert.Contains(r.Errors, e => e.Contains("system"));

        var d = r.Rows[0];
        Assert.Equal("n100", d.PlazaOsmId);
        Assert.Equal(1.60m, d.Class1Myr);
        Assert.Equal(0.00m, d.Class0Myr);
        Assert.Equal(new DateOnly(2024, 1, 1), d.EffectiveDate);
        Assert.Equal("direction: both, TnG", d.Notes);
        Assert.Null(r.Rows[1].Class0Myr);
        Assert.Equal(TollSystem.ClosedExit, r.Rows[2].System);
        Assert.Equal("Sungai Besi", r.Rows[2].EntryPlaza);
    }

    [Fact]
    public void Matches_by_osm_id_name_and_location_with_sibling_lane_nodes()
    {
        var plazas = new[]
        {
            new TollPlaza("n100", "Plaza Tol Damansara (A)", 3.1300, 101.6300),
            new TollPlaza("n101", "Plaza Tol Damansara (B)", 3.1302, 101.6303),  // sibling lane, 40 m
            new TollPlaza("n900", "Plaza Tol Damansara", 3.2000, 101.6000),      // same name, 8 km away (another highway)
            new TollPlaza("n200", "Plaza Tol Penchala", 3.1501, 101.6201),
            new TollPlaza("n300", "Plaza Toll PLUS Seremban Exit", 2.7, 101.9),
            new TollPlaza("n301", "Plaza Tol Seremban", 2.7001, 101.9001),
        };
        var m = TollRateCsv.Match(TollRateCsv.Parse(Csv).Rows, plazas);

        Assert.Equal(["n100", "n101"], m[0].PlaceIds);
        Assert.Equal("osm_id", m[0].Method);
        Assert.Equal(["n200"], m[1].PlaceIds);
        Assert.Equal("name+location", m[1].Method);
        Assert.Contains("n301", m[2].PlaceIds);   // name only, unique within 2 km
        Assert.Empty(m[3].PlaceIds);
        Assert.StartsWith("unmatched", m[3].Method);
    }

    [Fact]
    public void Ambiguous_names_without_location_stay_unmatched()
    {
        var rows = TollRateCsv.Parse("name,system,class1_myr,source_url\nPlaza Tol Bukit Raja,open,1.00,https://x\n").Rows;
        var plazas = new[] { new TollPlaza("a", "Plaza Tol Bukit Raja", 3.0, 101.4), new TollPlaza("b", "Plaza Tol Bukit Raja", 3.1, 101.5) };
        var m = Assert.Single(TollRateCsv.Match(rows, plazas));
        Assert.Empty(m.PlaceIds);
        Assert.Contains("ambiguous", m.Method);
    }

    [Fact]
    public void Match_report_lists_unmatched_rows()
    {
        var rows = TollRateCsv.Parse(Csv).Rows;
        var report = OsmImporter.BuildTollReport("my-toll-rates.csv", TollRateCsv.Match(rows, []), ["line 6: x"], 0);
        Assert.Contains("## Unmatched rows", report);
        Assert.Contains("Plaza Tol Hilang", report);
        Assert.Contains("line 6: x", report);
    }

    [Fact]
    public void Repo_toll_table_is_valid_when_present()
    {
        var path = FindRepoFile("data/tolls/my-toll-rates.csv");
        if (path is null) return; // table not added yet
        var r = TollRateCsv.Parse(File.ReadAllText(path));
        Assert.Empty(r.Errors);
        Assert.All(r.Rows, row =>
        {
            Assert.False(string.IsNullOrWhiteSpace(row.SourceUrl));
            Assert.True(row.Class0Myr is not null || row.Class1Myr is not null, $"{row.Name} has no fare");
            Assert.InRange(row.Class1Myr ?? 0, 0, 200);
        });
    }

    private static string? FindRepoFile(string rel)
    {
        for (var d = new DirectoryInfo(AppContext.BaseDirectory); d is not null; d = d.Parent)
            if (File.Exists(Path.Combine(d.FullName, rel))) return Path.Combine(d.FullName, rel);
        return null;
    }
}

public class FavouriteTests
{
    private static SavedPlace Fav(SavedPlaceKind kind, string name, int order, int ageMinutes = 0) => new()
    {
        Kind = kind, Name = name, SortOrder = order, Location = new GeoPoint(3, 101).ToPoint(),
        CreatedAt = DateTimeOffset.UtcNow.AddMinutes(-ageMinutes),
    };

    [Fact]
    public void Home_and_work_come_first_then_favourites_by_sort_order()
    {
        var ordered = AuthAndMeEndpoints.Ordered(
        [
            Fav(SavedPlaceKind.Favorite, "Kampung", 2),
            Fav(SavedPlaceKind.Work, "Ofis", 0),
            Fav(SavedPlaceKind.Favorite, "Rumah Mertua", 0, ageMinutes: 1),
            Fav(SavedPlaceKind.Favorite, "Sekolah Aina", 0, ageMinutes: 5),
            Fav(SavedPlaceKind.Home, "Rumah", 0),
        ]).Select(p => p.Name);
        Assert.Equal(["Rumah", "Ofis", "Sekolah Aina", "Rumah Mertua", "Kampung"], ordered);
    }

    [Fact]
    public void Home_and_work_always_use_their_own_icon()
    {
        var home = Fav(SavedPlaceKind.Home, "Rumah", 0);
        home.Icon = FavoriteIcon.Heart;
        Assert.Equal(FavoriteIcon.Home, home.ToDto().Icon);
        var fav = Fav(SavedPlaceKind.Favorite, "Kampung", 0);
        fav.Icon = FavoriteIcon.Kampung;
        Assert.Equal(FavoriteIcon.Kampung, fav.ToDto().Icon);
        Assert.Equal(FavoriteIcon.Star, new SavedPlace { Name = "x", Location = new GeoPoint(3, 101).ToPoint() }.Icon);
    }

    [Theory]
    [InlineData("Kampung", true)]
    [InlineData("Rumah Mertua di Kuala Kangsar yang jauh", true)]   // 40 chars
    [InlineData("Rumah Mertua di Kuala Kangsar yang jauh!!", false)] // 41 chars
    [InlineData("   ", false)]
    [InlineData(null, false)]
    public void Favourite_names_are_1_to_40_chars(string? name, bool ok) =>
        Assert.Equal(ok, Validation.FavouriteName(name) is null);

    [Theory]
    [InlineData("kampung", FavoriteIcon.Kampung)]
    [InlineData("mertua", FavoriteIcon.Mertua)]
    [InlineData("surau", FavoriteIcon.Surau)]
    public void Icons_use_the_shared_set(string wire, FavoriteIcon icon) =>
        Assert.Equal(icon, JsonSerializer.Deserialize<FavoriteIcon>($"\"{wire}\"", GimanoJson.Options));

    [Fact]
    public void Unknown_icons_are_rejected() =>
        Assert.Throws<JsonException>(() => JsonSerializer.Deserialize<PatchPlaceRequest>("""{"icon":"rocket"}""", GimanoJson.Options));
}

public class FeedbackTests
{
    private static readonly byte[] Png = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 0];
    private static readonly byte[] Jpeg = [0xFF, 0xD8, 0xFF, 0xE0, 0, 0];

    [Fact]
    public void Accepts_png_and_jpeg_raw_or_data_url()
    {
        var png = FeedbackEndpoints.DecodeScreenshot(Convert.ToBase64String(Png));
        Assert.Equal("image/png", png.ContentType);
        Assert.Equal(Png, png.Bytes);
        var jpg = FeedbackEndpoints.DecodeScreenshot("data:image/jpeg;base64," + Convert.ToBase64String(Jpeg));
        Assert.Equal("image/jpeg", jpg.ContentType);
    }

    [Fact]
    public void Rejects_non_images_and_bad_base64()
    {
        Assert.Equal(FeedbackEndpoints.ScreenshotError.Invalid, FeedbackEndpoints.DecodeScreenshot(Convert.ToBase64String("GIF89a"u8.ToArray())).Error);
        Assert.Equal(FeedbackEndpoints.ScreenshotError.Invalid, FeedbackEndpoints.DecodeScreenshot("not base64 at all!").Error);
    }

    [Fact]
    public void Screenshots_over_1_5_MB_are_too_large()
    {
        var big = new byte[FeedbackEndpoints.MaxScreenshotBytes + 1];
        Png.CopyTo(big, 0);
        Assert.Equal(FeedbackEndpoints.ScreenshotError.TooLarge, FeedbackEndpoints.DecodeScreenshot(Convert.ToBase64String(big)).Error);
        var ok = new byte[FeedbackEndpoints.MaxScreenshotBytes];
        Png.CopyTo(ok, 0);
        Assert.Equal(FeedbackEndpoints.ScreenshotError.None, FeedbackEndpoints.DecodeScreenshot(Convert.ToBase64String(ok)).Error);
    }

    [Theory]
    [InlineData("", null, false)]
    [InlineData("ok", null, true)]
    [InlineData("ok", 0, false)]
    [InlineData("ok", 6, false)]
    [InlineData("ok", 5, true)]
    public void Validates_message_and_rating(string message, int? rating, bool ok) =>
        Assert.Equal(ok, FeedbackEndpoints.Validate(new CreateFeedbackRequest(FeedbackCategory.Bug, message, rating, null, null, null)) is null);

    [Fact]
    public void Message_is_limited_to_2000_chars() =>
        Assert.NotNull(FeedbackEndpoints.Validate(new CreateFeedbackRequest(FeedbackCategory.Idea, new string('a', 2001), null, null, null, null)));

    [Fact]
    public void Request_deserialises_from_contract_example()
    {
        const string json = """
            {"category":"map_data","message":"Jalan ini sudah ditutup sejak minggu lepas","rating":4,"screen":"route_preview",
             "context":{"appVersion":"0.1.0 (1)","platform":"android","osVersion":"16","deviceModel":"SM-S921B","locale":"ms","lat":3.118,"lng":101.619,"routeId":"r1","placeId":null},
             "screenshot":null}
            """;
        var r = JsonSerializer.Deserialize<CreateFeedbackRequest>(json, GimanoJson.Options)!;
        Assert.Equal(FeedbackCategory.MapData, r.Category);
        Assert.Equal(FeedbackScreen.RoutePreview, r.Screen);
        Assert.Equal("SM-S921B", r.Context!.DeviceModel);
        Assert.Equal("\"wont_fix\"", JsonSerializer.Serialize(FeedbackStatus.WontFix, GimanoJson.Options));
    }

    [Fact]
    public void GitHub_issue_never_contains_user_id_contact_model_or_location()
    {
        var userId = Guid.NewGuid();
        var fb = new Feedback
        {
            UserId = userId, Category = FeedbackCategory.Route, Message = "Laluan salah di persimpangan\nbaris kedua", Rating = 2,
            Screen = FeedbackScreen.Navigation,
            Device = new DeviceInfo("0.2.0", 2, "ios", "iOS 26.1", null, "iPhone17,3", "Apple", null, "ms", "light", "live"),
            Lat = 3.12, Lng = 101.62, RouteId = "route-1",
            Screenshot = [1, 2, 3],
        };
        var (title, body, labels) = FeedbackIssueFormatter.Format(fb);
        Assert.Equal("[route] Laluan salah di persimpangan", title);
        Assert.Contains("0.2.0 (2)", body);
        Assert.Contains("iOS 26.1", body);
        Assert.DoesNotContain("iPhone17,3", body);
        Assert.DoesNotContain("Apple", body);
        Assert.DoesNotContain("3.12", body);
        Assert.DoesNotContain("101.62", body);
        Assert.DoesNotContain(userId.ToString(), body);
        Assert.Contains("not public", body);
        Assert.Contains("route", labels);
    }
}
