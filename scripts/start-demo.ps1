$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# deploy.ps1 owns the complete, dependency-ordered deployment workflow. Keeping
# this entry point tiny prevents the learning and regular deployment paths drifting.
& (Join-Path $PSScriptRoot 'deploy.ps1')
if ($LASTEXITCODE -ne 0) {
    throw 'Demo startup failed.'
}
