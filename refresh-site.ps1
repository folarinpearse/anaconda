# Rebuilds the signed anaconda.riv and refreshes the GitHub Pages site in docs/.
#
#   .\refresh-site.ps1
#
# Source of truth: web/index.html and web/vendor/ (the pinned Rive runtime).
# Output: docs/index.html, docs/anaconda.riv, docs/vendor/. web/anaconda.riv is
# kept in step too, so the local test server serves the same build.
# Needs `rive login`: web runtimes reject unsigned scripts, so this uses
# `rive . --publish`, which signs them through Rive's compile service.

$ErrorActionPreference = 'Stop'
Set-Location $PSScriptRoot

$started = Get-Date
$riv = Join-Path $PSScriptRoot 'build\anaconda.riv'

Write-Host 'Building signed anaconda.riv...'
& rive . --publish
if ($LASTEXITCODE -ne 0) {
    throw "rive --publish failed (exit $LASTEXITCODE); docs/ was not touched. Exit 3 means run 'rive login'; exit 7 is a service timeout, safe to retry."
}
if (-not (Test-Path $riv) -or (Get-Item $riv).LastWriteTime -lt $started) {
    throw "build\anaconda.riv was not written by this run; docs/ was not touched."
}

New-Item -ItemType Directory -Force -Path 'docs', 'docs\vendor' | Out-Null
Copy-Item $riv 'docs\anaconda.riv' -Force
Copy-Item $riv 'web\anaconda.riv' -Force
Copy-Item 'web\index.html' 'docs\index.html' -Force
Copy-Item 'web\vendor\*' 'docs\vendor\' -Force
# Pages should serve the folder as-is, with no Jekyll processing.
if (-not (Test-Path 'docs\.nojekyll')) { New-Item -ItemType File 'docs\.nojekyll' | Out-Null }

Write-Host ''
Write-Host 'docs/ updated:'
Get-ChildItem docs -Recurse -File | ForEach-Object {
    '{0,10:N0}  {1}' -f $_.Length, $_.FullName.Substring($PSScriptRoot.Length + 1)
}
Write-Host ''
Write-Host 'Next: git add docs web; git commit; git push'
