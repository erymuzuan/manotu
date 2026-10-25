using System.Text.Json;
using Anthropic;
using Anthropic.Models.Messages;
using Gimano.Core.Data;
using Gimano.Core.Domain;
using Microsoft.EntityFrameworkCore;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Options;

namespace Gimano.Core.Community;

public sealed class ScreeningOptions
{
    public const string Section = "Screening";
    /// <summary>Anthropic API key (env CLAUDE_API_KEY). Empty = the AI check is off and places follow the plain vetting rules.</summary>
    public string? ApiKey { get; set; }
    /// <summary>US$ per week (Malaysia time, Monday to Sunday); clamped to <see cref="PlaceScreening.MaxWeeklyBudgetUsd"/>.</summary>
    public decimal WeeklyBudgetUsd { get; set; } = PlaceScreening.MaxWeeklyBudgetUsd;

    public bool Enabled => !string.IsNullOrWhiteSpace(ApiKey);
}

/// <summary>
/// The answer, or none: <see cref="Unavailable"/> when the check is off or this week's budget is used up (the place follows the
/// plain vetting rules); neither when the call failed or timed out (the worker tries again).
/// </summary>
public sealed record ScreeningResult(ScreeningVerdict? Verdict, bool Unavailable)
{
    public static readonly ScreeningResult Off = new(null, true);
    public static readonly ScreeningResult Failed = new(null, false);
}

/// <summary>Asks the model about one submission.</summary>
public interface IPlaceScreener
{
    Task<ScreeningResult> ScreenAsync(ScreeningInput input, CancellationToken ct);
    bool Enabled { get; }
}

/// <summary>
/// Claude Haiku 5.5, and only that model. Every call is recorded in <c>ai_usage_weeks</c> (tokens and US$), and no call is made
/// once this week's spend has reached the budget. Submission text is never logged.
/// </summary>
public sealed class HaikuPlaceScreener(GimanoDbContext db, IOptions<ScreeningOptions> options, TimeProvider clock, ILogger<HaikuPlaceScreener> logger)
    : IPlaceScreener
{
    private static AnthropicClient? s_client;
    private static readonly object s_lock = new();

    public bool Enabled => options.Value.Enabled;

    private static readonly Dictionary<string, JsonElement> Schema = JsonSerializer.Deserialize<Dictionary<string, JsonElement>>("""
        {
          "type": "object",
          "properties": {
            "decision": { "type": "string", "enum": ["publish", "hold", "reject"] },
            "confidence": { "type": "string", "enum": ["high", "medium", "low"] },
            "reasons": { "type": "array", "items": { "type": "string" } }
          },
          "required": ["decision", "confidence", "reasons"],
          "additionalProperties": false
        }
        """)!;

    public async Task<ScreeningResult> ScreenAsync(ScreeningInput input, CancellationToken ct)
    {
        var o = options.Value;
        if (!o.Enabled) return ScreeningResult.Off;
        var week = PlaceScreening.WeekOf(clock.GetUtcNow());
        var spent = await db.AiUsageWeeks.AsNoTracking().Where(w => w.WeekStart == week).Select(w => (decimal?)w.CostUsd).FirstOrDefaultAsync(ct) ?? 0m;
        if (spent >= PlaceScreening.EffectiveBudget(o.WeeklyBudgetUsd))
        {
            logger.LogWarning("Place screening skipped: this week's AI budget (US${Budget}) is used up", PlaceScreening.EffectiveBudget(o.WeeklyBudgetUsd));
            return ScreeningResult.Off;
        }

        var (result, inputTokens, outputTokens) = await AskAsync(Client(o.ApiKey!), input, ct);
        if (inputTokens + outputTokens > 0) await RecordAsync(week, inputTokens, outputTokens, CancellationToken.None);
        if (result.Verdict is null) logger.LogWarning("Place screening returned no usable answer");
        return result;
    }

    /// <summary>One call to Haiku 5.5: the answer and the tokens it cost (0 when the call itself failed). No logging of content.</summary>
    internal static async Task<(ScreeningResult Result, long InputTokens, long OutputTokens)> AskAsync(AnthropicClient client, ScreeningInput input,
        CancellationToken ct)
    {
        var user = JsonSerializer.Serialize(new
        {
            submission = new
            {
                name = input.Name, category = Contracts.GimanoJson.ToWire(input.Category), description = input.Description,
                openingHours = input.OpeningHours, phone = input.Phone, website = input.Website,
            },
            nearby = input.NearbyNames, saidDifferentFrom = input.SaidDifferentFrom, isEdit = input.IsEdit,
        });
        var parameters = new MessageCreateParams
        {
            Model = PlaceScreening.Model,
            MaxTokens = 1024,
            System = PlaceScreening.SystemPrompt,
            Messages = [new UserMessageParam { Content = user }],
            OutputConfig = new OutputConfig { Effort = Effort.Low, Format = new JsonOutputFormat { Schema = Schema } },
        };

        Message reply;
        try { reply = await client.Messages.Create(parameters, ct); }
        catch (Exception ex) when (ex is not OperationCanceledException) { return (ScreeningResult.Failed, 0, 0); }

        var inputTokens = reply.Usage.InputTokens + (reply.Usage.CacheReadInputTokens ?? 0) + (reply.Usage.CacheCreationInputTokens ?? 0);
        var outputTokens = reply.Usage.OutputTokens;
        if (reply.StopReason?.Raw() is not "end_turn") return (ScreeningResult.Failed, inputTokens, outputTokens);
        var text = string.Concat(reply.Content.Select(b => b.TryPickText(out var t) ? t.Text : ""));
        try
        {
            using var doc = JsonDocument.Parse(text);
            var root = doc.RootElement;
            var reasons = root.TryGetProperty("reasons", out var r) && r.ValueKind == JsonValueKind.Array
                ? r.EnumerateArray().Where(x => x.ValueKind == JsonValueKind.String).Select(x => x.GetString()!).ToList() : [];
            return (new ScreeningResult(PlaceScreening.Normalize(root.GetProperty("decision").GetString(),
                root.TryGetProperty("confidence", out var c) ? c.GetString() : null, reasons), false), inputTokens, outputTokens);
        }
        catch (Exception ex) when (ex is JsonException or KeyNotFoundException or InvalidOperationException)
        {
            return (ScreeningResult.Failed, inputTokens, outputTokens);
        }
    }

    /// <summary>Adds one call to this week's row (an atomic upsert, so concurrent api and worker calls add up correctly).</summary>
    internal async Task RecordAsync(DateOnly week, long inputTokens, long outputTokens, CancellationToken ct)
    {
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

    internal static AnthropicClient Client(string key)
    {
        lock (s_lock) return s_client ??= new AnthropicClient { ApiKey = key, Timeout = TimeSpan.FromSeconds(30) };
    }
}

public static class ScreeningSetup
{
    /// <summary>The AI place check and the vetting switches (api and worker). The key also comes from env CLAUDE_API_KEY.</summary>
    public static Microsoft.Extensions.DependencyInjection.IServiceCollection AddGimanoScreening(
        this Microsoft.Extensions.DependencyInjection.IServiceCollection services, Microsoft.Extensions.Configuration.IConfiguration config)
    {
        Microsoft.Extensions.DependencyInjection.OptionsConfigurationServiceCollectionExtensions.Configure<ScreeningOptions>(services, config.GetSection(ScreeningOptions.Section));
        Microsoft.Extensions.DependencyInjection.OptionsServiceCollectionExtensions.PostConfigure<ScreeningOptions>(services,
            o => o.ApiKey = string.IsNullOrWhiteSpace(o.ApiKey) ? Environment.GetEnvironmentVariable("CLAUDE_API_KEY") : o.ApiKey);
        Microsoft.Extensions.DependencyInjection.OptionsConfigurationServiceCollectionExtensions.Configure<Identity.VettingOptions>(services, config.GetSection(Identity.VettingOptions.Section));
        Microsoft.Extensions.DependencyInjection.ServiceCollectionServiceExtensions.AddScoped<IPlaceScreener, HaikuPlaceScreener>(services);
        Microsoft.Extensions.DependencyInjection.ServiceCollectionServiceExtensions.AddScoped<PlaceGate>(services);
        return services;
    }
}
