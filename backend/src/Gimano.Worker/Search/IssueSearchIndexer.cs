using Gimano.Core.Data;
using Gimano.Core.Messaging;
using Gimano.Core.Search;
using Microsoft.EntityFrameworkCore;
namespace Gimano.Worker.Search;

/// <summary>Closure/reopening changes update retrieval, not just the post-query badge.</summary>
public sealed class IssueSearchIndexer(RabbitMqConnection connection, IServiceScopeFactory scopes, PlaceSearchIndex index, ILogger<IssueSearchIndexer> logger)
    : RabbitConsumer<IssueChangedEvent>(connection, logger)
{
    protected override string QueueName => "gimano.worker.issue-search";
    protected override IReadOnlyList<string> RoutingKeyBindings => [RoutingKeys.IssueChanged];
    protected override async Task HandleAsync(IssueChangedEvent message, string routingKey, CancellationToken ct)
    {
        await using var scope = scopes.CreateAsyncScope();
        await using var rebuildLock = await SearchRebuildLock.AcquireAsync(scope.ServiceProvider.GetRequiredService<Npgsql.NpgsqlDataSource>(), false, ct);
        var db = scope.ServiceProvider.GetRequiredService<GimanoDbContext>();
        var id = await db.Issues.Where(i => i.Id == message.IssueId).Select(i => i.PlaceId).FirstOrDefaultAsync(ct);
        if (id is null) return;
        await index.EnsureIndexAsync(ct: ct);
        var document = await PlaceDocuments.ForIdAsync(db, id, ct);
        if (document is not null) await index.BulkIndexAsync([document], ct);
    }
}
