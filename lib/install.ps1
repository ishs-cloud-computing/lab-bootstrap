# lab-bootstrap lib 1
# SPDX-License-Identifier: BSD-3-Clause
# Copyright 2026 The ISHS Cloud Computing Authors
#
# The install engine, tool-agnostic. Vendor facts live in lib/tools.ps1.
# Provided by the loader: $NoWinget $Force
# Definitions only - no top-level code, so load order never matters.

function Test-Winget {
    if ($NoWinget) { return $false }
    return [bool](Get-Command winget -ErrorAction SilentlyContinue)
}

function Install-Winget {
    param([string]$Id, [string]$Cmd)
    try {
        winget install --id $Id -e --source winget `
            --accept-package-agreements --accept-source-agreements `
            --silent --disable-interactivity | Out-Null
    } catch {
        Write-Warn "winget error: $($_.Exception.Message)"
    }
    # winget exit codes vary ('already up to date' etc.), so judge by command availability
    Sync-Path
    return (Test-Tool $Cmd)
}

# Install one tool: direct vendor download first (winget's source update and metadata cost
# 2-5 minutes across a fresh install), winget as the fallback when the download fails.
# -Direct stays a scriptblock rather than a data table because Terraform and kubectl each
# resolve their download differently; functions named after the tools is the greppable form.
function Install-Tool {
    param(
        [string]$Name,
        [string]$Cmd,
        [string]$WingetId,       # $null means no winget fallback exists
        [scriptblock]$Direct
    )
    Write-Step "$Name"

    if (-not $Force -and (Test-Tool $Cmd)) { Write-Skip "already installed"; return $true }

    try {
        & $Direct
        Sync-Path
        if (Test-Tool $Cmd) { Write-Ok "installed (download)"; return $true }
        Write-Warn "installed but '$Cmd' is not on PATH"
    } catch {
        Write-Warn "direct download failed: $($_.Exception.Message)"
    }

    if ($WingetId -and (Test-Winget)) {
        if (Install-Winget -Id $WingetId -Cmd $Cmd) { Write-Ok "installed (winget fallback)"; return $true }
    }

    Write-Err "direct download failed$(if ($WingetId) { ', winget fallback too' })"
    return $false
}
