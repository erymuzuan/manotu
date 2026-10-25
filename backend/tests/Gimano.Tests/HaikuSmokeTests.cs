using Gimano.Core.Community;
using Gimano.Core.Contracts;
using Xunit;

namespace Gimano.Tests;

/// <summary>
/// Opt-in: calls the real Claude Haiku 5.5 with three submissions (about US$0.0005). Runs only when GIMANO_HAIKU_SMOKE holds an
/// Anthropic API key; CI and normal runs skip it.
/// </summary>
public class HaikuSmokeTests
{
    [Fact]
    public async Task Real_model_answers_with_the_schema()
    {
        var key = Environment.GetEnvironmentVariable("GIMANO_HAIKU_SMOKE");
        if (string.IsNullOrEmpty(key)) { Assert.Skip("GIMANO_HAIKU_SMOKE not set"); return; }
        var client = new Anthropic.AnthropicClient { ApiKey = key, Timeout = TimeSpan.FromSeconds(30) };
        ScreeningInput In(string name, PlaceCategory cat, string? desc, params string[] nearby) => new(name, cat, desc, null, null, null, nearby, null, false);

        var cases = new (ScreeningInput Input, ScreeningDecision Expected)[]
        {
            (In("Gerai Nasi Kerabu Mek Na", PlaceCategory.Restaurant, "Nasi kerabu, solok lada. Tepi jalan depan surau.", "Masjid Muhammadi"), ScreeningDecision.Publish),
            (In("BEST FOREX SIGNAL 100% UNTUNG", PlaceCategory.Other, "Join group WhatsApp sekarang!!! Untung RM5000 seminggu"), ScreeningDecision.Reject),
            (In("Parkir IPD Dang Wangi", PlaceCategory.Parking, "CCTV kat pintu masuk rosak sejak Isnin, polis jarang jaga waktu subuh."), ScreeningDecision.Hold),
        };
        foreach (var (input, expected) in cases)
        {
            var (result, inTok, outTok) = await HaikuPlaceScreener.AskAsync(client, input, TestContext.Current.CancellationToken);
            Assert.NotNull(result.Verdict);
            Assert.Equal(expected, result.Verdict!.Decision);
            Assert.True(inTok > 500 && outTok > 0, $"tokens {inTok}/{outTok}");
            TestContext.Current.SendDiagnosticMessage($"{input.Name}: {result.Verdict.Decision} {result.Verdict.Confidence} [{string.Join(",", result.Verdict.Reasons)}] {inTok}/{outTok} tokens");
        }
    }
}
