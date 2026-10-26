using Gimano.Importer;
using Microsoft.Extensions.Logging.Abstractions;

namespace Gimano.Tests;

public class LocalityEnrichmentOptionsTests
{
    [Theory]
    [InlineData(true, true, true)]
    [InlineData(false, false, true)]
    [InlineData(false, true, false)]
    public async Task Recovery_rejects_incomplete_modes_before_acquiring_a_database_connection(
        bool dryRun, bool search, bool recreate)
    {
        var importer = new OsmImporter(null!, null!, null!, NullLogger<OsmImporter>.Instance);
        await Assert.ThrowsAsync<ArgumentException>(() => importer.RunAsync(
            new ImportOptions("unused", Search: search, RecreateIndex: recreate, DryRun: dryRun, EnrichOnly: true),
            CancellationToken.None));
    }
}
