<#
.SYNOPSIS
  Builds the Gimano images (api, worker, importer, backoffice) from this checkout and pushes them to Azure Container Registry.

.DESCRIPTION
  Runs on WS556-SERVER or WS556 (PowerShell 7 + Docker). Must be run from a git checkout.
  Authentication: log in beforehand, either with `az acr login --name <registry>` (pass -AzLogin to let the script
  do it) or with an existing `docker login <registry>.azurecr.io`. The script never handles or writes credentials.
  Tags every image with the git short SHA (or -Tag) and with `latest`, pushes both, and prints the digests.

.EXAMPLE
  pwsh deploy/build-push.ps1 -Registry myhiro.azurecr.io
  pwsh deploy/build-push.ps1 -Registry myhiro.azurecr.io -Tag v0.3.0 -AzLogin
  pwsh deploy/build-push.ps1 -Registry myhiro.azurecr.io -WhatIf
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)] [string]$Registry,
    [string]$Tag,
    [switch]$AzLogin,
    [switch]$NoLatest,
    [string[]]$Images = @('api', 'worker', 'importer', 'backoffice')
)
$ErrorActionPreference = 'Stop'
$root = (git rev-parse --show-toplevel).Trim()
Set-Location $root
if (-not $Tag) { $Tag = (git rev-parse --short HEAD).Trim() }
if ((git status --porcelain -- backend deploy data/moderation).Length -gt 0) {
    Write-Warning 'The working tree has uncommitted changes under backend/, deploy/ or data/moderation/: the image will not match the tag.'
}
$Registry = $Registry.TrimEnd('/')

if ($AzLogin) {
    $name = $Registry.Split('.')[0]
    if ($PSCmdlet.ShouldProcess($Registry, 'az acr login')) { az acr login --name $name | Out-Null; if ($LASTEXITCODE) { throw 'az acr login failed' } }
}

$results = @()
foreach ($img in $Images) {
    $repo = "$Registry/gimano-$img"
    $tags = @("${repo}:$Tag") + ($(if ($NoLatest) { @() } else { @("${repo}:latest") }))
    $tagArgs = $tags | ForEach-Object { '-t', $_ }
    if ($PSCmdlet.ShouldProcess(($tags -join ', '), "docker build deploy/Dockerfile.$img")) {
        docker build --pull -f "deploy/Dockerfile.$img" @tagArgs --label "org.opencontainers.image.revision=$((git rev-parse HEAD).Trim())" .
        if ($LASTEXITCODE) { throw "build of $img failed" }
        foreach ($t in $tags) { docker push $t | Out-Null; if ($LASTEXITCODE) { throw "push of $t failed" } }
        $digest = (docker inspect --format '{{index .RepoDigests 0}}' "${repo}:$Tag").Trim()
        $results += [pscustomobject]@{ Image = "gimano-$img"; Tag = $Tag; Digest = $digest }
    }
}
$results | Format-Table -AutoSize
Write-Host "On the server: set TAG=$Tag in deploy/.env.prod, then: docker compose -f deploy/docker-compose.prod.yml --env-file deploy/.env.prod pull && ... up -d"
