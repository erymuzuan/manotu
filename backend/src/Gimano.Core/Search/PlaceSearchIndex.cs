using Gimano.Core.Community;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using Gimano.Core.Contracts;
using Gimano.Core.Domain;
using Microsoft.Extensions.Logging;
using OpenSearch.Net;

namespace Gimano.Core.Search;

public sealed record PlaceHit(string Id, string Name, PlaceCategory Category, string Address, double Lat, double Lng, string? Brand, double Score,
    PlaceSource Source = PlaceSource.Osm, PlaceStatus? Status = null, double? Rating = null, int ReviewCount = 0, string? ThumbKey = null,
    string? OpeningHours = null, IReadOnlyList<string>? Warnings = null);

/// <summary>Index naming: every index and alias goes through <c>OpenSearch:IndexPrefix</c> (e.g. "gimano-").</summary>
public sealed record OpenSearchIndexOptions(string Prefix = "", int Replicas = 0)
{
    /// <summary>The alias the API and worker read/write, e.g. "gimano-places".</summary>
    public string PlacesAlias => Prefix + SearchQueryBuilder.IndexName;
}

/// <summary>
/// Thin wrapper over the OpenSearch low-level client for the places alias. Works with OpenSearch 2.19 and 3.0 and with a
/// restricted user that only has index permissions on the prefix (no cluster-level calls except bulk).
/// Rebuilds go to a new physical index (<c>{alias}-{timestamp}</c>) and the alias is swapped atomically at the end.
/// </summary>
public sealed class PlaceSearchIndex(IOpenSearchLowLevelClient client, OpenSearchIndexOptions names, ILogger<PlaceSearchIndex> logger)
{
    public string Index => names.PlacesAlias;

    /// <summary>
    /// Reachability + auth check without cluster:monitor: HEAD on our own alias. 200 (exists) and 404 (not created yet)
    /// both mean "reachable and authorised"; 401/403/5xx or no response mean not ready.
    /// </summary>
    public async Task<bool> PingAsync(CancellationToken ct = default)
    {
        var r = await client.Indices.ExistsAsync<StringResponse>(Index, ctx: ct);
        return r.HttpStatusCode is 200 or 404;
    }

    /// <summary>Creates the first physical index + alias if neither exists. With <paramref name="recreate"/> use <see cref="BeginRebuildAsync"/>.</summary>
    public async Task EnsureIndexAsync(bool recreate = false, CancellationToken ct = default)
    {
        if (recreate) throw new InvalidOperationException("Use BeginRebuildAsync/CompleteRebuildAsync to rebuild.");
        var exists = await client.Indices.ExistsAsync<StringResponse>(Index, ctx: ct);
        if (exists.HttpStatusCode == 200) return;
        var physical = await CreatePhysicalAsync(ct);
        await SwapAliasAsync(physical, ct);
    }

    /// <summary>Creates a new physical index for a full rebuild and returns its name (bulk into it, then complete).</summary>
    public Task<string> BeginRebuildAsync(CancellationToken ct = default) => CreatePhysicalAsync(ct);

    /// <summary>Refreshes the new index and atomically points the alias at it; old physical indices are retained.</summary>
    public async Task CompleteRebuildAsync(string physical, CancellationToken ct = default)
    {
        var refresh = await client.Indices.RefreshAsync<StringResponse>(physical, ctx: ct);
        if (!refresh.Success || JsonNode.Parse(refresh.Body)?["_shards"]?["failed"]?.GetValue<int>() > 0) throw new InvalidOperationException("Index refresh failed; promotion blocked.");
        await SwapAliasAsync(physical, ct);
    }

    private async Task<string> CreatePhysicalAsync(CancellationToken ct)
    {
        var physical = $"{Index}-{DateTime.UtcNow:yyyyMMddHHmmssfff}";
        var r = await client.Indices.CreateAsync<StringResponse>(physical, PostData.String(SearchQueryBuilder.IndexDefinition(names.Replicas).ToJsonString()), ctx: ct);
        if (!r.Success) throw new InvalidOperationException($"Creating index '{physical}' failed: {r.HttpStatusCode} {Trim(r.Body)}");
        logger.LogInformation("Created OpenSearch index {Index}", physical);
        return physical;
    }

    private async Task SwapAliasAsync(string physical, CancellationToken ct)
    {
        // Indices currently behind the alias (GET {alias}/_alias needs only index-level permissions on the prefix).
        var current = new List<string>();
        var get = await client.Indices.GetAliasAsync<StringResponse>(Index, ctx: ct);
        if (get.HttpStatusCode == 200 && JsonNode.Parse(get.Body) is JsonObject o)
        {
            foreach (var (name, value) in o)
            {
                // Before aliases were used (dev stacks), the alias name itself may be a concrete index: replace it.
                if (name == Index && value?["aliases"] is JsonObject al && !al.ContainsKey(Index))
                {
                    throw new InvalidOperationException("Legacy concrete index must be backed up and migrated to an alias before rebuilding; active search data was preserved.");
                }
                if (name != physical) current.Add(name);
            }
        }
        else if ((await client.Indices.ExistsAsync<StringResponse>(Index, ctx: ct)).HttpStatusCode == 200)
        {
            throw new InvalidOperationException("Legacy concrete index must be backed up and migrated to an alias before rebuilding; active search data was preserved.");
        }

        var actions = new JsonArray { new JsonObject { ["add"] = new JsonObject { ["index"] = physical, ["alias"] = Index } } };
        foreach (var old in current) actions.Add(new JsonObject { ["remove"] = new JsonObject { ["index"] = old, ["alias"] = Index } });
        var r = await client.DoRequestAsync<StringResponse>(OpenSearch.Net.HttpMethod.POST, "_aliases", ct, PostData.String(new JsonObject { ["actions"] = actions }.ToJsonString()));
        if (!r.Success) throw new InvalidOperationException($"Alias swap {Index} → {physical} failed: {r.HttpStatusCode} {Trim(r.Body)}");
        // Retain old physical indices for explicit rollback; cleanup is a separate maintenance decision.
        logger.LogInformation("Alias {Alias} → {Index} (retained {Old} previous indices)", Index, physical, current.Count);
    }

    private static string Trim(string? s) => s is null ? "" : s.Length > 300 ? s[..300] : s;

    public Task<int> BulkIndexAsync(IEnumerable<Place> places, CancellationToken ct = default) =>
        BulkIndexAsync(places.Select(p => SearchQueryBuilder.ToDocument(p)), null, ct);

    public Task<int> BulkIndexAsync(IEnumerable<JsonObject> docs, CancellationToken ct = default) => BulkIndexAsync(docs, null, ct);

    /// <summary>Indexes prepared documents (each must have an "id").</summary>
    /// <param name="targetIndex">A physical index during a rebuild; default = the alias.</param>
    public async Task<int> BulkIndexAsync(IEnumerable<JsonObject> docs, string? targetIndex, CancellationToken ct = default)
    {
        var target = targetIndex ?? Index;
        var sb = new StringBuilder();
        var n = 0;
        foreach (var d in docs)
        {
            sb.Append("{\"index\":{\"_index\":\"").Append(target).Append("\",\"_id\":").Append(JsonSerializer.Serialize(d["id"]!.GetValue<string>())).Append("}}\n");
            sb.Append(d.ToJsonString()).Append('\n');
            n++;
        }
        if (n == 0) return 0;
        var r = await client.BulkAsync<StringResponse>(PostData.String(sb.ToString()), ctx: ct);
        if (!r.Success) throw new InvalidOperationException($"Bulk index failed: {r.HttpStatusCode} {Trim(r.Body)} {r.OriginalException?.Message}");
        var response = JsonNode.Parse(r.Body);
        if (response?["errors"]?.GetValue<bool>() == true)
            throw new InvalidOperationException("Bulk indexing contained failed items; index promotion is blocked. Retry or repair the batch before rebuilding.");
        return n;
    }

    public async Task DeleteAsync(string id, CancellationToken ct = default) =>
        await client.DeleteAsync<StringResponse>(Index, id, ctx: ct);

    public async Task RefreshAsync(CancellationToken ct = default) =>
        await client.Indices.RefreshAsync<StringResponse>(Index, ctx: ct);

    public Task<IReadOnlyList<PlaceHit>> SearchAsync(SearchQuery q, CancellationToken ct = default) => SearchAsync(SearchQueryBuilder.Build(q), ct);

    /// <summary>Runs a prepared search body (see <see cref="SearchQueryBuilder"/>).</summary>
    public async Task<IReadOnlyList<PlaceHit>> SearchAsync(JsonObject body, CancellationToken ct = default)
    {
        var r = await client.SearchAsync<StringResponse>(Index, PostData.String(body.ToJsonString()), ctx: ct);
        if (!r.Success) throw new SearchUnavailableException($"OpenSearch query failed: {r.HttpStatusCode} {r.OriginalException?.Message}");
        return ParseHits(r.Body);
    }

    public async Task<int> CountAsync(JsonObject body, CancellationToken ct = default)
    {
        var r = await client.CountAsync<StringResponse>(Index, PostData.String(body.ToJsonString()), ctx: ct);
        if (!r.Success) throw new SearchUnavailableException($"OpenSearch count failed: {r.HttpStatusCode} {r.OriginalException?.Message}");
        return JsonNode.Parse(r.Body)?["count"]?.GetValue<int>() ?? 0;
    }

    public static IReadOnlyList<PlaceHit> ParseHits(string json)
    {
        var root = JsonNode.Parse(json)!;
        var hits = root["hits"]?["hits"]?.AsArray() ?? [];
        var result = new List<PlaceHit>(hits.Count);
        foreach (var h in hits)
        {
            var s = h!["_source"]!;
            GimanoJson.TryParseWire<PlaceCategory>(s["category"]?.GetValue<string>(), out var cat);
            var source = s["source"]?.GetValue<string>() == "community" ? PlaceSource.Community : PlaceSource.Osm;
            PlaceStatus? status = GimanoJson.TryParseWire<PlaceStatus>(s["status"]?.GetValue<string>(), out var st) ? st : null;
            result.Add(new PlaceHit(
                s["id"]!.GetValue<string>(),
                s["name"]!.GetValue<string>(),
                cat,
                s["address"]?.GetValue<string>() ?? "",
                s["location"]!["lat"]!.GetValue<double>(),
                s["location"]!["lon"]!.GetValue<double>(),
                s["brand"]?.GetValue<string>(),
                h["_score"]?.GetValue<double>() ?? 0,
                source, status,
                s["rating"]?.GetValue<double>(),
                s["reviewCount"]?.GetValue<int>() ?? 0,
                s["thumbKey"]?.GetValue<string>(),
                s["openingHours"]?.GetValue<string>(),
                PlaceWarnings.Normalize(s["warnings"]?.AsArray().Select(w => w?.GetValue<string>()))));
        }
        return result;
    }
}

public sealed class SearchUnavailableException(string message) : Exception(message);
