using System.Text.Json.Nodes;
using Gimano.Core.Contracts;
using Gimano.Core.Data;
using Gimano.Core.Domain;
using Microsoft.EntityFrameworkCore;

namespace Gimano.Core.Search;

/// <summary>Street search names are anchored to captured OSM ways, never a global text replacement.</summary>
public static class StreetCorrections
{
    public sealed class StreetSource
    {
        public string Name { get; set; } = "";
        public long[] WayIds { get; set; } = [];
        public double Lat { get; set; }
        public double Lng { get; set; }
    }

    public static async Task<StreetSource?> CaptureAsync(GimanoDbContext db, string id, CancellationToken ct)
    {
        var existing = await db.PlaceSuggestions.AsNoTracking().Where(s => s.PlaceId == id && s.Status == SuggestionStatus.Applied && s.StreetOriginalName != null)
            .OrderByDescending(s => s.AppliedAt).FirstOrDefaultAsync(ct);
        if (existing is not null)
        {
            var doc = await DocumentAsync(db, existing, ct);
            return doc is null ? null : new StreetSource { Name = existing.Changes.Name!, WayIds = existing.StreetWayIds,
                Lat = doc["location"]!["lat"]!.GetValue<double>(), Lng = doc["location"]!["lon"]!.GetValue<double>() };
        }
        return await db.Database.SqlQuery<StreetSource>($"""
            SELECT name AS "name", array_agg(DISTINCT osm_way_id) AS "way_ids", ST_Y(ST_ClosestPoint(ST_Collect(geom::geometry), ST_Centroid(ST_Collect(geom::geometry)))) AS "lat", ST_X(ST_ClosestPoint(ST_Collect(geom::geometry), ST_Centroid(ST_Collect(geom::geometry)))) AS "lng"
            FROM road_segments WHERE name IS NOT NULL
              AND 'st-' || ST_GeoHash(ST_StartPoint(geom::geometry), 4) || '-' || left(md5(name), 10) = {id}
            GROUP BY name
            """).FirstOrDefaultAsync(ct);
    }

    public static async Task<JsonObject?> DocumentAsync(GimanoDbContext db, PlaceSuggestion suggestion, CancellationToken ct)
    {
        var ids = suggestion.StreetWayIds;
        var source = await db.Database.SqlQuery<StreetSource>($"""
            SELECT ''::text AS "name", ARRAY[]::bigint[] AS "way_ids", ST_Y(pt) AS "lat", ST_X(pt) AS "lng"
            FROM (SELECT ST_ClosestPoint(ST_Collect(geom::geometry), ST_Centroid(ST_Collect(geom::geometry))) AS pt
                  FROM road_segments WHERE osm_way_id = ANY({ids})) s WHERE pt IS NOT NULL
            """).FirstOrDefaultAsync(ct);
        if (source is null) return null;
        var doc = SearchQueryBuilder.StreetDocument(suggestion.PlaceId, suggestion.Changes.Name!, source.Lat, source.Lng, "",
            Places.CountryResolver.Resolve(source.Lat, source.Lng));
        var oldNames = await db.PlaceSuggestions.AsNoTracking().Where(s => s.PlaceId == suggestion.PlaceId && s.Status == SuggestionStatus.Applied)
            .Select(s => s.StreetOriginalName).ToListAsync(ct);
        var aliases = string.Join(" ", oldNames.Where(n => n != null).Distinct());
        doc["aliases"] = aliases;
        doc["streetText"] = QueryParser.StreetKey(suggestion.Changes.Name + " " + aliases);
        doc["communityUpdated"] = true;
        return doc;
    }
}
