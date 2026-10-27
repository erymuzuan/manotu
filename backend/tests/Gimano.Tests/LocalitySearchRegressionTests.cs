using Gimano.Api.Services;
using Gimano.Core.Contracts;
using Gimano.Core.Domain;
using Gimano.Core.Geo;
using Gimano.Core.Search;

namespace Gimano.Tests;

public class LocalitySearchRegressionTests
{
    private static AreaLocator Areas() => new([
        new("pj", "Petaling Jaya", "city", 3.09888, 101.64542, 8),
        new("sj", "Subang Jaya", "city", 3.05149, 101.58233, 8),
        new("section", "Seksyen 17A", "quarter", 3.12934, 101.63193, 1),
        new("section17", "Seksyen 17", "quarter", 3.12522, 101.63524, 1),
        new("ss17", "SS 17", "quarter", 3.07631, 101.58198, 1),
    ]);

    [Theory]
    [InlineData("SS17A")]
    [InlineData("SS 17A")]
    [InlineData("PJ17A")]
    [InlineData("PJ 17A")]
    [InlineData("Seksyen17A")]
    [InlineData("Seksyen 17A")]
    public void Complete_section_code_resolves_without_losing_suffix(string locality)
    {
        var split = SearchPipeline.SplitArea(TextNormalizer.Normalize("Masjid Ar-Rahmah " + locality), Areas(), 3.1292, 101.6316);
        Assert.NotNull(split);
        Assert.Equal("section", split.Value.Area.Id);
        Assert.Equal("masjid ar rahmah", split.Value.Remainder);
    }

    [Fact]
    public void Native_SS17_is_not_replaced_by_a_nearer_numbered_section()
    {
        Assert.Equal("ss17", Areas().Resolve("SS17", 3.1292, 101.6316)!.Id);
        Assert.Null(Areas().Resolve("SS17B", 3.1292, 101.6316));
        Assert.Null(Areas().Resolve("SS18A", 3.1292, 101.6316));
        Assert.Null(Areas().Resolve("SS17A", null, null));
        Assert.Null(Areas().Resolve("SS17A", 5.8, 101.9));
    }

    [Fact]
    public async Task Nearby_name_variant_survives_exact_name_crowding_and_viewport()
    {
        var prefix = $"gimano-loc{Guid.NewGuid():N}"[..22] + "-";
        var index = OpenSearchIntegrationTests.Create(prefix, out var client);
        if (index is null) { Assert.Skip("GIMANO_OS_URL not set"); return; }
        static Place Mosque(string id, string name, double lat, double lng) => new()
        {
            Id = id, Name = name, Category = PlaceCategory.Mosque, OsmType = "node",
            Location = new GeoPoint(lat, lng).ToPoint(), Popularity = 2,
        };
        try
        {
            await index.EnsureIndexAsync();
            var places = Enumerable.Range(0, 35).Select(i => Mosque($"exact{i}", "Masjid Ar-Rahman", 3.105 - i * .001, 101.655)).ToList();
            places.Add(Mosque("near-variant", "Masjid Ar-Rahmah", 3.12915, 101.63160));
            places.Add(Mosque("unrelated", "Masjid Al-Hidayah", 3.1292, 101.6316));
            await index.BulkIndexAsync(places.Select(p => SearchQueryBuilder.ToDocument(p)));
            await index.RefreshAsync();
            var pipeline = new SearchPipeline(index, AliasTable.Embedded);
            foreach (var suffix in new[] { "", " SS17A", " SS 17A", " PJ17A", " Seksyen17A" })
            {
                var (hits, _, _) = await pipeline.RunAsync(new("Masjid Ar-Rahman" + suffix, 3.1292, 101.6316), null, Areas(), default);
                Assert.Contains(hits.Take(3), h => h.Id == "near-variant");
                Assert.Contains(hits, h => h.Name == "Masjid Ar-Rahman");
                Assert.DoesNotContain(hits, h => h.Id == "unrelated");
            }
            var (correct, _, _) = await pipeline.RunAsync(new("Masjid Ar-Rahmah", 3.1292, 101.6316), null, Areas(), default);
            Assert.Equal("near-variant", correct[0].Id);
            var (exact, _, _) = await pipeline.RunAsync(new("Masjid Ar-Rahman", 3.1292, 101.6316, Exact: true), null, Areas(), default);
            Assert.NotEmpty(exact);
            Assert.All(exact, h => Assert.Equal("Masjid Ar-Rahman", h.Name));
            Assert.True(SearchViewport.TryParse("101.62,3.12;101.64,3.12;101.64,3.14;101.62,3.14", out var localViewport));
            var (inside, _, _) = await pipeline.RunAsync(new("Masjid Ar-Rahman PJ17A", 3.05, 101.58, Viewport: localViewport), null, Areas(), default);
            Assert.Contains(inside, h => h.Id == "near-variant");
            Assert.All(inside, h => Assert.True(localViewport!.Contains(h.Lat, h.Lng)));
            Assert.True(SearchViewport.TryParse("101.65,3.06;101.67,3.06;101.67,3.11;101.65,3.11", out var viewport));
            var (bounded, _, _) = await pipeline.RunAsync(new("Masjid Ar-Rahman PJ17A", 3.1292, 101.6316, Viewport: viewport), null, Areas(), default);
            Assert.DoesNotContain(bounded, h => h.Id == "near-variant");
            Assert.All(bounded, h => Assert.True(viewport!.Contains(h.Lat, h.Lng)));
        }
        finally { await client.Indices.DeleteAsync<OpenSearch.Net.StringResponse>(prefix + "*"); }
    }
}
