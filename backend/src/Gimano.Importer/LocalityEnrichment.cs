using System.Diagnostics;
using Microsoft.Extensions.Logging;
using Npgsql;
using NpgsqlTypes;

namespace Gimano.Importer;

/// <summary>Bounded, exact geography enrichment. The caller holds SearchRebuildLock throughout.</summary>
internal static class LocalityEnrichment
{
    internal const int BATCH_SIZE = 256;
    private const int COMMAND_TIMEOUT_SECONDS = 120;

    internal static async Task RunAsync(NpgsqlConnection connection, ILogger logger, CancellationToken ct,
        int batchSize = BATCH_SIZE)
    {
        if (batchSize is < 1 or > BATCH_SIZE) throw new ArgumentOutOfRangeException(nameof(batchSize));
        // No partial tag publication: even cancellation after a completed batch rolls everything back.
        await using var transaction = await connection.BeginTransactionAsync(ct);
        await ExecuteAsync(connection, transaction, """
            CREATE TEMP TABLE locality_results (id varchar PRIMARY KEY, tags jsonb NOT NULL) ON COMMIT DROP;
            CREATE TEMP TABLE locality_candidates ON COMMIT DROP AS
                SELECT id, name, country, tags->>'place' AS kind, location FROM places
                WHERE category = 'Area' AND tags->>'place' IN ('city','town','village','suburb','neighbourhood','quarter');
            CREATE INDEX ON locality_candidates USING gist (location);
            CREATE INDEX ON locality_candidates (country);
            ANALYZE locality_candidates;
            """, ct);

        string? lastId = null;
        var total = 0;
        while (true)
        {
            ct.ThrowIfCancellationRequested();
            var ids = new List<string>(batchSize);
            await using (var page = new NpgsqlCommand("""
                SELECT id FROM places WHERE category <> 'Area' AND (@last IS NULL OR id > @last)
                ORDER BY id LIMIT @size
                """, connection, transaction) { CommandTimeout = COMMAND_TIMEOUT_SECONDS })
            {
                page.Parameters.AddWithValue("last", NpgsqlDbType.Varchar, (object?)lastId ?? DBNull.Value);
                page.Parameters.AddWithValue("size", batchSize);
                await using var reader = await page.ExecuteReaderAsync(ct);
                while (await reader.ReadAsync(ct)) ids.Add(reader.GetString(0));
            }
            if (ids.Count == 0) break;
            var elapsed = Stopwatch.StartNew();
            await using var batch = new NpgsqlCommand("""
                WITH batch AS MATERIALIZED (
                    SELECT id, country, location FROM places WHERE id = ANY(@ids)
                )
                INSERT INTO locality_results (id, tags)
                SELECT p.id, jsonb_strip_nulls(jsonb_build_object(
                    'manotu:admin_names', admin.names,
                    'manotu:locality', near.name, 'manotu:locality_id', near.id,
                    'manotu:locality_method', CASE WHEN near.id IS NOT NULL THEN 'nearest_place' END))
                FROM batch p
                LEFT JOIN LATERAL (
                    SELECT string_agg(DISTINCT a.name, ', ' ORDER BY a.name) AS names
                    FROM admin_areas a WHERE ST_Covers(a.geom, p.location)
                ) admin ON true
                LEFT JOIN LATERAL (
                    SELECT a.id, a.name FROM locality_candidates a
                    WHERE a.country = p.country
                      AND ST_DWithin(a.location, p.location, 20000)
                      AND ST_DWithin(a.location, p.location,
                          CASE WHEN a.kind IN ('city','town') THEN 20000 ELSE 2500 END)
                    ORDER BY a.location <-> p.location, a.id LIMIT 1
                ) near ON true
                """, connection, transaction) { CommandTimeout = COMMAND_TIMEOUT_SECONDS };
            batch.Parameters.AddWithValue("ids", NpgsqlDbType.Array | NpgsqlDbType.Varchar, ids.ToArray());
            await batch.ExecuteNonQueryAsync(ct);
            total += ids.Count;
            lastId = ids[^1];
            logger.LogInformation("Locality enrichment staged {Total} places; batch {Batch} in {Seconds:n1}s",
                total, ids.Count, elapsed.Elapsed.TotalSeconds);
        }

        await ExecuteAsync(connection, transaction, """
            UPDATE places p SET tags = p.tags || r.tags FROM locality_results r
            WHERE p.id = r.id AND r.tags <> '{}'::jsonb;
            """, ct);
        await transaction.CommitAsync(ct);
        logger.LogInformation("Locality enrichment committed for {Total} non-area places", total);
    }

    private static async Task ExecuteAsync(NpgsqlConnection connection, NpgsqlTransaction transaction,
        string sql, CancellationToken ct)
    {
        await using var command = new NpgsqlCommand(sql, connection, transaction)
            { CommandTimeout = COMMAND_TIMEOUT_SECONDS };
        await command.ExecuteNonQueryAsync(ct);
    }
}
