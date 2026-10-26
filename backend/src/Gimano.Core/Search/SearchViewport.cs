using System.Globalization;
using System.Text.Json.Nodes;
using Gimano.Core.Geo;
using NetTopologySuite.Geometries;

namespace Gimano.Core.Search;

/// <summary>A transient visible-ground footprint; never stored or logged. lon,lat pairs separated by semicolons.</summary>
public sealed class SearchViewport
{
    public Polygon Polygon { get; }
    public GeoPoint Center => GeoPoint.From(Polygon.Centroid);
    private SearchViewport(Polygon polygon) => Polygon = polygon;
    public bool Contains(double lat, double lng) => Polygon.Covers(new GeoPoint(lat, lng).ToPoint());

    public static bool TryParse(string? value, out SearchViewport? viewport)
    {
        viewport = null;
        if (string.IsNullOrWhiteSpace(value) || value.Length > 600) return false;
        var parts = value.Split(';');
        if (parts.Length is < 3 or > 8) return false;
        var points = new List<Coordinate>();
        foreach (var part in parts)
        {
            var pair = part.Split(',');
            if (pair.Length != 2 || !double.TryParse(pair[0], NumberStyles.Float, CultureInfo.InvariantCulture, out var x)
                || !double.TryParse(pair[1], NumberStyles.Float, CultureInfo.InvariantCulture, out var y)
                || !double.IsFinite(x) || !double.IsFinite(y) || x is < -180 or > 180 || y is < -85 or > 85) return false;
            points.Add(new Coordinate(x, y));
        }
        if (!points[0].Equals2D(points[^1])) points.Add(points[0].Copy());
        if (points.Count < 4) return false;
        var polygon = GeoMath.Factory.CreatePolygon(points.ToArray());
        if (!polygon.IsValid || polygon.IsEmpty || polygon.Area <= 0 || polygon.EnvelopeInternal.Width > 180) return false;
        viewport = new SearchViewport(polygon);
        return true;
    }

    public JsonObject Constrain(JsonObject body)
    {
        var query = body["query"]?.DeepClone() ?? new JsonObject { ["match_all"] = new JsonObject() };
        body["query"] = new JsonObject
        {
            ["bool"] = new JsonObject
            {
                ["must"] = new JsonArray(query),
                ["filter"] = new JsonArray(new JsonObject
                {
                    ["geo_polygon"] = new JsonObject
                    {
                        ["location"] = new JsonObject
                        {
                            ["points"] = new JsonArray(Polygon.Coordinates.Select(c => (JsonNode)new JsonObject { ["lat"] = c.Y, ["lon"] = c.X }).ToArray())
                        }
                    }
                })
            }
        };
        return body;
    }
}
