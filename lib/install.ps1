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

# Install one tool: winget, then the fallback scriptblock.
# -Fallback stays a scriptblock rather than a data table because Terraform, Git and kubectl each
# resolve their download differently; nine functions named after nine tools is the greppable form.
function Install-Tool {
    param(
        [string]$Name,
        [string]$Cmd,
        [string]$WingetId,       # $null skips winget entirely
        [scriptblock]$Fallback
    )
    Write-Step "$Name"

    if (-not $Force -and (Test-Tool $Cmd)) { Write-Skip "already installed"; return $true }

    if ($WingetId -and (Test-Winget)) {
        if (Install-Winget -Id $WingetId -Cmd $Cmd) { Write-Ok "installed (winget)"; return $true }
        Write-Warn "winget failed, trying direct download"
    }

    try {
        & $Fallback
        Sync-Path
        if (Test-Tool $Cmd) { Write-Ok "installed (download)"; return $true }
        Write-Err "installed but '$Cmd' is not on PATH"
        return $false
    } catch {
        Write-Err $_.Exception.Message
        return $false
    }
}
