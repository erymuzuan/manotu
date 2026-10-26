using Gimano.Core.Data;
using Gimano.Core.Messaging;
using Gimano.Core.Search;
using Microsoft.EntityFrameworkCore;

namespace Gimano.Worker.Search;

/// <summary>Consumes <c>place.changed</c>: re-indexes (or deletes) the place in OpenSearch.</summary>
public sealed class SearchIndexer(RabbitMqConnection connection, IServiceScopeFactory scopes, PlaceSearchIndex index, ILogger<SearchIndexer> logger)
    : RabbitConsumer<PlaceChangedEvent>(connection, logger)
{
    private bool _indexReady;

    protected override string QueueName => "gimano.worker.search";
    protected override IReadOnlyList<string> RoutingKeyBindings => [RoutingKeys.PlaceChanged];

    protected override async Task HandleAsync(PlaceChangedEvent message, string routingKey, CancellationToken ct)
    {
        if (!_indexReady)
        {
            await index.EnsureIndexAsync(ct: ct);
            _indexReady = true;
        }
        await using var scope = scopes.CreateAsyncScope();
        await using var rebuildLock = await SearchRebuildLock.AcquireAsync(scope.ServiceProvider.GetRequiredService<Npgsql.NpgsqlDataSource>(), false, ct);
        var db = scope.ServiceProvider.GetRequiredService<GimanoDbContext>();
        // OSM or community place, with its rating/review count/thumbnail.
        var doc = await PlaceDocuments.ForIdAsync(db, message.PlaceId, ct);
        if (doc is null) await index.DeleteAsync(message.PlaceId, ct);
        else await index.BulkIndexAsync([doc], ct);
    }
}
