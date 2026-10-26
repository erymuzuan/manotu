using System.Text.Json.Nodes;
using Gimano.Importer;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Logging.Abstractions;
using Npgsql;

namespace Gimano.Tests;

/// <summary>Run on WS556 with GIMANO_PG_TEST pointing to a disposable PostGIS server.</summary>
public sealed class PostgresIntegrationLocalityEnrichmentTests : IAsyncLifetime
{
    private NpgsqlConnection? m_connection;
    private string? m_admin;
    private string? m_database;

    public async ValueTask InitializeAsync()
    {
        this.m_admin = Environment.GetEnvironmentVariable("GIMANO_PG_TEST");
        if (string.IsNullOrEmpty(this.m_admin)) return;
        this.m_database = "gimano_locality_it_" + Guid.NewGuid().ToString("N");
        await using var admin = new NpgsqlConnection(this.m_admin);
        await admin.OpenAsync();
        await using (var create = new NpgsqlCommand($"CREATE DATABASE {this.m_database}", admin))
            await create.ExecuteNonQueryAsync();
        this.m_connection = new NpgsqlConnection(new NpgsqlConnectionStringBuilder(this.m_admin)
            { Database = this.m_database }.ConnectionString);
        await this.m_connection.OpenAsync();
        await this.ExecuteAsync("""
            CREATE EXTENSION postgis;
            CREATE TABLE places (id varchar PRIMARY KEY, name text NOT NULL, country text NOT NULL,
                category text NOT NULL, location geography(point,4326) NOT NULL, tags jsonb NOT NULL DEFAULT '{}');
            CREATE INDEX ON places USING gist(location);
            CREATE TABLE admin_areas (id bigint PRIMARY KEY, name text NOT NULL, geom geography(multipolygon,4326) NOT NULL);
            CREATE INDEX ON admin_areas USING gist(geom);
            """);
    }

    public async ValueTask DisposeAsync()
    {
        if (this.m_connection is null) return;
        await this.m_connection.DisposeAsync();
        await using var admin = new NpgsqlConnection(this.m_admin);
        await admin.OpenAsync();
        await using var drop = new NpgsqlCommand($"DROP DATABASE {this.m_database} WITH (FORCE)", admin);
        await drop.ExecuteNonQueryAsync();
    }

    [Fact]
    public async Task Batches_preserve_exact_geography_for_holes_edges_multipolygons_and_dateline()
    {
        if (this.m_connection is null) { Assert.Skip("GIMANO_PG_TEST not set"); return; }
        await this.ExecuteAsync("""
            INSERT INTO admin_areas VALUES
            (1,'With hole',ST_GeogFromText('MULTIPOLYGON(((100 0,102 0,102 2,100 2,100 0),(100.5 0.5,100.5 1.5,101.5 1.5,101.5 0.5,100.5 0.5)))')),
            (2,'Islands',ST_GeogFromText('MULTIPOLYGON(((103 0,104 0,104 1,103 1,103 0)),((105 0,106 0,106 1,105 1,105 0)))')),
            (3,'Curved edge',ST_GeogFromText('MULTIPOLYGON(((-45 60,45 60,45 70,-45 70,-45 60)))')),
            (4,'Dateline',ST_GeogFromText('MULTIPOLYGON(((179 -1,-179 -1,-179 1,179 1,179 -1)))'));
            INSERT INTO places (id,name,country,category,location,tags)
            SELECT id,id,'MY','Other',ST_SetSRID(ST_MakePoint(lon,lat),4326)::geography,'{"kept":"yes"}'::jsonb
            FROM (VALUES ('n1',100.0,0.0),('n2',101.0,1.0),('n3',100.2,1.0),
                ('n4',103.5,0.5),('n5',105.5,0.5),('n6',0.0,72.0),('n7',180.0,0.0),('n8',110.0,0.0)) v(id,lon,lat);
            CREATE TABLE expected AS SELECT p.id, string_agg(DISTINCT a.name, ', ' ORDER BY a.name) AS names
                FROM places p LEFT JOIN admin_areas a ON ST_Covers(a.geom,p.location) GROUP BY p.id;
            """);
        await using (var curved = new NpgsqlCommand("""
            SELECT ST_Covers(a.geom,p.location) AND NOT ST_Covers(a.geom::geometry,p.location::geometry)
            FROM admin_areas a,places p WHERE a.id=3 AND p.id='n6'
            """, this.m_connection))
            Assert.Equal(true, await curved.ExecuteScalarAsync()); // A planar replacement must fail this fixture.
        var log = new CaptureLogger();
        await LocalityEnrichment.RunAsync(this.m_connection, log, CancellationToken.None, 2);
        Assert.Equal(4, log.Batches);
        await using var mismatch = new NpgsqlCommand("""
            SELECT count(*) FROM places p JOIN expected e USING(id)
            WHERE p.tags->>'manotu:admin_names' IS DISTINCT FROM e.names OR p.tags->>'kept'<>'yes'
            """, this.m_connection);
        Assert.Equal(0L, await mismatch.ExecuteScalarAsync());
        Assert.Equal("With hole", (await this.TagsAsync("n1"))["manotu:admin_names"]!.GetValue<string>());
        Assert.Null((await this.TagsAsync("n2"))["manotu:admin_names"]);
        Assert.Equal("Dateline", (await this.TagsAsync("n7"))["manotu:admin_names"]!.GetValue<string>());
    }

    [Fact]
    public async Task Locality_keeps_country_and_radius_rules_and_is_idempotent()
    {
        if (this.m_connection is null) { Assert.Skip("GIMANO_PG_TEST not set"); return; }
        await this.ExecuteAsync("""
            INSERT INTO places VALUES
            ('p','POI','MY','Other',ST_GeogFromText('POINT(101 3)'),'{"old_name":"Preserved"}'),
            ('foreign','Foreign','SG','Area',ST_GeogFromText('POINT(101.00001 3)'),'{"place":"town"}'),
            ('village','Too far village','MY','Area',ST_GeogFromText('POINT(101.03 3)'),'{"place":"village"}'),
            ('town','Town','MY','Area',ST_GeogFromText('POINT(101.09 3)'),'{"place":"town"}'),
            ('distant','Out of range','MY','Other',ST_GeogFromText('POINT(105 3)'),'{}');
            """);
        await LocalityEnrichment.RunAsync(this.m_connection, NullLogger.Instance, CancellationToken.None, 1);
        var first = await this.TagsAsync("p");
        Assert.Equal("town", first["manotu:locality_id"]!.GetValue<string>());
        Assert.Equal("nearest_place", first["manotu:locality_method"]!.GetValue<string>());
        Assert.Equal("Preserved", first["old_name"]!.GetValue<string>());
        Assert.Null((await this.TagsAsync("distant"))["manotu:locality"]);
        Assert.Null((await this.TagsAsync("town"))["manotu:locality"]);
        await LocalityEnrichment.RunAsync(this.m_connection, NullLogger.Instance, CancellationToken.None, 1);
        Assert.True(JsonNode.DeepEquals(first, await this.TagsAsync("p")));
    }

    [Fact]
    public async Task Cancellation_after_a_staged_batch_publishes_no_tags_and_allows_retry()
    {
        if (this.m_connection is null) { Assert.Skip("GIMANO_PG_TEST not set"); return; }
        await this.ExecuteAsync("""
            INSERT INTO places VALUES
            ('a','Town','MY','Area',ST_GeogFromText('POINT(101 3)'),'{"place":"town"}'),
            ('p1','One','MY','Other',ST_GeogFromText('POINT(101.001 3)'),'{}'),
            ('p2','Two','MY','Other',ST_GeogFromText('POINT(101.002 3)'),'{}');
            """);
        using var cancel = new CancellationTokenSource();
        var log = new CaptureLogger(cancel.Cancel);
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() =>
            LocalityEnrichment.RunAsync(this.m_connection, log, cancel.Token, 1));
        Assert.Equal(1, log.Batches);
        Assert.Equal("{}", (await this.TagsAsync("p1")).ToJsonString());
        Assert.Equal("{}", (await this.TagsAsync("p2")).ToJsonString());
        await LocalityEnrichment.RunAsync(this.m_connection, NullLogger.Instance, CancellationToken.None, 1);
        Assert.Equal("a", (await this.TagsAsync("p2"))["manotu:locality_id"]!.GetValue<string>());
    }

    private async Task ExecuteAsync(string sql)
    {
        await using var command = new NpgsqlCommand(sql, this.m_connection);
        await command.ExecuteNonQueryAsync();
    }

    private async Task<JsonObject> TagsAsync(string id)
    {
        await using var command = new NpgsqlCommand("SELECT tags::text FROM places WHERE id=@id", this.m_connection);
        command.Parameters.AddWithValue("id", id);
        return JsonNode.Parse((string)(await command.ExecuteScalarAsync())!)!.AsObject();
    }

    private sealed class CaptureLogger(Action? afterBatch = null) : ILogger
    {
        public int Batches { get; private set; }
        public IDisposable? BeginScope<TState>(TState state) where TState : notnull => null;
        public bool IsEnabled(LogLevel level) => true;
        public void Log<TState>(LogLevel level, EventId id, TState state, Exception? error, Func<TState, Exception?, string> format)
        {
            if (!format(state, error).StartsWith("Locality enrichment staged", StringComparison.Ordinal)) return;
            this.Batches++;
            afterBatch?.Invoke();
        }
    }
}
