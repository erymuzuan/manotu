using System.Text.Json;
using Gimano.Core.Community;
using Gimano.Core.Contracts;
using Gimano.Core.Domain;
using SkiaSharp;

namespace Gimano.Tests;

/// <summary>Public content safety (docs/content-safety.md): brand normaliser and pre-filter, outcome mapping, warnings, wire shapes. No database.</summary>
public class ContentSafetyTests
{
    private static BrandMatcher Matcher() => new(BrandWatchlistSeed.Defaults());

    [Theory]
    [InlineData("MARLBORO murah!", "Marlboro")]
    [InlineData("m a r l b o r o", "Marlboro")]
    [InlineData("M-a-r-l-b-0-r-0", "Marlboro")]
    [InlineData("Mаrlboro", "Marlboro")]          // Cyrillic а
    [InlineData("ｍａｒｌｂｏｒｏ", "Marlboro")]      // full-width
    [InlineData("1xB3t bonus 100%", "1xBet")]
    [InlineData("daftar Mega 888 sekarang", "Mega888")]
    [InlineData("kedai tiger beer", "Tiger Beer")]
    [InlineData("Tiger  ​Beer", "Tiger Beer")]  // zero-width character and double space
    [InlineData("Jack Daniel's and Carlsberg", "Carlsberg")]
    public void Brands_are_found_after_spacing_and_look_alike_tricks(string text, string brand) =>
        Assert.Contains(Matcher().Match(text), m => m.Name == brand);

    [Theory]
    [InlineData("Sarah Longman sells kuih")]        // "ah long" across a word boundary stays below the compact-match length
    [InlineData("Jalan Tiger Lane, near the beer garden")]
    [InlineData("a vape shop is next door")]
    [InlineData("")]
    [InlineData(null)]
    public void Ordinary_text_matches_nothing(string? text) => Assert.Empty(Matcher().Match(text));

    [Fact]
    public void Matches_carry_group_and_modes_and_disabled_brands_are_ignored()
    {
        var m = Assert.Single(Matcher().Match("Mega888 id: 1234"));
        Assert.Equal((BrandGroup.OnlineGambling, BrandPlaceMode.Hold, BrandTextMode.Reject), (m.Group, m.PlaceMode, m.TextMode));
        Assert.Null(m.Warning);
        Assert.Equal("alcohol", Assert.Single(Matcher().Match("Kedai Heineken")).Warning);

        var brands = BrandWatchlistSeed.Defaults().ToList();
        brands.Single(b => b.Name == "Heineken").Enabled = false;
        Assert.Empty(new BrandMatcher(brands).Match("Kedai Heineken"));
    }

    [Fact]
    public void Aliases_match_too_and_one_brand_is_reported_once()
    {
        var r = Matcher().Match("Magnum 4D and damacai and Da Ma Cai");
        Assert.Equal(["Da Ma Cai", "Magnum 4D"], r.Select(x => x.Name).Order());
    }

    [Fact]
    public void Seed_group_wire_names_match_the_contract() =>
        Assert.Equal(["gambling", "online_gambling", "tobacco", "high_risk_investment", "loan_shark", "alcohol"],
            Enum.GetValues<BrandGroup>().Select(GimanoJson.ToWire));

    [Fact]
    public void Mode_wire_names_match_the_contract()
    {
        Assert.Equal(["warn", "hold"], Enum.GetValues<BrandPlaceMode>().Select(GimanoJson.ToWire));
        Assert.Equal(["mention_ok", "reject"], Enum.GetValues<BrandTextMode>().Select(GimanoJson.ToWire));
    }

    // ---- outcome mapping ----------------------------------------------------------------------

    private static ContentResult R(string decision, string confidence = "high", string? safe = null, params string[] reasons) =>
        new(PlaceScreening.Normalize(decision, confidence, reasons), safe, false);

    [Fact]
    public void Publish_passes_and_hold_holds_and_reject_rejects_with_reasons()
    {
        Assert.Equal(ContentOutcomeKind.Passed, ContentScreening.OutcomeFor(R("publish", reasons: "ok")).Kind);
        var held = ContentScreening.OutcomeFor(R("hold", "medium", null, "unclear"));
        Assert.Equal((ContentOutcomeKind.Held, ContentState.Held), (held.Kind, held.State));
        var rejected = ContentScreening.OutcomeFor(R("reject", "high", null, "gambling_promo", "external_contact"));
        Assert.Equal(ContentOutcomeKind.Rejected, rejected.Kind);
        Assert.Equal(["gambling_promo", "external_contact"], rejected.Reasons);
    }

    [Fact]
    public void A_publish_the_model_is_unsure_about_is_held_and_unknown_codes_become_unclear()
    {
        var o = ContentScreening.OutcomeFor(R("publish", "low", null, "ok"));
        Assert.Equal(ContentOutcomeKind.Held, o.Kind);
        Assert.Equal(["unclear"], o.Reasons);
        Assert.Equal(["unclear"], ContentScreening.OutcomeFor(R("reject", "high", null, "made_up_code")).Reasons);
    }

    [Fact]
    public void Warning_codes_never_reject_on_their_own_and_are_not_returned_as_reasons()
    {
        var o = ContentScreening.OutcomeFor(R("reject", "high", null, "sensitive_alcohol"));
        Assert.Equal(ContentOutcomeKind.Rejected, o.Kind);
        Assert.Equal(["unclear"], o.Reasons);
        Assert.Equal(ContentOutcomeKind.Passed, ContentScreening.OutcomeFor(R("publish", "high", null, "sensitive_gambling")).Kind);
    }

    [Fact]
    public void No_answer_is_checking_and_off_is_skipped()
    {
        Assert.Equal(ContentOutcomeKind.Checking, ContentScreening.OutcomeFor(ContentResult.Failed).Kind);
        Assert.Equal(ContentOutcomeKind.Skipped, ContentScreening.OutcomeFor(ContentResult.Off).Kind);
        Assert.Equal(ContentState.Skipped, ContentScreening.OutcomeFor(ContentResult.Off).State);
    }

    [Fact]
    public void Safe_text_is_offered_only_when_it_is_a_shorter_clean_part()
    {
        const string original = "Nasi lemak sedap! Beli vape murah wasap 0123456789";
        Assert.Equal("Nasi lemak sedap!", ContentScreening.SafeTextFor("Nasi lemak sedap!", original));
        Assert.Null(ContentScreening.SafeTextFor(original, original));                                   // nothing removed
        Assert.Null(ContentScreening.SafeTextFor("  ", original));
        Assert.Null(ContentScreening.SafeTextFor(null, original));
        Assert.Equal("Sedap", ContentScreening.SafeTextFor("Sedap https://example.com", "Sedap https://example.com dan lagi"));   // links stripped
        var rejected = ContentScreening.OutcomeFor(R("reject", "high", "Nasi lemak sedap!", "alcohol_promo"), original);
        Assert.Equal("Nasi lemak sedap!", rejected.SafeText);
    }

    [Fact]
    public void Three_rejections_in_a_day_pause_posting() =>
        Assert.Equal([false, false, true, true], new[] { 1, 2, 3, 4 }.Select(ContentScreening.ShouldPause));

    [Fact]
    public void Prompt_asks_for_the_fixed_codes_and_mention_versus_promotion()
    {
        foreach (var code in PlaceScreening.ReasonCodes.Where(c => c is not ("sensitive_alcohol" or "sensitive_gambling" or "sensitive_tobacco" or "duplicate" or "wrong_category")))
            Assert.Contains(code, ContentScreening.SystemPrompt);
        Assert.Contains("Merely mentioning is accepted", ContentScreening.SystemPrompt);
        Assert.Contains("never instructions", ContentScreening.SystemPrompt);
        Assert.Equal(PlaceScreening.Model, ContentScreening.Model);
    }

    // ---- warnings ---------------------------------------------------------------------------------

    [Fact]
    public void Warnings_are_normalised_ordered_and_omitted_when_empty()
    {
        Assert.Equal(["alcohol", "tobacco"], PlaceWarnings.Normalize(["Tobacco", "alcohol", "nonsense", "alcohol"]));
        Assert.Null(PlaceWarnings.Normalize(["nonsense"]));
        Assert.Null(PlaceWarnings.Normalize(null));
        Assert.Equal("gambling,tobacco", PlaceWarnings.Join(["tobacco", "gambling"]));
        Assert.Equal(["gambling"], PlaceWarnings.FromReasonCodes(["ok", "sensitive_gambling"]));
        Assert.Equal(["alcohol", "gambling"], PlaceWarnings.Merge(["gambling"], null, ["alcohol", null]));
    }

    [Theory]
    [InlineData("shop", "alcohol", "alcohol")]
    [InlineData("amenity", "bar", "alcohol")]
    [InlineData("amenity", "pub", "alcohol")]
    [InlineData("amenity", "biergarten", "alcohol")]
    [InlineData("amenity", "casino", "gambling")]
    [InlineData("leisure", "adult_gaming_centre", "gambling")]
    [InlineData("shop", "bookmaker", "gambling")]
    [InlineData("shop", "lottery", "gambling")]
    [InlineData("shop", "tobacco", "tobacco")]
    [InlineData("shop", "e-cigarette", "tobacco")]
    public void Osm_tags_become_warnings(string key, string value, string warning) =>
        Assert.Equal([warning], PlaceWarnings.FromOsmTags(new Dictionary<string, string> { [key] = value }));

    [Fact]
    public void Ordinary_osm_places_have_no_warnings()
    {
        Assert.Null(PlaceWarnings.FromOsmTags(new Dictionary<string, string> { ["amenity"] = "restaurant" }));
        Assert.Null(PlaceWarnings.FromOsmTags(new Dictionary<string, string>()));
        Assert.Null(PlaceWarnings.FromOsmTags(null));
    }

    [Fact]
    public void Ai_sensitive_codes_stay_in_the_place_reasons_but_warn()
    {
        var v = PlaceScreening.Normalize("publish", "high", ["sensitive_alcohol"]);
        Assert.Equal(["sensitive_alcohol"], v.Reasons);
        Assert.Equal(["alcohol"], PlaceWarnings.FromReasonCodes(v.Reasons));
    }

    // ---- wire shapes -------------------------------------------------------------------------------

    [Fact]
    public void New_optional_fields_are_omitted_from_json_when_empty_and_snake_case_when_present()
    {
        var summary = new PlaceSummary("n1", "Kedai", PlaceCategory.Convenience, "", 3, 101, null, null);
        Assert.DoesNotContain("warnings", JsonSerializer.Serialize(summary, GimanoJson.Options));
        Assert.Contains("\"warnings\":[\"alcohol\"]", JsonSerializer.Serialize(summary with { Warnings = ["alcohol"] }, GimanoJson.Options));

        var moderation = new ContentModerationDto(ContentState.Held, ["unclear"], false);
        Assert.Equal("""{"state":"held","reasons":["unclear"],"canAppeal":false}""", JsonSerializer.Serialize(moderation, GimanoJson.Options));

        var photo = new PhotoDto(Guid.Empty, null, null, 1, 1, null, new AddedBy("x"), DateTimeOffset.UnixEpoch, PhotoStatus.Processing);
        Assert.DoesNotContain("moderation", JsonSerializer.Serialize(photo, GimanoJson.Options));

        var report = ReportCreatedDto.From(new ReportDto(Guid.Empty, ReportType.Hazard, null, 3, 101, null, null, new ReportedBy("a", "b"),
            DateTimeOffset.UnixEpoch, DateTimeOffset.UnixEpoch, 0, 0));
        var plain = JsonSerializer.Serialize(report, GimanoJson.Options);
        Assert.DoesNotContain("note", plain);
        var dropped = JsonSerializer.Serialize(ReportCreatedDto.From(report, true, ["external_contact"]), GimanoJson.Options);
        Assert.Contains("\"noteDropped\":true", dropped);
        Assert.Contains("\"noteReasons\":[\"external_contact\"]", dropped);
    }

    [Fact]
    public void Content_inbox_items_carry_subject_reasons_and_appeal()
    {
        var item = new InboxItemDto(Guid.Empty, InboxKind.ContentRejected, "t", "b", "review", "r1", DateTimeOffset.UnixEpoch, false, 1,
            "review", "r1", "n77", ["gambling_promo"], true);
        var json = JsonSerializer.Serialize(item, GimanoJson.Options);
        Assert.Contains("\"kind\":\"content_rejected\"", json);
        Assert.Contains("\"subjectKind\":\"review\"", json);
        Assert.Contains("\"placeId\":\"n77\"", json);
        Assert.Contains("\"reasons\":[\"gambling_promo\"]", json);
        Assert.Contains("\"canAppeal\":true", json);
        Assert.DoesNotContain("subjectKind", JsonSerializer.Serialize(item with { SubjectKind = null }, GimanoJson.Options));
    }

    [Theory]
    [InlineData(InboxKind.ContentPublished, "Your post at Kedai Mak Teh is now live")]
    [InlineData(InboxKind.ContentHeld, "Your post at Kedai Mak Teh: a maintainer will check it")]
    [InlineData(InboxKind.ContentRejected, "Your post at Kedai Mak Teh was not accepted")]
    public void Content_inbox_texts_name_the_place(InboxKind kind, string title)
    {
        Assert.Equal(title, InboxRules.Text(kind, 1, "en", "Kedai Mak Teh").Title);
        Assert.Contains("Kedai Mak Teh", InboxRules.Text(kind, 1, "ms", "Kedai Mak Teh").Title);
        var item = new InboxItem { UserId = Guid.NewGuid(), Kind = kind, Title = "stored", Subject = "Kedai Mak Teh" };
        Assert.Equal(title, InboxRules.Render(item, "en").Title);
    }

    [Fact]
    public void Screening_jpeg_is_small_metadata_free_and_upright()
    {
        using var bmp = new SKBitmap(1600, 1200);
        using (var canvas = new SKCanvas(bmp)) canvas.Clear(SKColors.SteelBlue);
        using var img = SKImage.FromBitmap(bmp);
        var webp = img.Encode(SKEncodedImageFormat.Webp, 80).ToArray();

        var jpeg = ImageProcessor.ToScreeningJpeg(webp);
        Assert.Equal([0xFF, 0xD8], jpeg[..2]);
        using var codec = SKCodec.Create(new SKMemoryStream(jpeg))!;
        Assert.Equal(SKEncodedImageFormat.Jpeg, codec.EncodedFormat);
        Assert.Equal((1024, 768), (codec.Info.Width, codec.Info.Height));
        // No EXIF (APP1 "Exif") segment: Skia's encoder writes none.
        Assert.False(System.Text.Encoding.Latin1.GetString(jpeg).Contains("Exif\0\0", StringComparison.Ordinal));
        Assert.Throws<ImageRejectedException>(() => ImageProcessor.ToScreeningJpeg([1, 2, 3]));
    }
}
