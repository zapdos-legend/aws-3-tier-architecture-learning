$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

& (Join-Path $PSScriptRoot 'cleanup.ps1')
if ($LASTEXITCODE -ne 0) {
    throw 'Demo shutdown failed.'
}
