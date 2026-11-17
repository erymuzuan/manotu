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
using Microsoft.Extensions.Options;
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

    [Fact]
    public async Task Private_feedback_never_reaches_an_enabled_external_screener()
    {
        var screener = new TestGates.ContentScreener(_ => throw new InvalidOperationException("Private feedback must not be screened"));
        var gate = Gate(screener);
        Assert.False(await gate.IsSuspectedSpamAsync("A private feedback message", TimeSpan.FromSeconds(3), TestContext.Current.CancellationToken));
        Assert.False(await gate.IsSuspectedSpamAsync("  ", TimeSpan.FromSeconds(3), TestContext.Current.CancellationToken));
        var input = new ContentInput(ContentKind.Feedback, "A private feedback message");
        Assert.Equal(ContentOutcomeKind.Skipped, (await gate.CheckTextAsync(input, null, TestContext.Current.CancellationToken)).Kind);
        Assert.Equal(ContentOutcomeKind.Skipped, (await gate.CheckImageAsync([1, 2, 3], input, null, TestContext.Current.CancellationToken)).Kind);
        Assert.Empty(screener.Inputs);
    }

    [Fact]
    public async Task Haiku_screener_refuses_private_feedback_even_when_called_directly()
    {
        var options = new DbContextOptionsBuilder<GimanoDbContext>();
        var ds = GimanoDb.BuildDataSource("Host=localhost;Database=x"); // never opened
        GimanoDb.Configure(options, ds);
        await using var db = new GimanoDbContext(options.Options);
        var screener = new HaikuContentScreener(db, Options.Create(new ScreeningOptions { ApiKey = "test-only" }), TimeProvider.System, NullLogger<HaikuContentScreener>.Instance);
        var input = new ContentInput(ContentKind.Feedback, "A private feedback message");
        var ct = TestContext.Current.CancellationToken;
        Assert.Equal(ContentResult.Off, await screener.ScreenTextAsync(input, ct));
        Assert.Equal(ContentResult.Off, await screener.ScreenImageAsync([1, 2, 3], input, ct));
        Assert.Equal((ContentResult.Off, 0L, 0L), await HaikuContentScreener.AskAsync(null!, null, input, ct));
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
