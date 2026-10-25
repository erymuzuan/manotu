param(
    [string]$SourceRoot = (Split-Path -Parent $PSScriptRoot),
    [string]$WebRoot = '\\172.30.30.13\apps\websites'
)
# Run on WS556-SERVER with the BespokeTech VPN connected. No root web.config or association-file changes.
$ErrorActionPreference = 'Stop'
$source = Join-Path $SourceRoot 'site/manotu/p'
$home = Join-Path $WebRoot 'www.bukitbunga.com/index.html'
$html = [IO.File]::ReadAllText($home)
$old = 'href="https://manotu.app/"'
$new = 'href="https://manotu.app/p/?id=w1106132383"'
$count = [regex]::Matches($html, [regex]::Escape($old)).Count
$already = [regex]::Matches($html, [regex]::Escape($new)).Count
if ($count -ne 3 -and $already -ne 3) { throw 'Unexpected homepage links. Review before deploying.' }
$backup = Join-Path $env:TEMP ('manotu-place-links-' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
New-Item -ItemType Directory -Path $backup | Out-Null
Copy-Item -LiteralPath $home -Destination (Join-Path $backup 'bukitbunga-index.html')
$files = @('index.html', 'link.mjs', 'place.mjs', 'place.css', 'web.config')
foreach ($site in @('manotu.app', 'www.bukitbunga.com/manotu')) {
    $target = Join-Path $WebRoot "$site/p"
    $saved = Join-Path $backup ($site.Replace('/', '-') + '-p')
    if (Test-Path $target) { Copy-Item -LiteralPath $target -Destination $saved -Recurse }
    New-Item -ItemType Directory -Path $target -Force | Out-Null
    foreach ($file in $files) {
        $from = Join-Path $source $file
        $to = Join-Path $target $file
        Copy-Item -LiteralPath $from -Destination $to
        if ((Get-FileHash $from).Hash -ne (Get-FileHash $to).Hash) { throw "Copy verification failed: $to" }
    }
}
# Switch the homepage links only after both fallback pages are in place.
$updated = $html.Replace($old, $new).Replace('Open Manotu', 'Open in Manotu').Replace(
    '<p>For directions, search for &ldquo;Petronas Bukit Bunga&rdquo; in the Manotu app.</p>',
    '<p>Open Petronas Bukit Bunga in Manotu to view the place and get directions.</p>')
[IO.File]::WriteAllText($home, $updated, [Text.UTF8Encoding]::new($false))
Write-Output "Place links deployed. Backup: $backup"
