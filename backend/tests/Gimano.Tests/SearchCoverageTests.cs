using Gimano.Api.Services;
using Gimano.Core.Contracts;
using Gimano.Core.Places;
using Gimano.Core.Search;
namespace Gimano.Tests;
public class SearchCoverageTests
{
    private static AreaLocator Areas() => new([new AreaRef("bb", "Bukit Bunga", "town", 5.83, 101.90, 6), new AreaRef("kel", "Kelantan", "admin", 5.3, 102, 8)]);
    [Theory]
    [InlineData("petronas bukit bunga")]
    [InlineData("petronas di bukit bunga")]
    [InlineData("petronas bukit bnga")]
    [InlineData("petronas bukit bunga kelantan")]
    [InlineData("bukit bunga petronas")]
    public void Area_intent_survives_natural_phrasing(string query)
    {
        var split = SearchPipeline.SplitArea(query, Areas(), 3.14, 101.69);
        Assert.NotNull(split); Assert.Equal("bb", split.Value.Area.Id); Assert.Equal("petronas", split.Value.Remainder);
    }
    [Fact] public void Exact_mode_does_not_correct_area_typo() => Assert.Null(SearchPipeline.SplitArea("petronas bukit bnga", Areas(), 3.14, 101.69, false));
    [Theory]
    [InlineData("shop", "hairdresser", "Kedai Rambut Ali")]
    [InlineData("amenity", "fire_station", "Balai Bomba")]
    [InlineData("natural", "beach", "Pantai Cahaya")]
    [InlineData("building", "apartments", "Ken Damansara 2")]
    [InlineData("shop", "furniture", "Home Furniture")]
    public void Named_public_destinations_do_not_require_known_category(string tag, string value, string name)
    {
        var t = new Dictionary<string, string> { [tag] = value, ["name"] = name };
        var category = OsmCategoryMapper.Map(t); Assert.NotNull(category); Assert.True(OsmCategoryMapper.ShouldImport(category.Value, t));
    }
    [Theory]
    [InlineData("building", "house", "Erymuzuan home")]
    [InlineData("building", "apartments", "Rumah Mak Teh")]
    [InlineData("landuse", "military", "Camp")]
    [InlineData("office", "intelligence", "Office")]
    [InlineData("addr:unit", "12A", "Apartment unit")]
    public void Sensitive_sites_and_personal_residences_are_excluded(string tag, string value, string name)
    {
        var t = new Dictionary<string, string> { [tag] = value, ["name"] = name }; Assert.Null(OsmCategoryMapper.Map(t)); Assert.False(ImportEligibility.IncludeAddress(t));
    }
    [Fact] public void Translated_name_and_controlled_access_development_are_supported()
    {
        var t = new Dictionary<string, string> { ["name:ms"] = "Pangsapuri Mawar", ["building"] = "apartments", ["access"] = "private" };
        Assert.Equal(PlaceCategory.Other, OsmCategoryMapper.Map(t)); Assert.True(OsmCategoryMapper.ShouldImport(PlaceCategory.Other, t));
        Assert.Equal("Pangsapuri Mawar", OsmCategoryMapper.DisplayName(PlaceCategory.Other, t));
    }
    [Fact] public void Viewport_is_hard_boundary_including_edges()
    {
        Assert.True(SearchViewport.TryParse("101,3;102,3;102,4;101,4", out var v));
        Assert.True(v!.Contains(3,101)); Assert.True(v.Contains(3.5,101.5)); Assert.False(v.Contains(4.001,101.5));
        Assert.Contains("geo_polygon", SearchQueryBuilder.Build(new SearchQuery("petronas",1,100,Viewport:v)).ToJsonString());
    }
    [Theory]
    [InlineData("NaN,3;102,3;102,4")]
    [InlineData("101,3;102,4;101,4;102,3")]
    [InlineData("101,3;101,3;101,3")]
    public void Invalid_viewports_are_rejected(string text) => Assert.False(SearchViewport.TryParse(text,out _));
}
