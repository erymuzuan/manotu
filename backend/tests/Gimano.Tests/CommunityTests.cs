using System.Security.Cryptography;
using System.Text;
using System.Text.Json.Nodes;
using Gimano.Api.Services;
using Gimano.Core.Community;
using Gimano.Core.Contracts;
using Gimano.Core.Domain;
using Gimano.Core.Geo;
using Gimano.Core.Search;

namespace Gimano.Tests;

public class DuplicateDetectionTests
{
    [Theory]
    [InlineData("word", "word", 1.0)]
    [InlineData("Kedai Makan Mak Teh", "Kedai Makan Mak Teh", 1.0)]
    [InlineData("word", "two words", 0.363636)]   // pg_trgm docs example: similarity('word','two words') = 0.363636
    [InlineData("abc", "xyz", 0.0)]
    public void Trigram_similarity_matches_pg_trgm(string a, string b, double expected) =>
        Assert.Equal(expected, CommunityRules.TrigramSimilarity(a, b), 5);

    private static readonly GeoPoint Here = new(3.1180, 101.6190);

    [Fact]
    public void Similar_name_within_100m_is_a_duplicate()
    {
        var nearby = new[]
        {
            new CommunityRules.NearbyName("n1", "Restoran Mak Teh", 3.1183, 101.6190),   // ~33 m
            new CommunityRules.NearbyName("n2", "Kedai Runcit Ali", 3.1181, 101.6191),
        };
        var dup = CommunityRules.FindDuplicate("Restoran Mak Teh SS2", Here, nearby);
        Assert.Equal("n1", dup?.Id);
        Assert.Null(CommunityRules.FindDuplicate("Bengkel Kereta Ah Seng", Here, nearby));
    }

    [Fact]
    public void Same_name_further_than_100m_is_not_a_duplicate()
    {
        var far = new[] { new CommunityRules.NearbyName("n1", "Restoran Mak Teh", 3.1195, 101.6190) }; // ~167 m
        Assert.Null(CommunityRules.FindDuplicate("Restoran Mak Teh", Here, far));
    }

    [Fact]
    public void Case_and_punctuation_do_not_matter()
    {
        var nearby = new[] { new CommunityRules.NearbyName("c1", "KEDAI MAKAN MAK TEH!", 3.1180, 101.6191) };
        Assert.Equal("c1", CommunityRules.FindDuplicate("kedai makan mak teh", Here, nearby)?.Id);
    }
}

public class SearchVisibilityTests
{
    private static readonly Guid Owner = Guid.NewGuid();
    private static readonly Guid Other = Guid.NewGuid();

    [Theory]
    [InlineData(PlaceStatus.Published, false, true)]
    [InlineData(PlaceStatus.Pending, false, false)]
    [InlineData(PlaceStatus.Pending, true, true)]
    [InlineData(PlaceStatus.Hidden, true, false)]
    [InlineData(PlaceStatus.Closed, true, false)]
    public void Searchable_rules(PlaceStatus status, bool viewerIsOwner, bool searchable) =>
        Assert.Equal(searchable, CommunityRules.IsSearchableBy(status, Owner, viewerIsOwner ? Owner : Other));

    [Fact]
    public void Pending_places_are_visible_by_id_so_neighbours_can_verify_but_hidden_only_to_owner()
    {
        Assert.True(CommunityRules.IsVisibleTo(PlaceStatus.Pending, Owner, Other));
        Assert.True(CommunityRules.IsVisibleTo(PlaceStatus.Pending, Owner, null));
        Assert.False(CommunityRules.IsVisibleTo(PlaceStatus.Hidden, Owner, Other));
        Assert.True(CommunityRules.IsVisibleTo(PlaceStatus.Hidden, Owner, Owner));
    }

    /// <summary>Evaluates the OpenSearch visibility filter against a document (term/bool subset).</summary>
    private static bool Matches(JsonNode q, JsonObject doc)
    {
        if (q["term"] is JsonObject term)
        {
            var (field, value) = term.First();
            return doc[field]?.ToJsonString() == value!.ToJsonString();
        }
        var b = q["bool"]!;
        var filters = b["filter"]?.AsArray() ?? [];
        var should = b["should"]?.AsArray() ?? [];
        return filters.All(f => Matches(f!, doc)) && (should.Count == 0 || should.Any(s => Matches(s!, doc)));
    }

    private static JsonObject Doc(PlaceStatus status, Guid owner, bool listed = false) => SearchQueryBuilder.ToDocument(new CommunityPlace
    {
        Name = "Kedai Mak Teh", Location = new GeoPoint(3.1, 101.6).ToPoint(), Status = status, OwnerId = owner, Listed = listed,
    });

    private static JsonObject Osm() => SearchQueryBuilder.ToDocument(new Place
    {
        Id = "n1", Name = "Petronas", Location = new GeoPoint(3.1, 101.6).ToPoint(), OsmType = "node",
    });

    [Fact]
    public void OpenSearch_filter_returns_osm_published_listed_and_own_pending_only()
    {
        var asOther = SearchQueryBuilder.Visibility(Other);
        var asOwner = SearchQueryBuilder.Visibility(Owner);
        var anonymous = SearchQueryBuilder.Visibility(null);

        Assert.True(Matches(anonymous, Osm()));
        Assert.True(Matches(asOther, Doc(PlaceStatus.Published, Owner)));
        Assert.False(Matches(asOther, Doc(PlaceStatus.Pending, Owner)));
        Assert.False(Matches(anonymous, Doc(PlaceStatus.Pending, Owner)));
        Assert.True(Matches(asOwner, Doc(PlaceStatus.Pending, Owner)));
        Assert.False(Matches(asOwner, Doc(PlaceStatus.Hidden, Owner)));
        Assert.False(Matches(asOwner, Doc(PlaceStatus.Closed, Owner)));
        // Pending places the AI check passed are listed for everyone; "listed" never survives a status change.
        Assert.True(Matches(anonymous, Doc(PlaceStatus.Pending, Owner, listed: true)));
        Assert.False(Matches(anonymous, Doc(PlaceStatus.Hidden, Owner, listed: true)));
    }

    [Fact]
    public void Search_query_always_applies_the_visibility_filter()
    {
        var body = SearchQueryBuilder.Build(new SearchQuery("mak teh", 3.1, 101.6, Viewer: Owner));
        var filters = body["query"]!["function_score"]!["query"]!["boosting"]!["positive"]!["bool"]!["filter"]!.AsArray();
        Assert.Contains(filters, f => f!.ToJsonString().Contains(Owner.ToString()));
    }

    [Fact]
    public void Community_docs_carry_source_status_owner_and_rating()
    {
        var d = SearchQueryBuilder.ToDocument(new CommunityPlace { Name = "X", Location = new GeoPoint(3, 101).ToPoint(), OwnerId = Owner },
            new PlaceAggregates(4.5, 12, "abc"));
        Assert.Equal("community", d["source"]!.GetValue<string>());
        Assert.Equal("pending", d["status"]!.GetValue<string>());
        Assert.Equal(Owner.ToString(), d["ownerId"]!.GetValue<string>());
        Assert.Equal(4.5, d["rating"]!.GetValue<double>());
        Assert.Equal(12, d["reviewCount"]!.GetValue<int>());
        Assert.Equal("osm", SearchQueryBuilder.ToDocument(new Place { Id = "n", Name = "y", Location = new GeoPoint(3, 101).ToPoint(), OsmType = "node" })["source"]!.GetValue<string>());
    }

    [Fact]
    public void Parses_community_hits()
    {
        const string json = """
            {"hits":{"hits":[{"_score":1,"_source":{"id":"c0123","name":"Kedai","category":"cafe","address":"","location":{"lat":3.1,"lon":101.6},
             "source":"community","status":"pending","rating":4.2,"reviewCount":3,"thumbKey":"ab"}}]}}
            """;
        var h = Assert.Single(PlaceSearchIndex.ParseHits(json));
        Assert.Equal(PlaceSource.Community, h.Source);
        Assert.Equal(PlaceStatus.Pending, h.Status);
        Assert.Equal(4.2, h.Rating);
        Assert.Equal(3, h.ReviewCount);
    }
}

public class ReviewRuleTests
{
    [Theory]
    [InlineData(0)]
    [InlineData(6)]
    public void Rating_must_be_1_to_5(int rating) =>
        Assert.Throws<ValidationException>(() => ReviewService.CheckText(rating, "ok"));

    [Fact]
    public void Links_are_stripped_and_profanity_rejected()
    {
        Assert.Equal("Sedap! cuba nasi lemak", ReviewService.CheckText(5, "Sedap! https://spam.example.com/x cuba nasi lemak"));
        Assert.Equal("Bagus", ReviewService.CheckText(4, "Bagus www.promo.my"));
        Assert.Throws<ValidationException>(() => ReviewService.CheckText(1, "tempat ni bodoh"));
        Assert.Throws<ValidationException>(() => ReviewService.CheckText(3, new string('a', 2001)));
        Assert.Null(ReviewService.CheckText(3, "https://only-a-link.com"));
    }

    [Fact]
    public void Self_review_block_and_limits_match_the_contract()
    {
        Assert.Equal(TimeSpan.FromHours(24), CommunityRules.SelfReviewBlock);
        Assert.Equal(20, CommunityRules.ReviewsPerDay);
        Assert.Equal(3, CommunityRules.FlagsToHide);
        Assert.Equal((5, 20, 3, 2, 1), (CommunityRules.Points.PlaceAdded, CommunityRules.Points.PlacePublished, CommunityRules.Points.Review,
            CommunityRules.Points.Photo, CommunityRules.Points.HelpfulReceived));
    }

    [Fact]
    public void Cursors_round_trip()
    {
        var id = Guid.CreateVersion7();
        var c = CommunityRules.EncodeCursor(7, id);
        Assert.DoesNotContain("=", c);
        Assert.Equal(["7", id.ToString()], CommunityRules.DecodeCursor(c)!);
        Assert.Null(CommunityRules.DecodeCursor("%%%"));
        Assert.Null(CommunityRules.DecodeCursor(null));
    }
}

public class TextFilterTests
{
    private static readonly TextFilter F = TextFilter.Default;

    [Fact]
    public void Embedded_lists_are_loaded() => Assert.True(F.Count > 40);

    [Theory]
    [InlineData("Restoran Mak Teh", TextVerdict.Ok)]
    [InlineData("Butterworth Bus Terminal", TextVerdict.Ok)]   // "butt" inside a word is fine
    [InlineData("Scunthorpe Cafe", TextVerdict.Ok)]
    [InlineData("Kedai Babi Panggang Ah Seng", TextVerdict.Ok)] // legitimate food word, deliberately not listed
    [InlineData("Kedai Sial", TextVerdict.Profanity)]
    [InlineData("SH1T place", TextVerdict.Profanity)]          // leetspeak
    [InlineData("f u c k", TextVerdict.Profanity)]              // spaced out
    [InlineData("fuuuuck", TextVerdict.Profanity)]              // repeated letters
    [InlineData("Puk1mak", TextVerdict.Profanity)]
    [InlineData("haram   jadah", TextVerdict.Profanity)]        // multi-word
    [InlineData("Best deals at www.spam.com", TextVerdict.Link)]
    [InlineData("Promo cheapdeals.my now", TextVerdict.Link)]
    public void Checks_names(string text, TextVerdict expected) => Assert.Equal(expected, F.Check(text));

    [Fact]
    public void Normaliser_folds_accents_case_and_leetspeak()
    {
        Assert.Equal(["cafe", "sedap"], TextFilter.Tokens("CAFÉ  $3d4p"));
    }
}

public class MediaStoreTests
{
    [Fact]
    public async Task Local_store_round_trips_and_rejects_path_traversal()
    {
        var root = Path.Combine(Path.GetTempPath(), "gimano-media-" + Guid.NewGuid().ToString("N"));
        var store = new LocalMediaStore(root);
        var key = MediaKeys.Webp(new string('a', 32));
        await store.PutAsync(key, [1, 2, 3], "image/webp");
        Assert.Equal([1, 2, 3], await store.GetAsync(key));
        await store.DeleteAsync(key);
        Assert.Null(await store.GetAsync(key));
        await Assert.ThrowsAsync<ArgumentException>(() => store.GetAsync("../etc/passwd"));
        Directory.Delete(root, true);
    }

    [Fact]
    public void Media_keys_are_validated()
    {
        Assert.True(MediaKeys.IsValidHash(new string('0', 32)));
        Assert.False(MediaKeys.IsValidHash("../../x"));
        Assert.Equal("/media/abc.webp", MediaKeys.Url("abc"));
        Assert.Null(MediaKeys.Url(null));
    }

    [Fact]
    public void S3_requests_are_signed_with_sigv4()
    {
        var store = new S3MediaStore(new HttpClient(), new S3Options
        {
            Endpoint = "http://minio:9000", Bucket = "gimano", Region = "us-east-1", AccessKey = "AKIDEXAMPLE", SecretKey = "secret",
        });
        using var req = store.Sign(HttpMethod.Put, "ab/abc.webp", "hello"u8.ToArray(), "image/webp", new DateTimeOffset(2026, 10, 23, 0, 0, 0, TimeSpan.Zero));
        Assert.Equal("http://minio:9000/gimano/ab/abc.webp", req.RequestUri!.ToString());
        var auth = req.Headers.GetValues("Authorization").Single();
        Assert.StartsWith("AWS4-HMAC-SHA256 Credential=AKIDEXAMPLE/20261023/us-east-1/s3/aws4_request", auth);
        Assert.Contains("SignedHeaders=host;x-amz-content-sha256;x-amz-date", auth);
        Assert.Equal(Convert.ToHexStringLower(SHA256.HashData("hello"u8)), req.Headers.GetValues("x-amz-content-sha256").Single());
    }
}
