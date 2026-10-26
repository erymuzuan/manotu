using System.Text.Json;
using Anthropic;
using Anthropic.Models.Messages;
using Gimano.Core.Contracts;
using Gimano.Core.Data;
using Microsoft.EntityFrameworkCore;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Options;

namespace Gimano.Core.Community;

/// <summary>The weekly AI budget table (ai_usage_weeks), shared by the place check and the content check (US$20 a week at most).</summary>
public static class AiBudget
{
    public static async Task<bool> AvailableAsync(GimanoDbContext db, ScreeningOptions o, TimeProvider clock, CancellationToken ct)
    {
        var week = PlaceScreening.WeekOf(clock.GetUtcNow());
        var spent = await db.AiUsageWeeks.AsNoTracking().Where(w => w.WeekStart == week).Select(w => (decimal?)w.CostUsd).FirstOrDefaultAsync(ct) ?? 0m;
        return spent < PlaceScreening.EffectiveBudget(o.WeeklyBudgetUsd);
    }

    /// <summary>Adds one call to this week's row (an atomic upsert, so concurrent api and worker calls add up correctly).</summary>
    public static async Task RecordAsync(GimanoDbContext db, TimeProvider clock, long inputTokens, long outputTokens, CancellationToken ct)
    {
        var week = PlaceScreening.WeekOf(clock.GetUtcNow());
        var cost = PlaceScreening.CostUsd(inputTokens, outputTokens);
        var now = clock.GetUtcNow();
        await db.Database.ExecuteSqlInterpolatedAsync($"""
            INSERT INTO ai_usage_weeks (week_start, calls, input_tokens, output_tokens, cost_usd, updated_at)
            VALUES ({week}, 1, {inputTokens}, {outputTokens}, {cost}, {now})
            ON CONFLICT (week_start) DO UPDATE SET calls = ai_usage_weeks.calls + 1,
              input_tokens = ai_usage_weeks.input_tokens + EXCLUDED.input_tokens,
              output_tokens = ai_usage_weeks.output_tokens + EXCLUDED.output_tokens,
              cost_usd = ai_usage_weeks.cost_usd + EXCLUDED.cost_usd, updated_at = EXCLUDED.updated_at
            """, ct);
    }
}

/// <summary>
/// Claude Haiku 5.5 only (like the place check) for reviews, review edits, report notes and photos. Every call is recorded in
/// <c>ai_usage_weeks</c>; no call is made once this week's spend has reached the budget. The model sees only the public text or the
/// metadata-free image and the place's public name; content is never logged.
/// </summary>
public sealed class HaikuContentScreener(GimanoDbContext db, IOptions<ScreeningOptions> options, TimeProvider clock, ILogger<HaikuContentScreener> logger)
    : IContentScreener
{
    public bool Enabled => options.Value.Enabled;

    private static readonly Dictionary<string, JsonElement> Schema = JsonSerializer.Deserialize<Dictionary<string, JsonElement>>("""
        {
          "type": "object",
          "properties": {
            "decision": { "type": "string", "enum": ["publish", "hold", "reject"] },
            "confidence": { "type": "string", "enum": ["high", "medium", "low"] },
            "reasons": { "type": "array", "items": { "type": "string" } },
            "safeText": { "type": "string" }
          },
          "required": ["decision", "confidence", "reasons"],
          "additionalProperties": false
        }
        """)!;

    public Task<ContentResult> ScreenTextAsync(ContentInput input, CancellationToken ct) => RunAsync(null, input, ct);

    public Task<ContentResult> ScreenImageAsync(byte[] jpeg, ContentInput context, CancellationToken ct) => RunAsync(jpeg, context, ct);

    private async Task<ContentResult> RunAsync(byte[]? jpeg, ContentInput input, CancellationToken ct)
    {
        var o = options.Value;
        if (!o.Enabled) return ContentResult.Off;
        if (!await AiBudget.AvailableAsync(db, o, clock, ct))
        {
            logger.LogWarning("Content screening skipped: this week's AI budget (US${Budget}) is used up", PlaceScreening.EffectiveBudget(o.WeeklyBudgetUsd));
            return ContentResult.Off;
        }
        var (result, inputTokens, outputTokens) = await AskAsync(HaikuPlaceScreener.Client(o.ApiKey!), jpeg, input, ct);
        if (inputTokens + outputTokens > 0) await AiBudget.RecordAsync(db, clock, inputTokens, outputTokens, CancellationToken.None);
        if (result.Verdict is null) logger.LogWarning("Content screening returned no usable answer");
        return result;
    }

    /// <summary>One call to Haiku 5.5: the answer and the tokens it cost (0 when the call itself failed). No logging of content.</summary>
    internal static async Task<(ContentResult Result, long InputTokens, long OutputTokens)> AskAsync(AnthropicClient client, byte[]? jpeg, ContentInput input,
        CancellationToken ct)
    {
        var payload = JsonSerializer.Serialize(new
        {
            kind = input.Kind switch { ContentKind.Review => "review", ContentKind.ReviewEdit => "review", ContentKind.ReportNote => "road_report_note", _ => "photo" },
            isEdit = input.Kind == ContentKind.ReviewEdit,
            place = input.PlaceName,
            text = input.Kind == ContentKind.Photo ? null : input.Text,
            caption = input.Kind == ContentKind.Photo ? input.Text : null,
            watchlist = input.Brands is { Count: > 0 } b ? b.Select(x => new { brand = x.Name, group = GimanoJson.ToWire(x.Group) }) : null,
        });
        UserMessageParam message;
        if (jpeg is null) message = new UserMessageParam { Content = payload };
        else
            message = new UserMessageParam
            {
                Content = new List<ContentBlockParam>
                {
                    new ImageBlockParam { Source = new Base64ImageSource { Data = Convert.ToBase64String(jpeg), MediaType = MediaType.ImageJpeg } },
                    new TextBlockParam { Text = payload },
                },
            };
        var parameters = new MessageCreateParams
        {
            Model = ContentScreening.Model,
            MaxTokens = 1024,
            System = ContentScreening.SystemPrompt,
            Messages = [message],
            OutputConfig = new OutputConfig { Effort = Effort.Low, Format = new JsonOutputFormat { Schema = Schema } },
        };

        Message reply;
        try { reply = await client.Messages.Create(parameters, ct); }
        catch (Exception ex) when (ex is not OperationCanceledException) { return (ContentResult.Failed, 0, 0); }

        var inputTokens = reply.Usage.InputTokens + (reply.Usage.CacheReadInputTokens ?? 0) + (reply.Usage.CacheCreationInputTokens ?? 0);
        var outputTokens = reply.Usage.OutputTokens;
        if (reply.StopReason?.Raw() is not "end_turn") return (ContentResult.Failed, inputTokens, outputTokens);
        var text = string.Concat(reply.Content.Select(c => c.TryPickText(out var t) ? t.Text : ""));
        try
        {
            using var doc = JsonDocument.Parse(text);
            var root = doc.RootElement;
            var reasons = root.TryGetProperty("reasons", out var r) && r.ValueKind == JsonValueKind.Array
                ? r.EnumerateArray().Where(x => x.ValueKind == JsonValueKind.String).Select(x => x.GetString()!).ToList() : [];
            var verdict = PlaceScreening.Normalize(root.GetProperty("decision").GetString(),
                root.TryGetProperty("confidence", out var c) ? c.GetString() : null, reasons);
            var safe = root.TryGetProperty("safeText", out var st) && st.ValueKind == JsonValueKind.String ? st.GetString() : null;
            return (new ContentResult(verdict, safe, false), inputTokens, outputTokens);
        }
        catch (Exception ex) when (ex is JsonException or KeyNotFoundException or InvalidOperationException)
        {
            return (ContentResult.Failed, inputTokens, outputTokens);
        }
    }
}
