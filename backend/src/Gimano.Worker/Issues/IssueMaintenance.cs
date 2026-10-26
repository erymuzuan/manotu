using Gimano.Core.Contracts;
using Gimano.Core.Data;
using Gimano.Core.Domain;
using Gimano.Core.Issues;
using Gimano.Core.Messaging;
using Microsoft.EntityFrameworkCore;

namespace Gimano.Worker.Issues;

/// <summary>
/// Every 15 minutes (docs/complaints.md): passive evidence for open road issues (≥ 5 traversals after the report → refuted;
/// no traffic where there normally is → supports confirmed), expiry, "resolved" when the imported map now matches
/// (segment gone, one-way flag changed, place gone), and deletion of vote salts 30 days after closing.
/// </summary>
public sealed class IssueMaintenance(IServiceScopeFactory scopes, IEventPublisher bus, TimeProvider clock, ILogger<IssueMaintenance> logger)
    : BackgroundService
{
    public static readonly TimeSpan Interval = TimeSpan.FromMinutes(15);

    protected override async Task ExecuteAsync(CancellationToken stoppingToken)
    {
        using var timer = new PeriodicTimer(Interval);
        do
        {
            try { await TickAsync(stoppingToken); }
            catch (Exception ex) when (ex is not OperationCanceledException) { logger.LogWarning("Issue maintenance failed: {Message}", ex.Message); }
        } while (await timer.WaitForNextTickAsync(stoppingToken));
    }

    internal async Task<(int Changed, int Resolved)> TickAsync(CancellationToken ct)
    {
        var now = clock.GetUtcNow();
        await using var scope = scopes.CreateAsyncScope();
        var db = scope.ServiceProvider.GetRequiredService<GimanoDbContext>();
        var open = await db.Issues.Where(i => i.State == IssueState.Reported || i.State == IssueState.Suspected || i.State == IssueState.Confirmed)
            .OrderBy(i => i.CreatedAt).Take(5000).ToListAsync(ct);
        var changed = 0; var resolved = 0; var skipped = 0;
        foreach (var issue in open)
        {
            // An earlier conflict cleared the change tracker: re-attach with the xmin read at load time (a stale one conflicts again).
            if (db.Entry(issue).State == EntityState.Detached) db.Attach(issue);
            var before = issue.State;
            try
            {
                if (await MapNowMatchesAsync(db, issue, ct))
                {
                    if (await IssueLedger.MoveAsync(db, issue, IssueState.Resolved, "map updated", now, ct)) resolved++;
                }
                else await IssueLedger.EvaluateAsync(db, issue, now, ct);
                if (issue.State != before)
                {
                    changed++;
                    await db.SaveChangesAsync(ct);
                    await bus.PublishAsync(RoutingKeys.IssueChanged, new IssueChangedEvent(issue.Id, issue.State, true), ct);
                }
            }
            catch (DbUpdateConcurrencyException)
            {
                // A vote changed this issue while we evaluated it (xmin): the API already re-ran the rules on fresh numbers,
                // and the next tick will see it again. Drop our stale changes and carry on with the rest.
                db.ChangeTracker.Clear();
                skipped++;
            }
        }
        await db.SaveChangesAsync(ct);
        var saltCutoff = now.AddDays(-30);
        await db.IssueSalts.Where(s => s.ResolvedAt != null && s.ResolvedAt < saltCutoff).ExecuteDeleteAsync(ct);
        if (changed > 0 || skipped > 0)
            logger.LogInformation("Issues: {Changed} state changes ({Resolved} resolved by the map) of {Open} open; {Skipped} changed concurrently, retried next tick",
                changed, resolved, open.Count, skipped);
        return (changed, resolved);
    }

    /// <summary>"Resolved": the weekly import now matches the report (the segment or place is gone, or the one-way flag flipped).</summary>
    internal static async Task<bool> MapNowMatchesAsync(GimanoDbContext db, Issue i, CancellationToken ct)
    {
        if (i.State == IssueState.Reported) return false;
        if (i.WayId is { } way && i.Seq is { } seq && IssueRules.IsRoad(i.Kind))
        {
            // No road data at all (fresh database / importer running): never conclude anything.
            if (!await db.RoadSegments.AnyAsync(ct)) return false;
            var seg = await db.RoadSegments.AsNoTracking().Where(s => s.OsmWayId == way && s.Seq == seq).Select(s => new { s.Oneway }).FirstOrDefaultAsync(ct);
            return i.Kind switch
            {
                IssueKind.RoadNotExist => seg is null,
                IssueKind.OnewayWrongClosedDir => seg is null || seg.Oneway,
                IssueKind.OnewayWrongOpenDir => seg is null || !seg.Oneway,
                _ => false,
            };
        }
        // A missing OSM record is not evidence of reopening. Keep confirmed closure until explicitly refuted.
        return false;
    }
}
