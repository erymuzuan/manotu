<# Run on WS556 only. Isolated PostGIS database/network; no production connections or image builds. #>
param([string]$PostgisImage = 'postgis/postgis:17-3.5')
$ErrorActionPreference = 'Stop'
$suffix = [Guid]::NewGuid().ToString('N').Substring(0, 12)
$name = "gimano-locality-it-$suffix"
$network = "$name-net"
$repo = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
$oldPassword = $env:POSTGRES_PASSWORD
$oldTest = $env:GIMANO_PG_TEST
$networkCreated = $false
$containerCreated = $false
try {
    $env:POSTGRES_PASSWORD = [Convert]::ToHexString([Security.Cryptography.RandomNumberGenerator]::GetBytes(24))
    docker network create $network | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Could not create isolated test network' }
    $networkCreated = $true
    docker run -d --name $name --network $network -e POSTGRES_USER=gimano -e POSTGRES_PASSWORD -e POSTGRES_DB=postgres $PostgisImage | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Could not create isolated PostGIS container' }
    $containerCreated = $true
    $ready = $false
    for ($i = 0; $i -lt 40; $i++) {
        docker exec $name pg_isready -h 127.0.0.1 -U gimano -d postgres *> $null
        if ($LASTEXITCODE -eq 0) { $ready = $true; break }
        Start-Sleep -Seconds 2
    }
    if (-not $ready) { throw 'Isolated PostGIS did not become ready' }
    $env:GIMANO_PG_TEST = "Host=$name;Database=postgres;Username=gimano;Password=$env:POSTGRES_PASSWORD"
    docker run --rm --network $network -v "${repo}:/src" -w /src/backend -e GIMANO_PG_TEST `
        mcr.microsoft.com/dotnet/sdk:10.0 dotnet test tests/Gimano.Tests `
        --filter 'FullyQualifiedName~LocalityEnrichment|FullyQualifiedName~SearchCoverageTests' `
        --logger 'trx;LogFileName=locality-repair.trx' --results-directory /src/artifacts/locality-tests
    if ($LASTEXITCODE -ne 0) { throw 'Locality/search regression tests failed; do not build or push' }
    # A green command with skipped PostgreSQL tests is not sufficient evidence.
    [xml]$trx = Get-Content (Join-Path $repo 'artifacts/locality-tests/locality-repair.trx')
    $results = @($trx.TestRun.Results.UnitTestResult | Where-Object testName -Match 'PostgresIntegrationLocalityEnrichmentTests')
    if ($results.Count -lt 3 -or @($results | Where-Object outcome -ne 'Passed').Count -ne 0) {
        throw 'Required PostGIS cases did not all run and pass; do not build or push'
    }
    Write-Output 'Locality integration and search coverage gates passed.'
} finally {
    $env:POSTGRES_PASSWORD = $oldPassword
    $env:GIMANO_PG_TEST = $oldTest
    if ($containerCreated) { docker rm -f $name | Out-Null }
    if ($networkCreated) { docker network rm $network | Out-Null }
}
