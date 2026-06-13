# Builds the docs/ folder for GitHub Pages (lighter than SharePoint - ESPN images load directly).
param(
    [switch]$SkipDataRefresh
)

$ErrorActionPreference = 'Stop'

$projectRoot = Split-Path $PSScriptRoot -Parent
$docsRoot = Join-Path $projectRoot 'docs'
$assetsRoot = Join-Path $docsRoot 'assets'
$htmlSource = Join-Path $PSScriptRoot 'World-Cup-Performance-Team-Dashboard.html'
$cssSource = Join-Path $projectRoot 'assets\cisco-brand.css'
$dataJsSource = Join-Path $PSScriptRoot 'world-cup-data.js'
$utf8 = New-Object System.Text.UTF8Encoding $false

if (-not $SkipDataRefresh) {
    Write-Host 'Refreshing dashboard data from ESPN...'
    $skipRoster = ($env:GITHUB_ACTIONS -eq 'true')
    if ($skipRoster) {
        Write-Host 'CI mode: skipping ESPN roster calls (scores and standings still update).'
    }
    & (Join-Path $PSScriptRoot 'update-world-cup-dashboard.ps1') -SkipRosterFetch:$skipRoster
}

if (-not (Test-Path $dataJsSource)) {
    throw "Missing data file: $dataJsSource. The ESPN update step did not produce world-cup-data.js."
}

Write-Host 'Building GitHub Pages site in docs/...'
New-Item -ItemType Directory -Path $assetsRoot -Force | Out-Null

$html = [System.IO.File]::ReadAllText($htmlSource, $utf8)
$html = $html -replace '\.\./assets/cisco-brand\.css', 'assets/cisco-brand.css'

Copy-Item $cssSource (Join-Path $assetsRoot 'cisco-brand.css') -Force
Copy-Item $dataJsSource (Join-Path $docsRoot 'world-cup-data.js') -Force
[System.IO.File]::WriteAllText((Join-Path $docsRoot 'index.html'), $html, $utf8)

Write-Host "GitHub Pages files ready in: $docsRoot"
Write-Host '  docs/index.html'
Write-Host '  docs/world-cup-data.js'
Write-Host '  docs/assets/cisco-brand.css'
