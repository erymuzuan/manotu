using System.Text.Json;
using Gimano.Api.Services;
using Gimano.Core.Contracts;
using Gimano.Core.Geo;
using Gimano.Core.Places;
using NetTopologySuite.Geometries;

namespace Gimano.Tests;

/// <summary>docs/api.md "Restricted areas": OSM tags, sensitive terms, the payload phones download.</summary>
public sealed class RestrictedAreaTests
{
    [Theory]
    [InlineData("landuse=military", true)]
    [InlineData("military=barracks", true)]
    [InlineData("military=airfield", true)]
    [InlineData("military=bunker", false)]
    [InlineData("military=danger_area", false)]
    [InlineData("power=plant", true)]
    [InlineData("power=substation;voltage=275000;132000", true)]
    [InlineData("power=substation;voltage=33000", false)]
    [InlineData("power=substation", false)]
    [InlineData("man_made=water_works", true)]
    [InlineData("amenity=prison", true)]
    [InlineData("aeroway=aerodrome", false)]
    [InlineData("amenity=police", false)]
    public void Osm_tags(string tags, bool restricted)
    {
        var d = new Dictionary<string, string>();
        foreach (var kv in tags.Split(';'))
        {
            var parts = kv.Split('=');
            if (parts.Length == 2) d[parts[0]] = parts[1];
            else d["voltage"] += ";" + kv;   // "275000;132000"
        }
        Assert.Equal(restricted, RestrictedAreaRules.IsRestricted(d));
    }

    [Theory]
    [InlineData("Dekat pintu belakang kem", true)]
    [InlineData("Pintu  Belakang", true)]
    [InlineData("Ada CCTV dan pengawal", true)]
    [InlineData("Kem Tentera Sungai Besi", true)]
    [InlineData("Restoran Pangkalan Ikan", true)]          // held for review, not rejected
    [InlineData("Women’s shelter", true)]
    [InlineData("TUDM", true)]
    [InlineData("Kedai Runcit Ah Seng", false)]
    [InlineData("Restoran Pengawalan Diet", false)]          // whole words only
    [InlineData("Mesin ATM Maybank", false)]
    [InlineData("Bus shelter Jalan SS2", false)]
    [InlineData(null, false)]
    public void Sensitive_terms_match_whole_words(string? text, bool expected) =>
        Assert.Equal(expected, RestrictedAreaRules.HasSensitiveTerm(text));

    [Fact]
    public void Sensitive_location_reports_hide_after_one()
    {
        Assert.Equal(1, RestrictedAreaRules.FlagsToHide(FlagReason.SensitiveLocation, 3));
        Assert.Equal(3, RestrictedAreaRules.FlagsToHide(FlagReason.Spam, 3));
        Assert.Equal("sensitive_location", GimanoJson.ToWire(FlagReason.SensitiveLocation));
    }

    [Fact]
    public void Payload_has_no_names_simplifies_and_is_versioned_by_content()
    {
        // A 100-point circle (~150 m radius) simplifies to fewer points but stays a closed ring.
        var circle = (Polygon)new Point(101.62, 3.12) { SRID = 4326 }.Buffer(0.0014, 25);
        var (body, version) = RestrictedAreaSnapshot.Build([circle]);
        using var doc = JsonDocument.Parse(body);
        var root = doc.RootElement;
        Assert.Equal(version, root.GetProperty("version").GetString());
        Assert.Equal(16, version.Length);
        Assert.Equal(100, root.GetProperty("blockM").GetDouble());
        Assert.Equal(300, root.GetProperty("reviewM").GetDouble());
        Assert.Contains("cctv", root.GetProperty("terms").EnumerateArray().Select(t => t.GetString()));
        Assert.Equal(["version", "blockM", "reviewM", "terms", "areas"], root.EnumerateObject().Select(p => p.Name));
        var ring = Assert.Single(root.GetProperty("areas").EnumerateArray()).EnumerateArray().Select(p => (p[0].GetDouble(), p[1].GetDouble())).ToList();
        Assert.InRange(ring.Count, 4, circle.ExteriorRing.NumPoints - 1);
        Assert.Equal(ring[0], ring[^1]);
        Assert.InRange(ring[0].Item1, 101.6, 101.7);   // [lng, lat]

        Assert.Equal(version, RestrictedAreaSnapshot.Build([circle]).Version);
        Assert.NotEqual(version, RestrictedAreaSnapshot.Build([]).Version);
    }
}
