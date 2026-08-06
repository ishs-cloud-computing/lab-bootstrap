# lab-bootstrap lib 1
# SPDX-License-Identifier: BSD-3-Clause
# Copyright 2026 The ISHS Cloud Computing Authors
#
# Get bytes and unpack them.
# Provided by the loader: $InstallDir
# Definitions only - no top-level code, so load order never matters.

function Get-Download {
    param([string]$Url, [string]$OutFile, [int]$Retries = 3)
    for ($i = 1; $i -le $Retries; $i++) {
        try {
            Invoke-WebRequest -Uri $Url -OutFile $OutFile -TimeoutSec 120
            return
        } catch {
            if ($i -eq $Retries) { throw "download failed after $Retries tries: $Url" }
            Write-Warn "download failed ($i/$Retries), retrying: $Url"
            Start-Sleep -Seconds 3
        }
    }
}

function Expand-ToInstallDir {
    param([string]$Zip, [string]$ExeName)
    $tmp = Join-Path $env:TEMP ("x_" + [IO.Path]::GetFileNameWithoutExtension($Zip))
    if (Test-Path $tmp) { Remove-Item $tmp -Recurse -Force }
    Expand-Archive -Path $Zip -DestinationPath $tmp -Force
    $exe = Get-ChildItem -Path $tmp -Filter $ExeName -Recurse | Select-Object -First 1
    if (-not $exe) { throw "$ExeName not found in $Zip" }
    Copy-Item $exe.FullName (Join-Path $InstallDir $ExeName) -Force
    Remove-Item $tmp -Recurse -Force
}

function Get-LatestOrPinned {
    param([string]$Repo, [string]$Pinned, [string]$Label)
    try {
        $tag = (Invoke-RestMethod -Uri "https://api.github.com/repos/$Repo/releases/latest" `
                                  -Headers @{ 'User-Agent' = 'lab-bootstrap' } -TimeoutSec 30).tag_name
        if ($tag) { return $tag.TrimStart('v') }
        Write-Warn "$Label lookup returned no tag, using pin $Pinned"
    } catch {
        Write-Warn "$Label lookup failed, using pin $Pinned ($($_.Exception.Message))"
    }
    return $Pinned
}
