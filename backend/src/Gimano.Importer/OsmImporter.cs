using System.Diagnostics;
using System.Text.Json;
using Gimano.Core.Contracts;
using Gimano.Core.Data;
using Gimano.Core.Domain;
using Gimano.Core.Geo;
using Gimano.Core.Places;
using Gimano.Core.Search;
using Gimano.Core.Tolls;
using Microsoft.EntityFrameworkCore;
using Microsoft.Extensions.Logging;
using Npgsql;
using NpgsqlTypes;
using OsmSharp;
using OsmSharp.Streams;
using OsmSharp.Tags;

namespace Gimano.Importer;

public sealed record ImportOptions(string PbfPath, bool Places = true, bool Roads = true, bool Search = true, bool RecreateIndex = true, bool DryRun = false, string? TollsCsv = null, bool EnrichOnly = false);

/// <summary>
/// Two-pass PBF import:
///  1. ways   → road ways (traffic model) and POI ways (need node coordinates for a centroid);
///  2. nodes  → POI nodes, plus coordinates for every node referenced in pass 1.
/// Then: COPY road segments and upsert places into Postgres, enrich missing addresses, bulk index OpenSearch.
/// </summary>
public sealed class OsmImporter(GimanoDbContext db, NpgsqlDataSource dataSource, PlaceSearchIndex index, ILogger<OsmImporter> logger)
{
    private sealed record RoadWay(long Id, long[] Nodes, string Highway, string? Name, string? Ref, bool Oneway, double FreeFlowKmh);
    private sealed record PoiWay(long Id, long[] Nodes, PlaceCategory Category, Dictionary<string, string> Tags);

    /// <summary>Closed ways that are inland water (lakes, reservoirs, river areas): used to reject community places "in water".</summary>
    internal static bool IsWaterArea(IReadOnlyDictionary<string, string> tags) =>
        tags.GetValueOrDefault("natural") == "water" || tags.GetValueOrDefault("waterway") == "riverbank"
        || tags.GetValueOrDefault("landuse") is "reservoir" or "basin";

    public async Task RunAsync(ImportOptions o, CancellationToken ct)
    {
        if (o.EnrichOnly && (o.DryRun || !o.Search || !o.RecreateIndex))
            throw new ArgumentException("Enrichment recovery requires a new search index and cannot be a dry run.");
        await using var rebuildLock = o.DryRun ? null : await SearchRebuildLock.AcquireAsync(dataSource, true, ct);
        var sw = Stopwatch.StartNew();
        if (!o.DryRun)
        {
            logger.LogInformation("Applying migrations…");
            await db.Database.MigrateAsync(ct);
        }

        if (o.EnrichOnly)
        {
            await PlaceCorrections.ReplayAsync(db, ct);
            await this.EnrichLocalitiesAsync(ct);
            await this.IndexSearchAsync(true, ct);
            logger.LogInformation("Enrichment recovery finished in {Elapsed}", sw.Elapsed);
            return;
        }
        if (o.Places || o.Roads)
        {
            if (!File.Exists(o.PbfPath)) throw new FileNotFoundException($"OSM extract not found: {o.PbfPath}. Run data/download-osm.sh first.");

            // ---- Pass 1: ways -------------------------------------------------
            var roads = new List<RoadWay>();
            var poiWays = new List<PoiWay>();
            var poiRelations = new List<(long Id, PlaceCategory Category, Dictionary<string, string> Tags, long[] OuterWays, long[] InnerWays)>();
            var waterWays = new List<(long Id, long[] Nodes)>();
            var restrictedWays = new List<(long Id, long[] Nodes)>();
            var restrictedRels = new List<(long Id, long[] OuterWays)>();
            var adminAreas = new List<(long Id, long LabelNode, Dictionary<string, string> Tags)>();
            var addrWays = new List<(long Id, long[] Nodes, Dictionary<string, string> Tags)>();
            var boundaries = new List<(long Id, string Name, int Level, long[] OuterWays, long[] InnerWays)>();
            var needed = new List<long>();
            await using (var fs = File.OpenRead(o.PbfPath))
            {
                foreach (var g in new PBFOsmStreamSource(fs))
                {
                    if (g.Type == OsmGeoType.Node) continue;
                    if (g.Type == OsmGeoType.Relation)
                    {
                        // Administrative areas (states, federal territories, districts) as searchable areas, placed at their
                        // label (or admin centre) node; full boundary geometry isn't needed for search.
                        if (o.Places && g.Tags is { Count: > 0 } && AdminArea((Relation)g) is { } a)
                        {
                            adminAreas.Add(a);
                            needed.Add(a.LabelNode);
                        }
                        if (o.Places && g.Tags is { Count: > 0 } && Boundary((Relation)g) is { } b) boundaries.Add(b);
                        if (o.Places && g.Tags is { Count: > 0 } && RestrictedRelation((Relation)g) is { } rr) restrictedRels.Add(rr);
                        if (o.Places && g.Tags is { Count: > 0 })
                        {
                            var relation = (Relation)g;
                            var relationTags = ToDict(g.Tags);
                            if (relationTags.GetValueOrDefault("type") == "multipolygon" && OsmCategoryMapper.Map(relationTags) is { } category
                                && OsmCategoryMapper.ShouldImport(category, relationTags))
                                poiRelations.Add((g.Id!.Value, category, relationTags,
                                    (relation.Members ?? []).Where(m => m.Type == OsmGeoType.Way && m.Role != "inner").Select(m => m.Id).ToArray(),
                                    (relation.Members ?? []).Where(m => m.Type == OsmGeoType.Way && m.Role == "inner").Select(m => m.Id).ToArray()));
                        }
                        continue;
                    }
                    var w = (Way)g;
                    if (w.Nodes is not { Length: >= 2 } || w.Tags is null || w.Tags.Count == 0) continue;
                    var tags = ToDict(w.Tags);

                    var highway = tags.GetValueOrDefault("highway");
                    if (o.Roads && RoadRules.IsRoad(highway) && tags.GetValueOrDefault("area") != "yes")
                    {
                        var (oneway, reversed) = RoadRules.Oneway(highway!, tags.GetValueOrDefault("oneway"), tags.GetValueOrDefault("junction"));
                        var nodes = reversed ? w.Nodes.Reverse().ToArray() : w.Nodes;
                        roads.Add(new RoadWay(w.Id!.Value, nodes, highway!, tags.GetValueOrDefault("name"), tags.GetValueOrDefault("ref"),
                            oneway, RoadRules.FreeFlowKmh(highway!, tags.GetValueOrDefault("maxspeed"))));
                        needed.AddRange(nodes);
                    }
                    if (o.Places && OsmCategoryMapper.Map(tags) is { } cat && OsmCategoryMapper.ShouldImport(cat, tags))
                    {
                        poiWays.Add(new PoiWay(w.Id!.Value, w.Nodes, cat, tags));
                        needed.AddRange(w.Nodes);
                    }
                    if (o.Places && IsAddress(tags))
                    {
                        addrWays.Add((w.Id!.Value, w.Nodes, tags));
                        needed.AddRange(w.Nodes);
                    }
                    if (o.Places && w.Nodes.Length >= 4 && w.Nodes[0] == w.Nodes[^1] && IsWaterArea(tags))
                    {
                        waterWays.Add((w.Id!.Value, w.Nodes));
                        needed.AddRange(w.Nodes);
                    }
                    if (o.Places && w.Nodes.Length >= 4 && w.Nodes[0] == w.Nodes[^1] && RestrictedAreaRules.IsRestricted(tags))
                    {
                        restrictedWays.Add((w.Id!.Value, w.Nodes));
                        needed.AddRange(w.Nodes);
                    }
                }
            }
            // ---- Pass 1b: outer ways of admin boundaries and restricted multipolygons (ways come before relations, so a second look) ----
            var boundaryWays = new Dictionary<long, long[]>();
            if (boundaries.Count > 0 || restrictedRels.Count > 0 || poiRelations.Count > 0)
            {
                var wanted = boundaries.SelectMany(b => b.OuterWays.Concat(b.InnerWays)).Concat(restrictedRels.SelectMany(r => r.OuterWays)).Concat(poiRelations.SelectMany(r => r.OuterWays.Concat(r.InnerWays))).ToHashSet();
                await using var fs = File.OpenRead(o.PbfPath);
                foreach (var g in new PBFOsmStreamSource(fs))
                {
                    if (g.Type == OsmGeoType.Node) continue;
                    if (g.Type == OsmGeoType.Relation) break;
                    if (g.Id is { } wid && wanted.Contains(wid) && ((Way)g).Nodes is { Length: >= 2 } wn)
                    {
                        boundaryWays[wid] = wn;
                        needed.AddRange(wn);
                    }
                }
                logger.LogInformation("Pass 1b: {Boundaries} admin boundaries, {Restricted} restricted multipolygons, {Ways} outer ways",
                    boundaries.Count, restrictedRels.Count, boundaryWays.Count);
            }
            var neededIds = needed.Distinct().Order().ToArray();
            needed = null!;
            logger.LogInformation("Pass 1: {Roads} road ways, {PoiWays} POI ways, {Nodes} referenced nodes ({Elapsed:n0}s)",
                roads.Count, poiWays.Count, neededIds.Length, sw.Elapsed.TotalSeconds);

            // ---- Pass 2: nodes ------------------------------------------------
            var lat = new double[neededIds.Length];
            var lng = new double[neededIds.Length];
            var places = new List<Place>();
            var addresses = new List<AddressPoint>();
            var entranceKinds = new Dictionary<long, string>();
            await using (var fs = File.OpenRead(o.PbfPath))
            {
                foreach (var g in new PBFOsmStreamSource(fs))
                {
                    if (g.Type != OsmGeoType.Node) break;
                    var n = (Node)g;
                    if (n.Latitude is not { } la || n.Longitude is not { } lo) continue;
                    var idx = Array.BinarySearch(neededIds, n.Id!.Value);
                    if (idx >= 0) { lat[idx] = la; lng[idx] = lo; }

                    if (o.Places && n.Tags is { Count: > 0 })
                    {
                        var tags = ToDict(n.Tags);
                        if (idx >= 0 && EntranceKind(tags) is { } ek) entranceKinds[n.Id.Value] = ek;
                        if (OsmCategoryMapper.Map(tags) is { } cat && OsmCategoryMapper.ShouldImport(cat, tags))
                            places.Add(ToPlace("n", n.Id.Value, cat, tags, la, lo));
                        if (IsAddress(tags)) addresses.Add(ToAddress("n" + n.Id.Value, tags, la, lo));
                    }
                }
            }
            logger.LogInformation("Pass 2: {Places} POI nodes ({Elapsed:n0}s)", places.Count, sw.Elapsed.TotalSeconds);

            bool TryCoord(long id, out GeoPoint p)
            {
                var i = Array.BinarySearch(neededIds, id);
                p = i >= 0 && (lat[i] != 0 || lng[i] != 0) ? new GeoPoint(lat[i], lng[i]) : default;
                return i >= 0 && (lat[i] != 0 || lng[i] != 0);
            }

            var entrances = new List<(string PlaceId, GeoPoint At, string Kind)>();
            var outlines = new List<(string PlaceId, List<GeoPoint> Ring)>();
            foreach (var w in poiWays)
            {
                var pts = w.Nodes.Select(id => TryCoord(id, out var p) ? p : (GeoPoint?)null).Where(p => p is not null).Select(p => p!.Value).ToList();
                if (pts.Count == 0) continue;
                // Closed ways repeat the first node; drop it so the centroid isn't biased.
                if (pts.Count > 1 && pts[0] == pts[^1]) pts.RemoveAt(pts.Count - 1);
                places.Add(ToPlace("w", w.Id, w.Category, w.Tags, pts.Average(p => p.Lat), pts.Average(p => p.Lng)));
                // Arriving at the entrance: an OSM entrance node on the outline, else (closed outlines) the outline point
                // nearest the closest named road, worked out in SQL once the roads are in.
                if (BestEntrance(w.Nodes, entranceKinds) is { } en && TryCoord(en, out var ep))
                    entrances.Add(("w" + w.Id, ep, entranceKinds[en]));
                else if (pts.Count >= 3 && w.Nodes[0] == w.Nodes[^1])
                    outlines.Add(("w" + w.Id, pts));
            }

            foreach (var relation in poiRelations)
            {
                var shape = AssemblePolygon(relation.OuterWays, relation.InnerWays, boundaryWays, TryCoord);
                if (shape is null) continue;
                var point = shape.PointOnSurface;
                places.Add(ToPlace("r", relation.Id, relation.Category, relation.Tags, point.Y, point.X));
            }

            foreach (var w in addrWays)
            {
                var pts = w.Nodes.Select(id => TryCoord(id, out var p) ? p : (GeoPoint?)null).OfType<GeoPoint>().ToList();
                if (pts.Count == 0) continue;
                if (pts.Count > 1 && pts[0] == pts[^1]) pts.RemoveAt(pts.Count - 1);
                addresses.Add(ToAddress("w" + w.Id, w.Tags, pts.Average(p => p.Lat), pts.Average(p => p.Lng)));
            }
            logger.LogInformation("Addresses: {Count} OSM house addresses", addresses.Count);

            var areaNodes = places.Where(p => p.Category == PlaceCategory.Area).ToList();
            foreach (var a in adminAreas)
                if (TryCoord(a.LabelNode, out var p))
                {
                    var admin = ToPlace("r", a.Id, PlaceCategory.Area, a.Tags, p.Lat, p.Lng);
                    // "Putrajaya" the federal territory and "Putrajaya" the city are one search result: keep the place node
                    // (better centre) with the higher popularity of the two.
                    if (MergeAdminInto(areaNodes, admin) is { } same)
                    {
                        same.Popularity = Math.Max(same.Popularity, admin.Popularity);
                        foreach (var t in SearchAliases.AreaNameTags)
                            if (admin.Tags.TryGetValue(t, out var v) && !same.Tags.ContainsKey(t)) same.Tags[t] = v;
                        continue;
                    }
                    places.Add(admin);
                }
            logger.LogInformation("Areas: {Areas} named places/admin areas", places.Count(p => p.Category == PlaceCategory.Area));

            if (o.DryRun)
            {
                var segments = roads.Sum(r => Chunk(r.Nodes, TryCoord).Count());
                logger.LogInformation("Dry run: {Places} places ({ByCountry}), {Segments} road segments. Top categories: {Cats}",
                    places.Count,
                    string.Join(", ", places.GroupBy(p => p.Country).Select(g => $"{g.Key}={g.Count()}")),
                    segments,
                    string.Join(", ", places.GroupBy(p => p.Category).OrderByDescending(g => g.Count()).Take(12).Select(g => $"{g.Key}={g.Count()}")));
                logger.LogInformation("Dry run: {Ways} restricted closed ways, {Relations} restricted multipolygons ({Rings} rings)",
                    restrictedWays.Count, restrictedRels.Count,
                    restrictedRels.Sum(r => AssembleRings(r.OuterWays.Where(boundaryWays.ContainsKey).Select(id => boundaryWays[id])).Count));
                foreach (var p in places.Where(p => p.Name.Contains("Petronas", StringComparison.OrdinalIgnoreCase)).Take(5))
                    logger.LogInformation("  sample: {Id} {Name} [{Cat}] {Country} '{Address}' ({Lat:F2},{Lng:F2})", p.Id, p.Name, p.Category, p.Country, p.Address, p.Location.Y, p.Location.X);
                return;
            }
            if (o.Places) await WriteWaterAsync(waterWays, TryCoord, ct);
            if (o.Roads) await WriteRoadsAsync(roads, TryCoord, ct);
            if (o.Places) await UpsertPlacesAsync(places, ct);
            if (o.Places) await WriteAddressesAsync(addresses, ct);
            if (o.Places) await WriteBoundariesAsync(boundaries, boundaryWays, TryCoord, ct);
            if (o.Places) await WriteRestrictedAsync(restrictedWays, restrictedRels, boundaryWays, TryCoord, ct);
            if (o.Places) await WriteEntrancesAsync(entrances, outlines, ct);
            else if (o.Roads) await DropRestrictedRoadsAsync(ct);
            if (o.Places && o.Roads) await EnrichAddressesAsync(ct);
            if (o.Places) await PlaceCorrections.ReplayAsync(db, ct);
            if (o.Places) await EnrichLocalitiesAsync(ct);
        }

        if (!o.DryRun && o.TollsCsv is not null) await ImportTollRatesAsync(o.TollsCsv, ct);
        if (o.Search) await IndexSearchAsync(o.RecreateIndex, ct);
        logger.LogInformation("Import finished in {Elapsed}", sw.Elapsed);
    }

    private delegate bool CoordLookup(long id, out GeoPoint p);

    internal static Place ToPlace(string type, long id, PlaceCategory cat, IReadOnlyDictionary<string, string> tags, double lat, double lng) => new()
    {
        Id = type + id,
        Name = Truncate(OsmCategoryMapper.DisplayName(cat, tags), 200),
        Category = cat,
        Brand = OsmCategoryMapper.Brand(tags),
        Address = Truncate(cat == PlaceCategory.Area ? OsmCategoryMapper.AreaAddress(tags) : OsmCategoryMapper.BuildAddress(tags), 300),
        Location = new GeoPoint(lat, lng).ToPoint(),
        Country = CountryResolver.Resolve(lat, lng, tags.GetValueOrDefault("addr:country")),
        Phone = tags.GetValueOrDefault("phone") ?? tags.GetValueOrDefault("contact:phone"),
        Website = tags.GetValueOrDefault("website") ?? tags.GetValueOrDefault("contact:website"),
        OpeningHours = tags.GetValueOrDefault("opening_hours"),
        Amenities = OsmCategoryMapper.Amenities(tags).ToList(),
        Tags = OsmCategoryMapper.KeepTags(tags),
        OsmType = type switch { "n" => "node", "w" => "way", _ => "relation" },
        OsmId = id,
        Popularity = OsmCategoryMapper.Popularity(cat, tags),
    };

    internal static Place? MergeAdminInto(IEnumerable<Place> areaNodes, Place admin) =>
        areaNodes.FirstOrDefault(n => string.Equals(n.Name, admin.Name, StringComparison.OrdinalIgnoreCase)
            && GeoMath.HaversineM(n.Location.Y, n.Location.X, admin.Location.Y, admin.Location.X) <= 15_000);

    internal static (long Id, long LabelNode, Dictionary<string, string> Tags)? AdminArea(Relation r)
    {
        var tags = ToDict(r.Tags);
        if (tags.GetValueOrDefault("boundary") != "administrative" || !tags.TryGetValue("name", out var name) || name.Length == 0) return null;
        if (!int.TryParse(tags.GetValueOrDefault("admin_level"), out var level) || level is < 4 or > 6) return null;
        var members = r.Members ?? [];
        var label = members.FirstOrDefault(m => m.Type == OsmGeoType.Node && m.Role == "label")
                    ?? members.FirstOrDefault(m => m.Type == OsmGeoType.Node && m.Role == "admin_centre");
        if (label is null) return null;
        tags["place"] = "admin";
        tags["gimano:admin_level"] = level.ToString(System.Globalization.CultureInfo.InvariantCulture);
        return (r.Id!.Value, label.Id, tags);
    }

    private static string Truncate(string s, int max) => s.Length <= max ? s : s[..max];

    private static Dictionary<string, string> ToDict(TagsCollectionBase tags)
    {
        var d = new Dictionary<string, string>(tags.Count);
        foreach (var t in tags) d[t.Key] = t.Value;
        return d;
    }

    private async Task WriteRoadsAsync(List<RoadWay> roads, CoordLookup coord, CancellationToken ct)
    {
        await using var conn = await dataSource.OpenConnectionAsync(ct);
        await using (var trunc = new NpgsqlCommand("TRUNCATE road_segments RESTART IDENTITY; TRUNCATE segment_speeds; TRUNCATE jams;", conn))
            await trunc.ExecuteNonQueryAsync(ct);

        long count = 0;
        await using (var writer = await conn.BeginBinaryImportAsync(
            "COPY road_segments (osm_way_id, seq, name, ref, highway, oneway, free_flow_kmh, length_m, from_node, to_node, geom) FROM STDIN (FORMAT BINARY)", ct))
        {
            foreach (var road in roads)
            {
                var seq = 0;
                foreach (var chunk in Chunk(road.Nodes, coord))
                {
                    await writer.StartRowAsync(ct);
                    await writer.WriteAsync(road.Id, NpgsqlDbType.Bigint, ct);
                    await writer.WriteAsync(seq++, NpgsqlDbType.Integer, ct);
                    await WriteNullableAsync(writer, road.Name, ct);
                    await WriteNullableAsync(writer, road.Ref, ct);
                    await writer.WriteAsync(road.Highway, NpgsqlDbType.Varchar, ct);
                    await writer.WriteAsync(road.Oneway, NpgsqlDbType.Boolean, ct);
                    await writer.WriteAsync(road.FreeFlowKmh, NpgsqlDbType.Double, ct);
                    await writer.WriteAsync(chunk.LengthM, NpgsqlDbType.Double, ct);
                    await writer.WriteAsync(chunk.FromNode, NpgsqlDbType.Bigint, ct);
                    await writer.WriteAsync(chunk.ToNode, NpgsqlDbType.Bigint, ct);
                    await writer.WriteAsync(GeoMath.ToLineString(chunk.Points), NpgsqlDbType.Geography, ct);
                    count++;
                }
            }
            await writer.CompleteAsync(ct);
        }
        await using (var analyze = new NpgsqlCommand("ANALYZE road_segments;", conn)) await analyze.ExecuteNonQueryAsync(ct);
        logger.LogInformation("Wrote {Count} road segments from {Ways} ways", count, roads.Count);
    }

    private async Task WriteWaterAsync(List<(long Id, long[] Nodes)> ways, CoordLookup coord, CancellationToken ct)
    {
        await using var conn = await dataSource.OpenConnectionAsync(ct);
        await using (var trunc = new NpgsqlCommand("TRUNCATE water_areas RESTART IDENTITY;", conn)) await trunc.ExecuteNonQueryAsync(ct);
        var count = 0;
        await using (var writer = await conn.BeginBinaryImportAsync("COPY water_areas (osm_way_id, geom) FROM STDIN (FORMAT BINARY)", ct))
        {
            foreach (var (id, nodes) in ways)
            {
                var pts = new List<NetTopologySuite.Geometries.Coordinate>(nodes.Length);
                foreach (var n in nodes) if (coord(n, out var p)) pts.Add(new(p.Lng, p.Lat));
                if (pts.Count < 4 || !pts[0].Equals2D(pts[^1])) continue;
                var poly = GeoMath.Factory.CreatePolygon(pts.ToArray());
                if (!poly.IsValid) continue; // self-intersecting outlines: skip rather than misclassify land
                if (!poly.Shell.IsCCW) poly = (NetTopologySuite.Geometries.Polygon)poly.Reverse();
                await writer.StartRowAsync(ct);
                await writer.WriteAsync(id, NpgsqlDbType.Bigint, ct);
                await writer.WriteAsync(poly, NpgsqlDbType.Geography, ct);
                count++;
            }
            await writer.CompleteAsync(ct);
        }
        logger.LogInformation("Wrote {Count} inland water areas", count);
    }

    /// <summary>admin_level 4–8 boundary relations with a name, and their outer member ways.</summary>
    internal static (long Id, string Name, int Level, long[] OuterWays, long[] InnerWays)? Boundary(Relation r)
    {
        var tags = ToDict(r.Tags);
        if (tags.GetValueOrDefault("boundary") != "administrative" || !tags.TryGetValue("name", out var name) || name.Length == 0) return null;
        if (!int.TryParse(tags.GetValueOrDefault("admin_level"), out var level) || level is < 4 or > 8) return null;
        var outers = (r.Members ?? []).Where(m => m.Type == OsmGeoType.Way && m.Role is "outer" or "" or null).Select(m => m.Id).ToArray();
        return outers.Length == 0 ? null : (r.Id!.Value, name, level, outers, (r.Members ?? []).Where(m => m.Type == OsmGeoType.Way && m.Role == "inner").Select(m => m.Id).ToArray());
    }

    /// <summary>OSM entrance=* (not exits, emergency-only or "no"); the value is kept to rank and word it ("main" first).</summary>
    internal static string? EntranceKind(IReadOnlyDictionary<string, string> tags) =>
        tags.TryGetValue("entrance", out var v) && v.Length is > 0 and <= 16 && v is not ("exit" or "emergency" or "no" or "staircase") ? v : null;

    /// <summary>The best entrance node of an outline: main, then yes, then any other, then service.</summary>
    internal static long? BestEntrance(long[] nodes, IReadOnlyDictionary<long, string> kinds)
    {
        static int Rank(string k) => k switch { "main" => 0, "yes" => 1, "service" => 3, _ => 2 };
        long? best = null;
        var bestRank = int.MaxValue;
        foreach (var n in nodes)
            if (kinds.TryGetValue(n, out var k) && Rank(k) < bestRank) { best = n; bestRank = Rank(k); }
        return best;
    }

    private const string OutlineEntrancesSql = @"
        INSERT INTO place_entrances (place_id, location, source, kind)
        SELECT o.place_id, ST_ClosestPoint(ST_Boundary(o.geom::geometry), r.g)::geography, 'outline', NULL
        FROM tmp_outlines o
        JOIN places p ON p.id = o.place_id
        CROSS JOIN LATERAL (
            SELECT s.geom::geometry AS g, s.geom AS geog FROM road_segments s
            WHERE s.name IS NOT NULL AND s.highway NOT IN ('service', 'track', 'footway', 'path', 'cycleway', 'pedestrian', 'steps', 'living_street')
              AND ST_DWithin(s.geom, o.geom, 150)
            ORDER BY s.geom <-> o.geom LIMIT 1) r
        WHERE ST_Distance(p.location, r.geog) > 25
        ON CONFLICT (place_id) DO NOTHING;
        DROP TABLE tmp_outlines;
        ANALYZE place_entrances;";

    /// <summary>
    /// place_entrances: OSM entrance nodes, then for outlines without one, the outline point nearest the closest named
    /// drivable road within 150 m, when the place's pin is more than 25 m from that road (else the pin is good enough).
    /// </summary>
    private async Task WriteEntrancesAsync(List<(string PlaceId, GeoPoint At, string Kind)> entrances, List<(string PlaceId, List<GeoPoint> Ring)> outlines,
        CancellationToken ct)
    {
        await using var conn = await dataSource.OpenConnectionAsync(ct);
        await using (var trunc = new NpgsqlCommand("TRUNCATE place_entrances; CREATE TEMP TABLE tmp_outlines (place_id text PRIMARY KEY, geom geography(polygon, 4326));", conn))
            await trunc.ExecuteNonQueryAsync(ct);
        await using (var writer = await conn.BeginBinaryImportAsync("COPY place_entrances (place_id, location, source, kind) FROM STDIN (FORMAT BINARY)", ct))
        {
            foreach (var e in entrances.DistinctBy(e => e.PlaceId))
            {
                await writer.StartRowAsync(ct);
                await writer.WriteAsync(e.PlaceId, NpgsqlDbType.Text, ct);
                await writer.WriteAsync(e.At.ToPoint(), NpgsqlDbType.Geography, ct);
                await writer.WriteAsync("osm_entrance", NpgsqlDbType.Text, ct);
                await writer.WriteAsync(e.Kind, NpgsqlDbType.Text, ct);
            }
            await writer.CompleteAsync(ct);
        }
        await using (var writer = await conn.BeginBinaryImportAsync("COPY tmp_outlines (place_id, geom) FROM STDIN (FORMAT BINARY)", ct))
        {
            foreach (var (id, ring) in outlines.DistinctBy(x => x.PlaceId))
            {
                var coords = ring.Select(p => new NetTopologySuite.Geometries.Coordinate(p.Lng, p.Lat)).Append(new(ring[0].Lng, ring[0].Lat)).ToArray();
                var poly = GeoMath.Factory.CreatePolygon(coords);
                if (!poly.IsValid) continue;
                if (!poly.Shell.IsCCW) poly = (NetTopologySuite.Geometries.Polygon)poly.Reverse();
                await writer.StartRowAsync(ct);
                await writer.WriteAsync(id, NpgsqlDbType.Text, ct);
                await writer.WriteAsync(poly, NpgsqlDbType.Geography, ct);
            }
            await writer.CompleteAsync(ct);
        }
        await using (var cmd = new NpgsqlCommand(OutlineEntrancesSql, conn) { CommandTimeout = 1800 })
            await cmd.ExecuteNonQueryAsync(ct);
        await using var count = new NpgsqlCommand("SELECT source, count(*) FROM place_entrances GROUP BY source", conn);
        await using var rd = await count.ExecuteReaderAsync(ct);
        while (await rd.ReadAsync(ct)) logger.LogInformation("Place entrances: {Count} {Source}", rd.GetInt64(1), rd.GetString(0));
    }

    /// <summary>Restricted multipolygon relations (RestrictedAreaRules.IsRestricted) and their outer member ways.</summary>
    internal static (long Id, long[] OuterWays)? RestrictedRelation(Relation r)
    {
        var tags = ToDict(r.Tags);
        if (tags.GetValueOrDefault("type") != "multipolygon" || !RestrictedAreaRules.IsRestricted(tags)) return null;
        var outers = (r.Members ?? []).Where(m => m.Type == OsmGeoType.Way && m.Role is "outer" or "" or null).Select(m => m.Id).ToArray();
        return outers.Length == 0 ? null : (r.Id!.Value, outers);
    }

    /// <summary>
    /// Rebuilds the OSM rows of restricted_areas (curated rows are kept), then drops road segments inside public areas so
    /// no traffic speeds are computed there from anonymous pings (docs/api.md "Restricted areas").
    /// </summary>
    private async Task WriteRestrictedAsync(List<(long Id, long[] Nodes)> closedWays, List<(long Id, long[] OuterWays)> relations,
        Dictionary<long, long[]> ways, CoordLookup coord, CancellationToken ct)
    {
        var rings = closedWays.Select(w => (OsmId: w.Id, Nodes: (IReadOnlyList<long>)w.Nodes))
            .Concat(relations.DistinctBy(r => r.Id).SelectMany(r =>
                AssembleRings(r.OuterWays.Where(ways.ContainsKey).Select(id => ways[id])).Select(ring => (OsmId: -r.Id, Nodes: (IReadOnlyList<long>)ring))));
        await using var conn = await dataSource.OpenConnectionAsync(ct);
        await using (var del = new NpgsqlCommand("DELETE FROM restricted_areas WHERE NOT curated;", conn)) await del.ExecuteNonQueryAsync(ct);
        var count = 0;
        await using (var writer = await conn.BeginBinaryImportAsync("COPY restricted_areas (osm_id, curated, \"public\", geom) FROM STDIN (FORMAT BINARY)", ct))
        {
            foreach (var (osmId, nodes) in rings)
            {
                var pts = new List<NetTopologySuite.Geometries.Coordinate>(nodes.Count);
                foreach (var n in nodes) if (coord(n, out var p)) pts.Add(new(p.Lng, p.Lat));
                if (pts.Count < 4 || !pts[0].Equals2D(pts[^1])) continue;
                var poly = GeoMath.Factory.CreatePolygon(pts.ToArray());
                if (!poly.IsValid) poly = poly.Buffer(0) as NetTopologySuite.Geometries.Polygon ?? poly;
                if (!poly.IsValid || poly.IsEmpty) continue;
                if (!poly.Shell.IsCCW) poly = (NetTopologySuite.Geometries.Polygon)poly.Reverse();
                await writer.StartRowAsync(ct);
                await writer.WriteAsync(osmId, NpgsqlDbType.Bigint, ct);
                await writer.WriteAsync(false, NpgsqlDbType.Boolean, ct);
                await writer.WriteAsync(true, NpgsqlDbType.Boolean, ct);
                await writer.WriteAsync(poly, NpgsqlDbType.Geography, ct);
                count++;
            }
            await writer.CompleteAsync(ct);
        }
        logger.LogInformation("Wrote {Count} restricted areas", count);
        await DropRestrictedRoadsAsync(ct);
        await using var hide = new NpgsqlCommand("""
            DELETE FROM places p USING restricted_areas r WHERE ST_DWithin(p.location, r.geom, 100);
            DELETE FROM street_addresses p USING restricted_areas r WHERE ST_DWithin(p.location, r.geom, 100);
            """, conn) { CommandTimeout = 1800 };
        await hide.ExecuteNonQueryAsync(ct);
    }

    private async Task DropRestrictedRoadsAsync(CancellationToken ct)
    {
        await using var conn = await dataSource.OpenConnectionAsync(ct);
        await using var cmd = new NpgsqlCommand(
            "DELETE FROM road_segments s USING restricted_areas r WHERE r.\"public\" AND ST_Intersects(s.geom, r.geom);", conn) { CommandTimeout = 600 };
        logger.LogInformation("Dropped {Count} road segments inside restricted areas", await cmd.ExecuteNonQueryAsync(ct));
    }

    /// <summary>Joins way node lists end-to-end into closed rings (reversing ways as needed); open leftovers are dropped.</summary>
    internal static List<List<long>> AssembleRings(IEnumerable<long[]> ways)
    {
        var pending = ways.Where(w => w.Length >= 2).Select(w => w.ToList()).ToList();
        var rings = new List<List<long>>();
        while (pending.Count > 0)
        {
            var ring = pending[0];
            pending.RemoveAt(0);
            var guard = 0;
            while (ring[0] != ring[^1] && guard++ < 100_000)
            {
                var end = ring[^1];
                var i = pending.FindIndex(w => w[0] == end || w[^1] == end);
                if (i < 0) break;
                var next = pending[i];
                pending.RemoveAt(i);
                if (next[^1] == end) next.Reverse();
                ring.AddRange(next.Skip(1));
            }
            if (ring.Count >= 4 && ring[0] == ring[^1]) rings.Add(ring);
        }
        return rings;
    }

    private static NetTopologySuite.Geometries.MultiPolygon? AssemblePolygon(long[] outerIds, long[] innerIds,
        Dictionary<long, long[]> ways, CoordLookup coord)
    {
        if (outerIds.Concat(innerIds).Any(id => !ways.ContainsKey(id))) return null;
        List<NetTopologySuite.Geometries.LinearRing> Rings(long[] ids)
        {
            var result = new List<NetTopologySuite.Geometries.LinearRing>();
            foreach (var nodes in AssembleRings(ids.Select(id => ways[id])))
            {
                var points = new List<NetTopologySuite.Geometries.Coordinate>();
                foreach (var node in nodes)
                {
                    if (!coord(node, out var at)) return [];
                    points.Add(new(at.Lng, at.Lat));
                }
                var ring = GeoMath.Factory.CreateLinearRing(points.ToArray());
                if (!ring.IsValid) return [];
                result.Add(ring);
            }
            return result;
        }
        var shells = Rings(outerIds); var holes = Rings(innerIds);
        if (shells.Count == 0 || (innerIds.Length > 0 && holes.Count == 0)) return null;
        var polygons = new List<NetTopologySuite.Geometries.Polygon>();
        foreach (var shell in shells)
        {
            var outside = GeoMath.Factory.CreatePolygon(shell);
            var inside = holes.Where(h => outside.Covers(GeoMath.Factory.CreatePolygon(h))).ToArray();
            var polygon = GeoMath.Factory.CreatePolygon(shell, inside);
            if (!polygon.IsValid) return null;
            if (!polygon.Shell.IsCCW) polygon = (NetTopologySuite.Geometries.Polygon)polygon.Reverse();
            polygons.Add(polygon);
        }
        var multi = GeoMath.Factory.CreateMultiPolygon(polygons.ToArray());
        return multi.IsValid ? multi : null;
    }

    private async Task WriteBoundariesAsync(List<(long Id, string Name, int Level, long[] OuterWays, long[] InnerWays)> boundaries, Dictionary<long, long[]> ways,
        CoordLookup coord, CancellationToken ct)
    {
        await using var conn = await dataSource.OpenConnectionAsync(ct);
        await using (var trunc = new NpgsqlCommand("TRUNCATE admin_areas;", conn)) await trunc.ExecuteNonQueryAsync(ct);
        var count = 0;
        await using (var writer = await conn.BeginBinaryImportAsync("COPY admin_areas (id, name, admin_level, geom) FROM STDIN (FORMAT BINARY)", ct))
        {
            foreach (var b in boundaries.DistinctBy(b => b.Id))
            {
                var shape = AssemblePolygon(b.OuterWays, b.InnerWays, ways, coord);
                if (shape is null) continue;
                await writer.StartRowAsync(ct);
                await writer.WriteAsync(b.Id, NpgsqlDbType.Bigint, ct);
                await writer.WriteAsync(Truncate(b.Name, 200), NpgsqlDbType.Text, ct);
                await writer.WriteAsync(b.Level, NpgsqlDbType.Integer, ct);
                await writer.WriteAsync(shape, NpgsqlDbType.Geography, ct);
                count++;
            }
            await writer.CompleteAsync(ct);
        }
        logger.LogInformation("Wrote {Count} admin boundaries", count);
    }

    internal static bool IsAddress(IReadOnlyDictionary<string, string> tags) =>
        ImportEligibility.IncludeAddress(tags) && tags.TryGetValue("addr:housenumber", out var hn) && hn.Length is > 0 and <= 40
        && tags.TryGetValue("addr:street", out var st) && st.Length is > 0 and <= 200;

    internal static AddressPoint ToAddress(string id, IReadOnlyDictionary<string, string> tags, double lat, double lng) => new(
        id, tags["addr:housenumber"].Trim(), tags["addr:street"].Trim(),
        tags.GetValueOrDefault("addr:postcode") is { Length: > 0 and <= 12 } pc ? pc.Trim() : null,
        tags.GetValueOrDefault("addr:city") is { Length: > 0 and <= 100 } city ? city.Trim() : null,
        lat, lng, CountryResolver.Resolve(lat, lng, tags.GetValueOrDefault("addr:country")));

    private async Task WriteAddressesAsync(List<AddressPoint> addresses, CancellationToken ct)
    {
        await using var conn = await dataSource.OpenConnectionAsync(ct);
        await using (var trunc = new NpgsqlCommand("TRUNCATE street_addresses;", conn)) await trunc.ExecuteNonQueryAsync(ct);
        await using (var writer = await conn.BeginBinaryImportAsync(
            "COPY street_addresses (id, house_number, street, postcode, city, country, location) FROM STDIN (FORMAT BINARY)", ct))
        {
            foreach (var a in addresses.DistinctBy(a => a.Id))
            {
                await writer.StartRowAsync(ct);
                await writer.WriteAsync(a.Id, NpgsqlDbType.Text, ct);
                await writer.WriteAsync(a.HouseNumber, NpgsqlDbType.Text, ct);
                await writer.WriteAsync(a.Street, NpgsqlDbType.Text, ct);
                await WriteNullableAsync(writer, a.Postcode, ct);
                await WriteNullableAsync(writer, a.City, ct);
                await writer.WriteAsync(a.Country, NpgsqlDbType.Text, ct);
                await writer.WriteAsync(new GeoPoint(a.Lat, a.Lng).ToPoint(), NpgsqlDbType.Geography, ct);
            }
            await writer.CompleteAsync(ct);
        }
        logger.LogInformation("Wrote {Count} street addresses", addresses.Count);
    }

    private static async Task WriteNullableAsync(NpgsqlBinaryImporter w, string? s, CancellationToken ct)
    {
        if (s is null) await w.WriteNullAsync(ct);
        else await w.WriteAsync(s, NpgsqlDbType.Text, ct);
    }

    internal readonly record struct RoadChunk(long FromNode, long ToNode, List<GeoPoint> Points, double LengthM);

    /// <summary>Splits a way into ≈300 m chunks. Chunks share their boundary node.</summary>
    private static IEnumerable<RoadChunk> Chunk(long[] nodes, CoordLookup coord)
    {
        var pts = new List<GeoPoint>();
        long from = 0;
        long last = 0;
        double len = 0;
        foreach (var id in nodes)
        {
            if (!coord(id, out var p)) continue;
            if (pts.Count == 0) { from = id; pts.Add(p); last = id; continue; }
            if (p == pts[^1]) continue;
            len += GeoMath.HaversineM(pts[^1], p);
            pts.Add(p);
            last = id;
            if (len >= RoadRules.ChunkLengthM)
            {
                yield return new RoadChunk(from, id, pts, len);
                pts = [p];
                from = id;
                len = 0;
            }
        }
        if (pts.Count >= 2) yield return new RoadChunk(from, last, pts, len);
    }

    private async Task UpsertPlacesAsync(List<Place> places, CancellationToken ct)
    {
        // De-duplicate ids (shouldn't happen, but a broken extract must not abort the import).
        places = places.GroupBy(p => p.Id).Select(g => g.First()).ToList();
        await using var conn = await dataSource.OpenConnectionAsync(ct);
        await using (var cmd = new NpgsqlCommand("CREATE TEMP TABLE places_import (LIKE places INCLUDING DEFAULTS) ON COMMIT DROP;", conn))
        {
            await using var tx = await conn.BeginTransactionAsync(ct);
            cmd.Transaction = tx;
            await cmd.ExecuteNonQueryAsync(ct);

            await using (var w = await conn.BeginBinaryImportAsync(
                "COPY places_import (id, name, category, brand, address, location, country, phone, website, opening_hours, amenities, tags, osm_type, osm_id, popularity, updated_at) FROM STDIN (FORMAT BINARY)", ct))
            {
                var now = DateTimeOffset.UtcNow;
                foreach (var p in places)
                {
                    await w.StartRowAsync(ct);
                    await w.WriteAsync(p.Id, NpgsqlDbType.Varchar, ct);
                    await w.WriteAsync(p.Name, NpgsqlDbType.Text, ct);
                    await w.WriteAsync(p.Category.ToString(), NpgsqlDbType.Varchar, ct);
                    await WriteNullableAsync(w, p.Brand, ct);
                    await w.WriteAsync(p.Address, NpgsqlDbType.Text, ct);
                    await w.WriteAsync(p.Location, NpgsqlDbType.Geography, ct);
                    await w.WriteAsync(p.Country, NpgsqlDbType.Varchar, ct);
                    await WriteNullableAsync(w, p.Phone, ct);
                    await WriteNullableAsync(w, p.Website, ct);
                    await WriteNullableAsync(w, p.OpeningHours, ct);
                    await w.WriteAsync(p.Amenities.ToArray(), NpgsqlDbType.Array | NpgsqlDbType.Text, ct);
                    await w.WriteAsync(JsonSerializer.Serialize(p.Tags), NpgsqlDbType.Jsonb, ct);
                    await w.WriteAsync(p.OsmType, NpgsqlDbType.Varchar, ct);
                    await w.WriteAsync(p.OsmId, NpgsqlDbType.Bigint, ct);
                    await w.WriteAsync(p.Popularity, NpgsqlDbType.Double, ct);
                    await w.WriteAsync(now, NpgsqlDbType.TimestampTz, ct);
                }
                await w.CompleteAsync(ct);
            }

            const string upsert = """
                INSERT INTO places AS p (id, name, category, brand, address, location, country, phone, website, opening_hours, amenities, tags, osm_type, osm_id, popularity, updated_at)
                SELECT id, name, category, brand, address, location, country, phone, website, opening_hours, amenities, tags, osm_type, osm_id, popularity, updated_at FROM places_import
                ON CONFLICT (id) DO UPDATE SET
                  name = EXCLUDED.name, category = EXCLUDED.category, brand = EXCLUDED.brand, address = EXCLUDED.address,
                  location = EXCLUDED.location, country = EXCLUDED.country, phone = EXCLUDED.phone, website = EXCLUDED.website,
                  opening_hours = EXCLUDED.opening_hours, amenities = EXCLUDED.amenities, tags = EXCLUDED.tags,
                  osm_type = EXCLUDED.osm_type, osm_id = EXCLUDED.osm_id, popularity = EXCLUDED.popularity, updated_at = EXCLUDED.updated_at;
                DELETE FROM places WHERE id NOT IN (SELECT id FROM places_import);
                """;
            await using (var up = new NpgsqlCommand(upsert, conn, tx)) await up.ExecuteNonQueryAsync(ct);
            await tx.CommitAsync(ct);
        }
        await using (var analyze = new NpgsqlCommand("ANALYZE places;", conn)) await analyze.ExecuteNonQueryAsync(ct);
        logger.LogInformation("Upserted {Count} places", places.Count);
    }

    /// <summary>Places without addr:* tags get the nearest named road (≤ 150 m) as their address.</summary>
    private async Task EnrichAddressesAsync(CancellationToken ct)
    {
        const string sql = """
            UPDATE places p SET address = sub.name
            FROM (
              SELECT p2.id,
                     (SELECT COALESCE(s.name, s.ref) FROM road_segments s
                      WHERE (s.name IS NOT NULL OR s.ref IS NOT NULL) AND ST_DWithin(s.geom, p2.location, 150)
                      ORDER BY s.geom <-> p2.location LIMIT 1) AS name
              FROM places p2
              WHERE p2.address = ''
            ) sub
            WHERE p.id = sub.id AND sub.name IS NOT NULL;
            """;
        await using var conn = await dataSource.OpenConnectionAsync(ct);
        await using var cmd = new NpgsqlCommand(sql, conn) { CommandTimeout = 1800 };
        var n = await cmd.ExecuteNonQueryAsync(ct);
        logger.LogInformation("Filled {Count} missing addresses from nearby roads", n);
    }

    /// <summary>Area context for every POI, independently of whether it already has a street address.</summary>
    internal async Task EnrichLocalitiesAsync(CancellationToken ct)
    {
        await using var conn = await dataSource.OpenConnectionAsync(ct);
        await LocalityEnrichment.RunAsync(conn, logger, ct);
    }

    /// <summary>Loads data/tolls/my-toll-rates.csv, matches rows to OSM toll plazas, replaces toll_rates and writes a match report.</summary>
    private async Task ImportTollRatesAsync(string csvPath, CancellationToken ct)
    {
        if (!File.Exists(csvPath))
        {
            logger.LogWarning("Toll tariff table not found at {Path}; skipping toll fares", csvPath);
            return;
        }
        var parsed = TollRateCsv.Parse(await File.ReadAllTextAsync(csvPath, ct));
        foreach (var e in parsed.Errors) logger.LogWarning("Toll CSV: {Error}", e);

        var plazas = (await db.Places.AsNoTracking().Where(p => p.Category == PlaceCategory.TollBooth)
                .Select(p => new { p.Id, p.Name, p.Location }).ToListAsync(ct))
            .Select(p => new TollPlaza(p.Id, p.Name, p.Location.Y, p.Location.X)).ToList();
        var outcomes = TollRateCsv.Match(parsed.Rows, plazas);
        foreach (var m in outcomes) m.Row.MatchedPlaceIds = [.. m.PlaceIds];

        await db.TollRates.ExecuteDeleteAsync(ct);
        db.TollRates.AddRange(outcomes.Select(m => m.Row));
        await db.SaveChangesAsync(ct);

        var matched = outcomes.Count(m => m.PlaceIds.Count > 0);
        logger.LogInformation("Toll rates: {Rows} rows, {Matched} matched to {Nodes} OSM plaza nodes, {Unmatched} unmatched, {Errors} invalid",
            outcomes.Count, matched, outcomes.Sum(m => m.PlaceIds.Count), outcomes.Count - matched, parsed.Errors.Count);

        var report = BuildTollReport(csvPath, outcomes, parsed.Errors, plazas.Count);
        var reportPath = Path.ChangeExtension(csvPath, ".match-report.md");
        try
        {
            await File.WriteAllTextAsync(reportPath, report, ct);
            logger.LogInformation("Toll match report written to {Path}", reportPath);
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            logger.LogWarning("Could not write {Path} ({Message}); report follows:\n{Report}", reportPath, ex.Message, report);
        }
    }

    internal static string BuildTollReport(string csvPath, IReadOnlyList<TollRateCsv.MatchOutcome> outcomes, IReadOnlyList<string> errors, int plazaNodes)
    {
        var sb = new System.Text.StringBuilder();
        sb.AppendLine("# Toll tariff ↔ OSM plaza match report").AppendLine();
        sb.AppendLine($"Generated by `Gimano.Importer` from `{Path.GetFileName(csvPath)}` against {plazaNodes} OSM toll plaza nodes.").AppendLine();
        sb.AppendLine($"- rows: {outcomes.Count}, matched: {outcomes.Count(o => o.PlaceIds.Count > 0)}, unmatched: {outcomes.Count(o => o.PlaceIds.Count == 0)}, invalid: {errors.Count}").AppendLine();
        var unmatched = outcomes.Where(o => o.PlaceIds.Count == 0).ToList();
        if (unmatched.Count > 0)
        {
            sb.AppendLine("## Unmatched rows").AppendLine().AppendLine("| name | highway | system | entry | reason |").AppendLine("|---|---|---|---|---|");
            foreach (var o in unmatched) sb.AppendLine($"| {o.Row.Name} | {o.Row.Highway} | {GimanoJson.ToWire(o.Row.System)} | {o.Row.EntryPlaza} | {o.Method} |");
            sb.AppendLine();
        }
        if (errors.Count > 0)
        {
            sb.AppendLine("## Invalid rows").AppendLine();
            foreach (var e in errors) sb.AppendLine($"- {e}");
            sb.AppendLine();
        }
        sb.AppendLine("## Matched rows").AppendLine().AppendLine("| name | highway | system | class 1 | class 0 | method | OSM nodes |").AppendLine("|---|---|---|---|---|---|---|");
        foreach (var o in outcomes.Where(o => o.PlaceIds.Count > 0))
            sb.AppendLine($"| {o.Row.Name} | {o.Row.Highway} | {GimanoJson.ToWire(o.Row.System)} | {o.Row.Class1Myr} | {o.Row.Class0Myr} | {o.Method} | {string.Join(" ", o.PlaceIds)} |");
        return sb.ToString();
    }

    /// <summary>Area refs for labels ("SS2, Petaling Jaya") from the imported areas.</summary>
    private async Task<AreaLocator> LoadAreasAsync(CancellationToken ct)
    {
        var rows = await db.Places.AsNoTracking().Where(p => p.Category == PlaceCategory.Area)
            .Select(p => new { p.Id, p.Name, p.Tags, p.Location, p.Popularity }).ToListAsync(ct);
        return new AreaLocator(rows.Select(r => new AreaRef(r.Id, r.Name, r.Tags.GetValueOrDefault("place") ?? "admin", r.Location.Y, r.Location.X, r.Popularity)));
    }

    /// <summary>Streets (from road segments), house addresses and postcode centroids as search documents.</summary>
    private async Task<int> IndexStreetsAndAddressesAsync(string? target, CancellationToken ct)
    {
        var areas = await LoadAreasAsync(ct);
        var total = 0;
        await using var conn = await dataSource.OpenConnectionAsync(ct);

        // One document per street name per geohash-4 cell (~20-40 km), snapped onto the road.
        var streetEdits = (await db.PlaceSuggestions.AsNoTracking().Where(s => s.Status == SuggestionStatus.Applied && s.StreetOriginalName != null)
            .OrderBy(s => s.AppliedAt).ThenBy(s => s.Id).ToListAsync(ct)).GroupBy(s => s.PlaceId).Select(g => g.Last()).ToList();
        var editedWays = streetEdits.SelectMany(s => s.StreetWayIds).ToHashSet();
        var streets = 0;
        var buffer = new List<System.Text.Json.Nodes.JsonObject>(2000);
        await using (var cmd = new NpgsqlCommand("""
            SELECT 'st-' || gh || '-' || left(md5(name), 10), name, ST_Y(pt), ST_X(pt), ways FROM (
              SELECT name, gh, array_agg(DISTINCT osm_way_id) AS ways, ST_ClosestPoint(ST_Collect(g), ST_Centroid(ST_Collect(g))) AS pt FROM (
                SELECT name, osm_way_id, geom::geometry AS g, ST_GeoHash(ST_StartPoint(geom::geometry), 4) AS gh
                FROM road_segments WHERE name IS NOT NULL AND name <> '' AND NOT (osm_way_id = ANY(@edited))) s
              GROUP BY name, gh) t
            """, conn) { CommandTimeout = 1800, Parameters = { new NpgsqlParameter("edited", editedWays.ToArray()) } })
        await using (var r = await cmd.ExecuteReaderAsync(ct))
        {
            while (await r.ReadAsync(ct))
            {
                double lat = r.GetDouble(2), lng = r.GetDouble(3);
                buffer.Add(SearchQueryBuilder.StreetDocument(r.GetString(0), r.GetString(1), lat, lng, areas.Label(lat, lng), CountryResolver.Resolve(lat, lng, null)));
                if (buffer.Count == 2000) { streets += await index.BulkIndexAsync(buffer, target, ct); buffer.Clear(); }
            }
        }
        foreach (var edit in streetEdits)
            if (await StreetCorrections.DocumentAsync(db, edit, ct) is { } correctedStreet) buffer.Add(correctedStreet);
        streets += await index.BulkIndexAsync(buffer, target, ct); buffer.Clear();
        total += streets;

        // House addresses, and postcode centroids from addresses + places that carry addr:postcode.
        var postcodes = new Dictionary<string, (double Lat, double Lng, int N, Dictionary<string, int> Cities, string Country)>();
        void AddPostcode(string? pc, double lat, double lng, string? city, string country)
        {
            if (pc is null || !System.Text.RegularExpressions.Regex.IsMatch(pc, @"^\d{5,6}$")) return;
            var e = postcodes.GetValueOrDefault(pc, (0, 0, 0, new Dictionary<string, int>(), country));
            if (!string.IsNullOrWhiteSpace(city)) e.Cities[city] = e.Cities.GetValueOrDefault(city) + 1;
            postcodes[pc] = (e.Lat + lat, e.Lng + lng, e.N + 1, e.Cities, e.Country);
        }
        var addresses = 0;
        await foreach (var a in db.StreetAddresses.AsNoTracking().AsAsyncEnumerable().WithCancellation(ct))
        {
            var at = new AddressPoint(a.Id, a.HouseNumber, a.Street, a.Postcode, a.City, a.Location.Y, a.Location.X, a.Country);
            AddPostcode(a.Postcode, at.Lat, at.Lng, a.City, a.Country);
            buffer.Add(SearchQueryBuilder.AddressDocument(at, areas.Label(at.Lat, at.Lng)));
            if (buffer.Count == 2000) { addresses += await index.BulkIndexAsync(buffer, target, ct); buffer.Clear(); }
        }
        addresses += await index.BulkIndexAsync(buffer, target, ct); buffer.Clear();
        total += addresses;

        await using (var cmd = new NpgsqlCommand("""
            SELECT tags->>'addr:postcode', ST_Y(location::geometry), ST_X(location::geometry), tags->>'addr:city', country
            FROM places WHERE tags ? 'addr:postcode'
            """, conn) { CommandTimeout = 600 })
        await using (var r = await cmd.ExecuteReaderAsync(ct))
            while (await r.ReadAsync(ct))
                AddPostcode(r.IsDBNull(0) ? null : r.GetString(0).Trim(), r.GetDouble(1), r.GetDouble(2), r.IsDBNull(3) ? null : r.GetString(3), r.GetString(4));

        var pcs = postcodes.Where(kv => kv.Value.N >= 2).Select(kv =>
        {
            var (lat, lng) = (kv.Value.Lat / kv.Value.N, kv.Value.Lng / kv.Value.N);
            var city = kv.Value.Cities.OrderByDescending(c => c.Value).Select(c => c.Key).FirstOrDefault();
            return SearchQueryBuilder.PostcodeDocument(kv.Key, lat, lng, city ?? areas.Label(lat, lng), kv.Value.Country);
        }).ToList();
        total += await index.BulkIndexAsync(pcs, target, ct);
        logger.LogInformation("Indexed {Streets} streets, {Addresses} addresses, {Postcodes} postcodes", streets, addresses, pcs.Count);
        return total;
    }

    internal async Task IndexSearchAsync(bool recreate, CancellationToken ct)
    {
        // A rebuild fills a new physical index and swaps the alias at the end, so search keeps working meanwhile.
        string? target = null;
        if (recreate) target = await index.BeginRebuildAsync(ct);
        else await index.EnsureIndexAsync(ct: ct);
        // Reviews/photos aggregates and community places must survive a re-import.
        var aggregates = await PlaceDocuments.AggregatesAsync(db, null, ct);
        var closedIds = (await db.Issues.Where(i => i.Kind == IssueKind.PlaceClosedPerm && i.State == IssueState.Confirmed && i.PlaceId != null).Select(i => i.PlaceId!).ToListAsync(ct)).ToHashSet();
        const int batch = 2000;
        var total = 0;
        string? lastId = null;
        while (true)
        {
            var q = db.Places.AsNoTracking().OrderBy(p => p.Id).AsQueryable();
            if (lastId is not null) q = q.Where(p => string.Compare(p.Id, lastId) > 0);
            var rows = await q.Take(batch).ToListAsync(ct);
            if (rows.Count == 0) break;
            total += await index.BulkIndexAsync(rows.Select(p => { var doc = SearchQueryBuilder.ToDocument(p, aggregates.GetValueOrDefault(p.Id)); if (closedIds.Contains(p.Id)) doc["closed"] = true; return doc; }), target, ct);
            lastId = rows[^1].Id;
            if (total % 20000 < batch) logger.LogInformation("Indexed {Total} places…", total);
        }
        var community = await db.CommunityPlaces.AsNoTracking().ToListAsync(ct);
        total += await index.BulkIndexAsync(community.Select(p => { var doc = SearchQueryBuilder.ToDocument(p, aggregates.GetValueOrDefault(p.Id)); if (closedIds.Contains(p.Id)) doc["closed"] = true; return doc; }), target, ct);
        total += await IndexStreetsAndAddressesAsync(target, ct);
        if (target is not null) await index.CompleteRebuildAsync(target, ct);
        else await index.RefreshAsync(ct);
        logger.LogInformation("OpenSearch '{Index}' now has {Total} documents ({Community} community)", index.Index, total, community.Count);
    }
}
