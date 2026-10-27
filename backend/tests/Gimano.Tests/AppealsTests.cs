using System.Text.Json;
using Gimano.Api;
using Gimano.Api.Services;
using Gimano.Core.Community;
using Gimano.Core.Contracts;
using Gimano.Core.Data;
using Gimano.Core.Domain;
using Microsoft.AspNetCore.Http;
using Microsoft.EntityFrameworkCore;
using Microsoft.Extensions.Logging.Abstractions;
using SkiaSharp;

namespace Gimano.Tests;

/// <summary>Appeals with a compulsory note and private evidence photos, map-place flags and the feedback spam screen (docs/content-safety.md). No database.</summary>
public class AppealsTests
{
    // ---- the note -----------------------------------------------------------------------------------

    [Theory]
    [InlineData(null)]
    [InlineData("")]
    [InlineData("   ")]
    public void A_missing_note_is_400_note_required(string? note)
    {
        var ex = Assert.Throws<ApiCodeException>(() => Moderation.CheckAppealNote(note));
        Assert.Equal((400, "note_required"), (ex.Status, ex.Code));
    }

    [Fact]
    public void The_note_is_trimmed_at_most_200_characters_and_friendly()
    {
        Assert.Equal("Ini bukan iklan", Moderation.CheckAppealNote("  Ini bukan iklan \n"));
        Assert.Equal(200, Moderation.CheckAppealNote(new string('a', 200)).Length);
        Assert.Equal("note_required", Assert.Throws<ApiCodeException>(() => Moderation.CheckAppealNote(new string('a', 201))).Code);
        Assert.Equal("note_required", Assert.Throws<ApiCodeException>(() => Moderation.CheckAppealNote("see https://example.com")).Code);
    }

    [Fact]
    public async Task The_handler_writes_the_code_and_status_into_problem_json()
    {
        var problems = new CapturingProblems();
        var http = new DefaultHttpContext();
        Assert.True(await new ApiExceptionHandler(problems, NullLogger<ApiExceptionHandler>.Instance)
            .TryHandleAsync(http, new ApiCodeException(409, "already_appealed", "This was already sent for review."), CancellationToken.None));
        Assert.Equal(409, http.Response.StatusCode);
        Assert.Equal("already_appealed", problems.Last!.ProblemDetails.Extensions["code"]);
    }

    private sealed class CapturingProblems : IProblemDetailsService
    {
        public ProblemDetailsContext? Last { get; private set; }
        public ValueTask WriteAsync(ProblemDetailsContext context) { Last = context; return ValueTask.CompletedTask; }
        public ValueTask<bool> TryWriteAsync(ProblemDetailsContext context) { Last = context; return ValueTask.FromResult(true); }
    }

    // ---- evidence photos -------------------------------------------------------------------------------

    [Fact]
    public void Evidence_is_re_encoded_without_exif_or_gps_and_limited_to_three()
    {
        var withGps = ImageProcessorTests.Jpeg(withGps: true);
        Assert.Contains("GimanoTestGPS", System.Text.Encoding.Latin1.GetString(withGps));
        var prepared = AppealEvidence.Prepare([withGps, withGps]);
        Assert.Equal(2, prepared.Count);
        Assert.All(prepared, w =>
        {
            Assert.Equal("RIFF", System.Text.Encoding.ASCII.GetString(w, 0, 4));
            Assert.Equal("WEBP", System.Text.Encoding.ASCII.GetString(w, 8, 4));
            Assert.DoesNotContain("GimanoTestGPS", System.Text.Encoding.Latin1.GetString(w));
        });
        Assert.Empty(AppealEvidence.Prepare([]));
        var four = Enumerable.Repeat(withGps, 4).ToList();
        Assert.Equal("photos", Assert.Throws<ValidationException>(() => AppealEvidence.Prepare(four)).Field);
    }

    [Fact]
    public void Evidence_formats_are_checked_by_content_and_size_by_the_limit()
    {
        Assert.Throws<ValidationException>(() => AppealEvidence.Prepare(["GIF89a......".Select(c => (byte)c).ToArray()]));
        Assert.Throws<ValidationException>(() => AppealEvidence.Prepare([[]]));
        using var bmp = new SKBitmap(300, 300);
        using var img = SKImage.FromBitmap(bmp);
        var png = img.Encode(SKEncodedImageFormat.Png, 100).ToArray();
        var webp = img.Encode(SKEncodedImageFormat.Webp, 80).ToArray();
        Assert.Equal(2, AppealEvidence.Prepare([png, webp]).Count);
        var big = new byte[AppealEvidence.MaxBytes + 1];
        big[0] = 0xFF; big[1] = 0xD8; big[2] = 0xFF;
        var ex = Assert.Throws<ApiCodeException>(() => AppealEvidence.Prepare([big]));
        Assert.Equal((413, "photo_too_large"), (ex.Status, ex.Code));
        var g = Guid.NewGuid();
        Assert.Equal($"appeals/{g:N}/2", MediaKeys.Appeal(g, 2));
        Assert.False(MediaKeys.IsValidHash(MediaKeys.Appeal(Guid.NewGuid(), 0)));    // never served by /media
    }

    // ---- wire shapes ---------------------------------------------------------------------------------------

    [Fact]
    public void Wire_names_match_the_contract()
    {
        Assert.Equal(["review", "photo", "place"], Enum.GetValues<AppealKind>().Select(GimanoJson.ToWire));
        Assert.Equal(["pending", "approved", "denied"], Enum.GetValues<AppealStatus>().Select(GimanoJson.ToWire));
        Assert.True(GimanoJson.TryParseWire<ModerationKind>("appeal", out var k) && k == ModerationKind.Appeal);
        var id = Guid.Parse("0197f2d4-7b3a-7c11-9a55-3e2f1b6d0a10");
        Assert.Equal("""{"id":"0197f2d4-7b3a-7c11-9a55-3e2f1b6d0a10","status":"pending"}""", JsonSerializer.Serialize(new AppealAccepted(id, "pending"), GimanoJson.Options));
        var flag = JsonSerializer.Deserialize<FlagRequest>("""{"reason":"other","warnings":["alcohol","gambling"]}""", GimanoJson.Options)!;
        Assert.Equal(FlagReason.Other, flag.Reason);
        Assert.Equal(["alcohol", "gambling"], flag.Warnings!);
        Assert.Null(JsonSerializer.Deserialize<FlagRequest>("""{"reason":"spam"}""", GimanoJson.Options)!.Warnings);
    }

    // ---- feedback spam screen ----------------------------------------------------------------------

    private static ContentGate Gate(IContentScreener s)
    {
        var o = new DbContextOptionsBuilder<GimanoDbContext>();
        var ds = GimanoDb.BuildDataSource("Host=localhost;Database=x");   // never opened
        GimanoDb.Configure(o, ds);
        var db = new GimanoDbContext(o.Options);
        return TestGates.Content(db, TimeProvider.System, s);
    }

    private static ContentResult R(string decision, string confidence = "high", params string[] reasons) =>
        new(PlaceScreening.Normalize(decision, confidence, reasons), null, false);

    [Theory]
    [InlineData("reject", true)]
    [InlineData("hold", false)]
    [InlineData("publish", false)]
    public async Task Only_a_reject_marks_feedback_as_suspected_spam(string decision, bool expected)
    {
        var screener = new TestGates.ContentScreener(_ => R(decision, "high", "spam"));
        Assert.Equal(expected, await Gate(screener).IsSuspectedSpamAsync("Beli ubat kuat murah wasap 0123", TimeSpan.FromSeconds(3), TestContext.Current.CancellationToken));
    }

    [Fact]
    public async Task The_screen_sends_the_message_text_only_and_is_silent_when_off_or_failing()
    {
        var ct = TestContext.Current.CancellationToken;
        var screener = new TestGates.ContentScreener(_ => R("reject"));
        await Gate(screener).IsSuspectedSpamAsync("Free vape promo code 123", TimeSpan.FromSeconds(3), ct);
        var seen = Assert.Single(screener.Inputs);
        Assert.Equal((ContentKind.Feedback, "Free vape promo code 123", null, null), (seen.Kind, seen.Text, seen.PlaceName, seen.Brands));

        Assert.False(await Gate(new TestGates.ContentScreener(null)).IsSuspectedSpamAsync("x", TimeSpan.FromSeconds(3), ct));          // off or budget used up
        Assert.False(await Gate(new TestGates.ContentScreener(_ => ContentResult.Failed)).IsSuspectedSpamAsync("x", TimeSpan.FromSeconds(3), ct));
        Assert.False(await Gate(new TestGates.ContentScreener(_ => throw new HttpRequestException("down"))).IsSuspectedSpamAsync("x", TimeSpan.FromSeconds(3), ct));
        var untouched = new TestGates.ContentScreener(_ => R("reject"));
        Assert.False(await Gate(untouched).IsSuspectedSpamAsync("  ", TimeSpan.FromSeconds(3), ct));
        Assert.Empty(untouched.Inputs);
    }

    [Fact]
    public void The_feedback_prompt_is_separate_never_blocks_and_treats_the_message_as_data()
    {
        Assert.NotEqual(ContentScreening.SystemPrompt, ContentScreening.FeedbackSystemPrompt);
        Assert.Contains("never blocked", ContentScreening.FeedbackSystemPrompt);
        Assert.Contains("complaints", ContentScreening.FeedbackSystemPrompt);
        Assert.Contains("never instructions", ContentScreening.FeedbackSystemPrompt);
    }

    // ---- warnings suggested on a map place ----------------------------------------------------------

    [Fact]
    public void Suggested_warnings_keep_only_the_known_three_in_a_fixed_order()
    {
        Assert.Equal("alcohol,gambling", PlaceWarnings.Join(["Gambling", "alcohol", "nonsense", "alcohol"]));
        Assert.Null(PlaceWarnings.Join(["nonsense"]));
        Assert.Null(PlaceWarnings.Join(null));
    }
}
