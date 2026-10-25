using Gimano.Core.Community;
using Gimano.Core.Data;
using Microsoft.EntityFrameworkCore;

namespace Gimano.Worker.Vetting;

/// <summary>
/// Every minute: finishes the AI check for places the API stopped waiting for (over 4 s, or the call failed). A place still
/// unanswered after an hour goes to a maintainer instead (design B6). The owner hears the result in the Inbox.
/// </summary>
public sealed class PlaceScreeningRetry(IServiceScopeFactory scopes, TimeProvider clock, ILogger<PlaceScreeningRetry> logger) : BackgroundService
{
    protected override async Task ExecuteAsync(CancellationToken stoppingToken)
    {
        using var timer = new PeriodicTimer(TimeSpan.FromMinutes(1), clock);
        do
        {
            try { await TickAsync(stoppingToken); }
            catch (Exception ex) when (ex is not OperationCanceledException) { logger.LogWarning("Place screening retry failed: {Message}", ex.Message); }
        } while (await timer.WaitForNextTickAsync(stoppingToken));
    }

    internal async Task TickAsync(CancellationToken ct)
    {
        var now = clock.GetUtcNow();
        await using var scope = scopes.CreateAsyncScope();
        var db = scope.ServiceProvider.GetRequiredService<GimanoDbContext>();
        var gate = scope.ServiceProvider.GetRequiredService<PlaceGate>();
        var settled = now.AddSeconds(-30);
        var due = await db.CommunityPlaces.Include(p => p.Owner)
            .Where(p => p.ScreeningState == ScreeningState.Checking && p.UpdatedAt < settled).OrderBy(p => p.UpdatedAt).Take(50).ToListAsync(ct);
        int done = 0, gaveUp = 0;
        foreach (var p in due)
        {
            if (now - p.UpdatedAt > PlaceScreening.GiveUpAfter) { await gate.GiveUpAsync(p, ct); gaveUp++; continue; }
            if (await gate.RunAsync(p, isEdit: p.ResolvedAt is not null || p.ScreenedAt is not null, wait: TimeSpan.FromSeconds(30), late: true, ct)) done++;
        }
        if (done + gaveUp > 0) logger.LogInformation("Place screening: {Done} finished, {GaveUp} sent to a maintainer", done, gaveUp);
    }
}
