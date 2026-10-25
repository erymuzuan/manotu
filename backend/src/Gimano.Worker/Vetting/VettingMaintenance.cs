using Gimano.Core.Contracts;
using Gimano.Core.Data;
using Gimano.Core.Identity;
using Gimano.Core.Messaging;
using Microsoft.EntityFrameworkCore;

namespace Gimano.Worker.Vetting;

/// <summary>
/// Hourly: pending places older than 30 days expire (votes unlinked, contributor notified); salts of places resolved
/// more than 30 days ago are deleted (resolved votes become permanently unlinkable). Every 24 h: tiers recomputed for
/// everyone active in the last 90 days (demotion/suspension expiry).
/// </summary>
public sealed class VettingMaintenance(IServiceScopeFactory scopes, IEventPublisher bus, TimeProvider clock, ILogger<VettingMaintenance> logger,
    Microsoft.Extensions.Options.IOptions<VettingOptions> vetting)
    : BackgroundService
{
    private DateTimeOffset _lastNightly = DateTimeOffset.MinValue;

    protected override async Task ExecuteAsync(CancellationToken stoppingToken)
    {
        using var timer = new PeriodicTimer(TimeSpan.FromHours(1));
        do
        {
            try { await TickAsync(stoppingToken); }
            catch (Exception ex) when (ex is not OperationCanceledException) { logger.LogWarning("Vetting maintenance failed: {Message}", ex.Message); }
        } while (await timer.WaitForNextTickAsync(stoppingToken));
    }

    internal async Task TickAsync(CancellationToken ct)
    {
        var now = clock.GetUtcNow();
        await using var scope = scopes.CreateAsyncScope();
        var db = scope.ServiceProvider.GetRequiredService<GimanoDbContext>();

        var cutoff = now - Reputation.PendingExpiryFor(vetting.Value.LaunchMode);
        var expired = await db.CommunityPlaces.Where(p => p.Status == PlaceStatus.Pending && p.ScreeningState != Core.Community.ScreeningState.Checking
            && p.CreatedAt < cutoff).Take(500).ToListAsync(ct);
        foreach (var p in expired)
        {
            await Ledger.ResolveAsync(db, p, PlaceStatus.Expired, now, ct);
            await db.SaveChangesAsync(ct);
            await bus.PublishAsync(RoutingKeys.PlaceChanged, new PlaceChangedEvent(p.Id), ct);
            await bus.PublishAsync(RoutingKeys.PlaceVerified, new PlaceVerifiedEvent(p.Id, PlaceStatus.Expired), ct);
        }
        // Audits that never collected enough votes close after 30 days too (the place stays published).
        await db.CommunityPlaces.Where(p => p.AuditOpen && p.CreatedAt < cutoff)
            .ExecuteUpdateAsync(s => s.SetProperty(p => p.AuditOpen, false).SetProperty(p => p.ResolvedAt, now), ct);

        var saltCutoff = now - Reputation.SaltRetention;
        var salts = await db.PlaceSalts.Where(s => s.ResolvedAt != null && s.ResolvedAt < saltCutoff).ExecuteDeleteAsync(ct);
        if (expired.Count + salts > 0) logger.LogInformation("Vetting: {Expired} places expired, {Salts} salts deleted", expired.Count, salts);

        if (now - _lastNightly >= TimeSpan.FromHours(24))
        {
            _lastNightly = now;
            var activeSince = DateOnly.FromDateTime(now.AddDays(-90).UtcDateTime);
            var users = await db.Users.Where(u => u.LastActiveDay >= activeSince || u.Tier != Tier.Baharu || u.SuspendedUntil != null).ToListAsync(ct);
            var changed = 0;
            foreach (var u in users)
            {
                var (tier, susp) = (u.Tier, u.SuspendedUntil);
                await Ledger.RecomputeAsync(db, u, now, ct);
                if (u.SuspendedUntil < now) u.SuspendedUntil = null;
                if (u.Tier != tier || u.SuspendedUntil != susp) changed++;
            }
            await db.SaveChangesAsync(ct);
            logger.LogInformation("Nightly tier recompute: {Users} users, {Changed} changed", users.Count, changed);
        }
    }
}
