using Gimano.Core.Data;
using Gimano.Core.Support;

namespace Gimano.Worker.Support;

/// <summary>Hourly: contact details (30 days after close, 90 days max), crash reports (90 days), feedback (24 months), contact-carrying
/// reports unlinked from accounts, appeal text/notes/evidence photos (30 days after the decision), expired road reports unlinked from their reporter (votes deleted), search-miss counts (&lt; 5 after the week; 26 weeks).</summary>
public sealed class ReportRetentionJob(IServiceScopeFactory scopes, TimeProvider clock, ILogger<ReportRetentionJob> logger) : BackgroundService
{
    protected override async Task ExecuteAsync(CancellationToken stoppingToken)
    {
        using var timer = new PeriodicTimer(TimeSpan.FromHours(1));
        do
        {
            try
            {
                await using var scope = scopes.CreateAsyncScope();
                var db = scope.ServiceProvider.GetRequiredService<GimanoDbContext>();
                var (contacts, crashes, groups) = await ReportRetention.RunAsync(db, clock.GetUtcNow(), stoppingToken);
                var (reportsUnlinked, votesDeleted) = await Gimano.Core.Alerts.ReportUnlinking.RunAsync(db, clock.GetUtcNow(), stoppingToken);
                if (reportsUnlinked + votesDeleted > 0)
                    logger.LogInformation("Retention: unlinked {Reports} expired road reports, deleted {Votes} report votes", reportsUnlinked, votesDeleted);
                var unlinked = await ReportRetention.UnlinkContactReportsAsync(db, stoppingToken);
                if (unlinked > 0) logger.LogInformation("Retention: unlinked {Count} reports that carry a contact from their accounts", unlinked);
                var feedback = await ReportRetention.FeedbackAsync(db, clock.GetUtcNow(), stoppingToken);
                if (feedback > 0) logger.LogInformation("Retention: deleted {Count} feedback items older than 24 months", feedback);
                var misses = await SearchMisses.RetentionAsync(db, clock.GetUtcNow(), stoppingToken);
                if (misses > 0) logger.LogInformation("Retention: dropped {Count} search-miss rows", misses);
                if (contacts + crashes + groups > 0)
                    logger.LogInformation("Retention: deleted {Contacts} contacts, {Crashes} crash reports, {Groups} crash groups", contacts, crashes, groups);
                var appeals = await Gimano.Core.Community.AppealRetention.RunAsync(db, scope.ServiceProvider.GetRequiredService<Gimano.Core.Community.IMediaStore>(), clock.GetUtcNow(), stoppingToken);
                if (appeals > 0) logger.LogInformation("Retention: scrubbed {Count} decided appeals (text, note, evidence photos)", appeals);
                var (tokens, audit) = await Gimano.Core.BackOffice.BackOfficeRetention.RunAsync(db, clock.GetUtcNow(), stoppingToken);
                if (tokens + audit > 0) logger.LogInformation("Retention: deleted {Tokens} dead agent tokens, {Audit} audit rows", tokens, audit);
            }
            catch (Exception ex) when (ex is not OperationCanceledException) { logger.LogWarning("Report retention failed: {Message}", ex.Message); }
        } while (await timer.WaitForNextTickAsync(stoppingToken));
    }
}
