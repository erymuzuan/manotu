using Npgsql;

namespace Gimano.Core.Search;

/// <summary>Serializes imports with accepted OSM edits and index consumers across processes.
/// Consumers wait before reading effective facts, so queued updates land on the promoted alias.</summary>
public sealed class SearchRebuildLock : IAsyncDisposable
{
    private const long Key = 0x4D414E4F5455;
    private readonly NpgsqlConnection connection;
    private readonly bool exclusive;
    private SearchRebuildLock(NpgsqlConnection connection, bool exclusive) => (this.connection, this.exclusive) = (connection, exclusive);

    public static async Task<SearchRebuildLock> AcquireAsync(NpgsqlDataSource source, bool exclusive, CancellationToken ct)
    {
        var connection = await source.OpenConnectionAsync(ct);
        try
        {
            await using var cmd = new NpgsqlCommand($"SELECT pg_advisory_lock{(exclusive ? "" : "_shared")}({Key})", connection) { CommandTimeout = 0 };
            await cmd.ExecuteNonQueryAsync(ct);
            return new SearchRebuildLock(connection, exclusive);
        }
        catch { await connection.DisposeAsync(); throw; }
    }

    public async ValueTask DisposeAsync()
    {
        try
        {
            await using var cmd = new NpgsqlCommand($"SELECT pg_advisory_unlock{(exclusive ? "" : "_shared")}({Key})", connection);
            await cmd.ExecuteNonQueryAsync();
        }
        finally { await connection.DisposeAsync(); }
    }
}
