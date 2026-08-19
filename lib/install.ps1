# lab-bootstrap lib 1
# SPDX-License-Identifier: BSD-3-Clause
# Copyright 2026 The ISHS Cloud Computing Authors
#
# The install engine, tool-agnostic. Vendor facts live in lib/tools.ps1.
# Provided by the loader: $NoWinget $Force $InstallDir
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

# winget upgrade, for a package winget already owns. 'No applicable upgrade found' comes back
# as a non-zero exit, so the exit code tells us nothing; the caller compares versions instead.
function Update-Winget {
    param([string]$Id)
    try {
        winget upgrade --id $Id -e --source winget `
            --accept-package-agreements --accept-source-agreements `
            --silent --disable-interactivity | Out-Null
    } catch {
        Write-Warn "winget error: $($_.Exception.Message)"
    }
    Sync-Path
}

# The first semver a tool prints. Every tool here prints one; $null means 'cannot compare',
# which callers read as 'leave it alone'. How to ask is a vendor fact, so it lives in tools.ps1.
function Get-ToolVersion {
    param([string]$Cmd)
    if (-not (Test-Tool $Cmd)) { return $null }
    # Several of these write the version to stderr, which EAP=Stop would call a failure.
    # Function scope, so it is restored on return.
    $ErrorActionPreference = 'Continue'
    $out = (& $Cmd @(Get-VersionArgs $Cmd) 2>&1 | Out-String)
    if ($out -match '(\d+\.\d+\.\d+)') { return $Matches[1] }
    return $null
}

# Install one tool: winget, then the fallback scriptblock.
# -Fallback stays a scriptblock rather than a data table because Terraform and kubectl each
# resolve their download differently; seven functions named after seven tools is the greppable form.
function Install-Tool {
    param(
        [string]$Name,
        [string]$Cmd,
        [string]$WingetId,       # $null skips winget entirely
        [scriptblock]$Fallback,
        [scriptblock]$Latest     # installed version in, wanted version out; $null = no way to know
    )
    Write-Step "$Name"

    # $have stays $null on a fresh install, and every branch below asks 'was it already here?'
    # by testing it. $want is the version we are aiming at, passed on to the fallback so the
    # same release is not looked up twice.
    $have = $null
    $want = $null

    if (-not $Force -and (Test-Tool $Cmd)) {
        $have = Get-ToolVersion $Cmd
        # No readable installed version means no comparison, whatever the lookup would say -
        # so do not spend the lookup either.
        $want = if ($Latest -and $have) { & $Latest $have } else { $null }
        if ($want -and $want -eq $have) { Write-Skip "up to date ($have)"; return $true }

        # Nothing to compare against: AWS CLI, the SSM plugin and VS Code publish no cheap
        # 'what is current' endpoint. winget already tracks them, so ask it and judge by whether
        # the version moved. Without winget there is no answer, and reinstalling an MSI on every
        # run to find out is not one.
        if (-not $want) {
            $shown = if ($have) { " ($have)" } else { "" }
            if ($WingetId -and (Test-Winget)) {
                Update-Winget -Id $WingetId
                $now = Get-ToolVersion $Cmd
                if ($have -and $now -and $now -ne $have) { Write-Ok "updated $have -> $now (winget)" }
                else { Write-Skip "up to date$shown" }
            } else {
                Write-Skip "already installed$shown - cannot check for updates"
            }
            return $true
        }
    }

    if ($WingetId -and (Test-Winget)) {
        if ($have) {
            # winget owns this copy, so winget has to move it: its shim directory sits ahead of
            # $InstallDir on PATH, and a newer exe dropped in $InstallDir would stay shadowed.
            # A copy winget does not own fails here and falls through to the download.
            Update-Winget -Id $WingetId
            $now = Get-ToolVersion $Cmd
            if ($now -eq $want) { Write-Ok "updated $have -> $now (winget)"; return $true }
        } elseif (Install-Winget -Id $WingetId -Cmd $Cmd) {
            Write-Ok "installed $(Get-ToolVersion $Cmd) (winget)"
            return $true
        }
        Write-Warn "winget failed, trying direct download"
    }

    try {
        & $Fallback $want
        Sync-Path
        if (-not (Test-Tool $Cmd)) { Write-Err "installed but '$Cmd' is not on PATH"; return $false }

        # We wrote the new binary and PATH still answers with the old version: something earlier
        # on PATH is winning. Reporting an update here would be a lie, and a silent one - we
        # would come back and download the same file on every future run.
        $now = Get-ToolVersion $Cmd
        if ($want -and $now -and $now -ne $want) {
            Write-Warn "$want written to $InstallDir, but PATH still answers $now - another copy is ahead of it"
            return $true
        }
        if ($have) { Write-Ok "updated $have -> $now (download)" } else { Write-Ok "installed $now (download)" }
        return $true
    } catch {
        Write-Err $_.Exception.Message
        return $false
    }
}
