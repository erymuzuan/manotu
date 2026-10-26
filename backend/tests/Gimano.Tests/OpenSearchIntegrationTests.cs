using Gimano.Core.Contracts;
using Gimano.Core.Domain;
using Gimano.Core.Geo;
using Gimano.Core.Infrastructure;
using Gimano.Core.Search;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Logging;
using OpenSearch.Net;

namespace Gimano.Tests;

/// <summary>
/// Runs against a real OpenSearch (2.19 or 3.x) when GIMANO_OS_URL is set, e.g.
///   GIMANO_OS_URL=https://localhost:9200 GIMANO_OS_USER=gimano GIMANO_OS_PASSWORD=… GIMANO_OS_INSECURE=true dotnet test --filter OpenSearchIntegration
/// The user only needs index permissions on "gimano-*" (+ the cluster-level bulk action). Skipped otherwise.
/// </summary>
public class OpenSearchIntegrationTests
{
    internal static PlaceSearchIndex? Create(string prefix, out IOpenSearchLowLevelClient client)
    {
        client = null!;
        var url = Environment.GetEnvironmentVariable("GIMANO_OS_URL");
        if (string.IsNullOrEmpty(url)) return null;
        var config = new ConfigurationBuilder().AddInMemoryCollection(new Dictionary<string, string?>
        {
            ["OpenSearch:Url"] = url,
            ["OpenSearch:User"] = Environment.GetEnvironmentVariable("GIMANO_OS_USER"),
            ["OpenSearch:Password"] = Environment.GetEnvironmentVariable("GIMANO_OS_PASSWORD"),
            ["OpenSearch:AllowInvalidCertificate"] = Environment.GetEnvironmentVariable("GIMANO_OS_INSECURE") ?? "false",
            ["OpenSearch:IndexPrefix"] = prefix,
            ["OpenSearch:TimeoutSeconds"] = "60",
            ["OpenSearch:Replicas"] = "0",
        }).Build();
        var sp = new ServiceCollection().AddLogging(b => b.AddConsole()).AddGimanoSearch(config).BuildServiceProvider();
        client = sp.GetRequiredService<IOpenSearchLowLevelClient>();
        return sp.GetRequiredService<PlaceSearchIndex>();
    }

    private static Place Osm(string id, string name, double lat, double lng, PlaceCategory cat = PlaceCategory.Fuel) => new()
    {
        Id = id, Name = name, Brand = name.Split(' ')[0], Category = cat, Location = new GeoPoint(lat, lng).ToPoint(), OsmType = "node", Popularity = 2,
    };

    [Fact]
    public async Task Locality_viewport_and_closure_retrieval()
    {
        var prefix = $"gimano-cov{Guid.NewGuid():N}"[..22] + "-";
        var index = Create(prefix, out var client);
        if (index is null) { Assert.Skip("GIMANO_OS_URL not set"); return; }
        try
        {
            await index.EnsureIndexAsync();
            var station = Osm("nBB", "Petronas", 5.8355, 101.9018);
            station.Tags["manotu:locality"] = "Bukit Bunga";
            station.Tags["manotu:admin_names"] = "Kelantan";
            var closed = SearchQueryBuilder.ToDocument(Osm("closed", "Petronas", 5.8356, 101.9019));
            closed["closed"] = true;
            await index.BulkIndexAsync([SearchQueryBuilder.ToDocument(station), closed,
                SearchQueryBuilder.ToDocument(Osm("far", "Petronas", 3.14, 101.69)),
                SearchQueryBuilder.ToDocument(new CommunityPlace { Id = "community", Name = "Petronas Kiosk", Category = PlaceCategory.Fuel,
                    Status = PlaceStatus.Pending, Listed = true, Location = new GeoPoint(5.836, 101.902).ToPoint() })]);
            await index.RefreshAsync();
            var areas = new AreaLocator([new AreaRef("bb", "Bukit Bunga", "town", 5.83, 101.90, 6), new AreaRef("kel", "Kelantan", "admin", 5.3, 102, 8)]);
            var pipeline = new Gimano.Api.Services.SearchPipeline(index, AliasTable.Embedded);
            foreach (var query in new[] { "Petronas Bukit Bunga", "Petronas di Bukit Bunga", "Petronas Bukit Bnga", "Petronas Bukit Bunga Kelantan" })
            {
                var (results, _, correction) = await pipeline.RunAsync(new(query, 3.14, 101.69, Category: PlaceCategory.Fuel), null, areas, default);
                Assert.Contains(results, r => r.Id == "nBB");
                Assert.DoesNotContain(results, r => r.Id is "far" or "closed");
                if (query.Contains("Bnga")) Assert.Contains("Bukit Bunga", correction);
            }
            Assert.True(SearchViewport.TryParse("101.89,5.82;101.92,5.82;101.92,5.85;101.89,5.85", out var viewport));
            var (scoped, _, _) = await pipeline.RunAsync(new("Petronas", 3.14, 101.69, Viewport: viewport), null, areas, default);
            Assert.Contains(scoped, r => r.Id == "community" && r.Status == PlaceStatus.Pending);
            Assert.All(scoped, r => Assert.True(viewport!.Contains(r.Lat, r.Lng)));
            Assert.DoesNotContain(scoped, r => r.Id == "closed");
            Assert.True(SearchViewport.TryParse("101.68,3.13;101.70,3.13;101.70,3.15;101.68,3.15", out var klViewport));
            var (outsideLocality, _, _) = await pipeline.RunAsync(new("Petronas Bukit Bunga", 3.14, 101.69, Viewport: klViewport), null, areas, default);
            Assert.Empty(outsideLocality);
            var malformed = SearchQueryBuilder.ToDocument(station); malformed["location"] = "invalid";
            await Assert.ThrowsAsync<InvalidOperationException>(() => index.BulkIndexAsync([malformed]));
        }
        finally
        {
            var response = await client.Indices.GetAsync<StringResponse>(prefix + "*");
            if (response.Success && System.Text.Json.Nodes.JsonNode.Parse(response.Body) is System.Text.Json.Nodes.JsonObject rows)
                foreach (var (name, _) in rows) await client.Indices.DeleteAsync<StringResponse>(name);
        }
    }

    [Fact]
    public async Task Prefixed_alias_bulk_search_visibility_and_rebuild_against_a_real_cluster()
    {
        var prefix = $"gimano-it{Guid.NewGuid():N}"[..20] + "-";
        var index = Create(prefix, out var client);
        if (index is null) { Assert.Skip("GIMANO_OS_URL not set"); return; }
        try
        {
            Assert.True(await index.PingAsync(), "ping (HEAD on the prefixed alias) should succeed even before the index exists");
            await index.EnsureIndexAsync();
            Assert.Equal(prefix + "places", index.Index);

            var owner = Guid.NewGuid();
            var docs = new[]
            {
                SearchQueryBuilder.ToDocument(Osm("n1", "Petronas Damansara", 3.1300, 101.6300)),
                SearchQueryBuilder.ToDocument(Osm("n2", "Petronas Kepong", 3.2100, 101.6400)),
                SearchQueryBuilder.ToDocument(Osm("n3", "Shell SS2", 3.1190, 101.6210)),
                SearchQueryBuilder.ToDocument(new CommunityPlace { Id = "c1", Name = "Petronas Kiosk Komuniti", Location = new GeoPoint(3.12, 101.62).ToPoint(),
                    Status = PlaceStatus.Pending, OwnerId = owner }),
            };
            Assert.Equal(4, await index.BulkIndexAsync(docs));
            await index.RefreshAsync();

            // search_as_you_type bool_prefix + gauss geo decay + visibility filter
            var near = await index.SearchAsync(new SearchQuery("petr", 3.11, 101.62));
            Assert.Equal(["n1", "n2"], near.Select(h => h.Id).ToArray());   // nearest first, pending community place hidden
            var asOwner = await index.SearchAsync(new SearchQuery("petr", 3.11, 101.62, Viewer: owner));
            Assert.Contains(asOwner, h => h.Id == "c1" && h.Status == PlaceStatus.Pending && h.Source == PlaceSource.Community);
            var fuzzy = await index.SearchAsync(new SearchQuery("petronaz", null, null));
            Assert.NotEmpty(fuzzy);
            var cat = await index.SearchAsync(new SearchQuery("shell", 3.11, 101.62, Category: PlaceCategory.Fuel));
            Assert.Equal("n3", Assert.Single(cat).Id);

            // Rebuild into a new physical index and swap the alias atomically.
            var physical = await index.BeginRebuildAsync();
            await index.BulkIndexAsync([SearchQueryBuilder.ToDocument(Osm("n9", "Petronas Baru", 3.12, 101.62))], physical);
            await index.CompleteRebuildAsync(physical);
            var after = await index.SearchAsync(new SearchQuery("petronas", 3.12, 101.62));
            Assert.Equal("n9", Assert.Single(after).Id);

            await index.DeleteAsync("n9");
            await index.RefreshAsync();
            Assert.Empty(await index.SearchAsync(new SearchQuery("petronas", 3.12, 101.62)));
        }
        finally
        {
            // Delete by exact name (OpenSearch 3 defaults to action.destructive_requires_name=true).
            var all = await client.Indices.GetAsync<StringResponse>(prefix + "*");
            if (all.Success && System.Text.Json.Nodes.JsonNode.Parse(all.Body) is System.Text.Json.Nodes.JsonObject o)
                foreach (var (name, _) in o) await client.Indices.DeleteAsync<StringResponse>(name);
        }
    }
}
