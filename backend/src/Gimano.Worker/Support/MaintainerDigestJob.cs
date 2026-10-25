using Azure.Communication.Email;
using Gimano.Core.Data;
using Gimano.Core.Support;
using Microsoft.Extensions.Options;

namespace Gimano.Worker.Support;

public sealed class DigestOptions
{
    public const string Section = "Digest";
    /// <summary>Azure Communication Services connection string (env DIGEST_ACS_CONNECTION_STRING). Empty = digest off.</summary>
    public string? AcsConnectionString { get; set; }
    /// <summary>A sender on a domain verified in that ACS resource.</summary>
    public string From { get; set; } = "DoNotReply@bukitbunga.com";
    /// <summary>Maintainer addresses (Digest:To:0, Digest:To:1, …); an entry may hold several, comma-separated.</summary>
    public List<string> To { get; set; } = [];

    public IReadOnlyList<string> Recipients =>
        To.SelectMany(t => t.Split([',', ';'], StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries)).Distinct(StringComparer.OrdinalIgnoreCase).ToList();
    /// <summary>Hour of the day (Malaysia time) the daily digest goes out.</summary>
    public int SendAtHour { get; set; } = 8;
    /// <summary>Skip the daily email when there is nothing to report.</summary>
    public bool SkipWhenQuiet { get; set; } = true;
    public string BackOfficeUrl { get; set; } = "http://100.101.150.9:5090";

    public bool Enabled => !string.IsNullOrWhiteSpace(AcsConnectionString) && Recipients.Count > 0;
}

/// <summary>Sends one email to the maintainers. Implemented with ACS; a seam for tests.</summary>
public interface IMaintainerMailer
{
    Task SendAsync(MaintainerDigest.Message message, CancellationToken ct);
}

public sealed class AcsMaintainerMailer(IOptions<DigestOptions> options) : IMaintainerMailer
{
    private readonly EmailClient _client = new(options.Value.AcsConnectionString);

    public async Task SendAsync(MaintainerDigest.Message message, CancellationToken ct)
    {
        var o = options.Value;
        var recipients = new EmailRecipients(o.Recipients.Select(t => new EmailAddress(t)).ToList());
        var email = new EmailMessage(o.From, recipients, new EmailContent(message.Subject) { PlainText = message.Text, Html = message.Html });
        // Started, not awaited to completion: ACS delivery status is not needed for an internal digest.
        await _client.SendAsync(Azure.WaitUntil.Started, email, ct);
    }
}

/// <summary>
/// Every 15 minutes: sends the daily counts-only digest once per Malaysia day after Digest:SendAtHour, and a moderation alert
/// when an item has waited 20 h (at most every 12 h). State is in memory: the digest is only sent within its hour, so a restart
/// can repeat it only inside that hour, and a worker that is down for the whole hour skips that day's digest.
/// </summary>
public sealed class MaintainerDigestJob(IServiceScopeFactory scopes, IMaintainerMailer mailer, IOptions<DigestOptions> options,
    TimeProvider clock, ILogger<MaintainerDigestJob> logger) : BackgroundService
{
    private DateOnly? _lastDigestDay;
    private DateTimeOffset? _lastAlert;

    protected override async Task ExecuteAsync(CancellationToken stoppingToken)
    {
        using var timer = new PeriodicTimer(TimeSpan.FromMinutes(15), clock);
        do
        {
            try { await TickAsync(stoppingToken); }
            catch (Exception ex) when (ex is not OperationCanceledException) { logger.LogWarning("Maintainer digest failed: {Message}", ex.Message); }
        } while (await timer.WaitForNextTickAsync(stoppingToken));
    }

    internal async Task TickAsync(CancellationToken ct)
    {
        var now = clock.GetUtcNow();
        var o = options.Value;
        var digestDue = MaintainerDigest.DigestDue(now, o.SendAtHour, _lastDigestDay);
        if (!digestDue && _lastAlert is { } last && now - last < MaintainerDigest.AlertCooldown) return;

        await using var scope = scopes.CreateAsyncScope();
        var db = scope.ServiceProvider.GetRequiredService<GimanoDbContext>();
        var counts = await MaintainerDigest.CountAsync(db, now, ct);

        if (digestDue)
        {
            _lastDigestDay = MaintainerDigest.MalaysiaDay(now);
            if (!(counts.IsQuiet && o.SkipWhenQuiet))
            {
                await mailer.SendAsync(MaintainerDigest.Daily(counts, now, o.BackOfficeUrl), ct);
                logger.LogInformation("Maintainer digest sent ({Feedback} feedback, {Moderation} to moderate)", counts.FeedbackNew, counts.ModerationWaiting);
            }
            // The digest already shows the waiting items; don't follow it with an alert.
            if (counts.ModerationWaiting > 0) _lastAlert = now;
            return;
        }
        if (MaintainerDigest.ModerationAlertDue(counts, now, _lastAlert))
        {
            _lastAlert = now;
            await mailer.SendAsync(MaintainerDigest.ModerationAlert(counts, o.BackOfficeUrl), ct);
            logger.LogInformation("Moderation alert sent ({Waiting} waiting)", counts.ModerationWaiting);
        }
    }
}
