# SPDX-License-Identifier: BSD-3-Clause
# Copyright 2026 The ISHS Cloud Computing Authors
#
# Unit tests for the update check. Dot-sources the real lib/*.ps1 and drives it against stub
# tools that print exactly what the real ones print, so the version regex and every branch of
# Install-Tool are exercised without Windows, winget, or a download.
#
# Not covered here, on purpose: winget, msiexec, the registry and services are all mocked or
# absent, so this says nothing about whether those calls are correct on a real PC. It says the
# decision logic around them is.
#
# Stubs are /bin/sh scripts, so this needs Linux or macOS. On Windows it skips rather than
# pretending to pass.

$ErrorActionPreference = 'Stop'

if ($IsWindows) {
    Write-Host "SKIP  stub tools are shell scripts; run this on Linux or macOS" -ForegroundColor Yellow
    exit 0
}

$Root = Split-Path $PSScriptRoot -Parent
$Tmp  = Join-Path ([System.IO.Path]::GetTempPath()) "lab-bootstrap-units-$PID"
$Bin  = Join-Path $Tmp 'bin'
New-Item -ItemType Directory -Path $Bin -Force | Out-Null
$env:PATH = "$Bin" + [System.IO.Path]::PathSeparator + $env:PATH

$Fail = 0
function Bad  { param([string]$Msg) $script:Fail++; Write-Host "FAIL $Msg" -ForegroundColor Red }
function Good { param([string]$Msg) Write-Host "ok   $Msg" -ForegroundColor Green }

# A stub that prints $Out. $Err sends it to stderr instead - k9s does that, and Get-ToolVersion
# has to read it anyway.
#
# The stub refuses any arguments but the ones Get-VersionArgs is supposed to send it. Without
# that, a wrong entry in the args table still produces a version and the test passes on a lie.
function New-Stub {
    param([string]$Name, [string]$Out, [string]$ExpectArgs = 'version', [switch]$Err)
    $redir = if ($Err) { ' 1>&2' } else { '' }
    $body  = ($Out -split "`n" | ForEach-Object { "echo '$_'$redir" }) -join "`n"
    $p     = Join-Path $Bin $Name
    Set-Content -Path $p -Value @"
#!/bin/sh
if [ "`$*" != "$ExpectArgs" ]; then echo "stub $Name got args: `$*" 1>&2; exit 64; fi
$body
"@
    chmod +x $p
}

# The logging layer lives in bootstrap.ps1, which we do not want to run. Capture instead of print.
$Script:Log = @()
function Write-Step { param([string]$Msg) }
function Write-Ok   { param([string]$Msg) $Script:Log += "OK   $Msg" }
function Write-Skip { param([string]$Msg) $Script:Log += "SKIP $Msg" }
function Write-Warn { param([string]$Msg) $Script:Log += "WARN $Msg" }
function Write-Err  { param([string]$Msg) $Script:Log += "FAIL $Msg" }

$NoWinget   = $true          # Test-Winget returns false, so the version-compare paths run
$Force      = $false
$InstallDir = '/lab-tools'

. (Join-Path $Root 'lib/env.ps1')
. (Join-Path $Root 'lib/tools.ps1')
. (Join-Path $Root 'lib/install.ps1')

# Sync-Path reads the Windows machine PATH, which is empty here - calling it would wipe $env:PATH
# and the stubs with it. It is the only thing from env.ps1 we have to replace.
function Sync-Path { }

try {
    # 1. Get-VersionArgs + Get-ToolVersion, against what the real tools actually print.
    Write-Host "`n== version parsing" -ForegroundColor Cyan
    $cases = @(
        @{ Cmd = 'aws';                    Args = '--version';        Want = '2.17.42'; Out = 'aws-cli/2.17.42 Python/3.11.9 Windows/10 exe/AMD64 prompt/off' }
        @{ Cmd = 'session-manager-plugin'; Args = '--version';        Want = '1.2.633'; Out = '1.2.633.0' }
        @{ Cmd = 'helm';                   Args = 'version --short';  Want = '3.16.2';  Out = 'v3.16.2+g9d6a4d5' }
        @{ Cmd = 'eksctl';                 Args = 'version';          Want = '0.191.0'; Out = '0.191.0' }
        @{ Cmd = 'kubectl';                Args = 'version --client'; Want = '1.36.2';  Out = "Client Version: v1.36.2`nKustomize Version: v5.4.2" }
        @{ Cmd = 'terraform';              Args = 'version';          Want = '1.15.8';  Out = "Terraform v1.15.8`non windows_amd64" }
        @{ Cmd = 'code';                   Args = '--version';        Want = '1.93.1';  Out = "1.93.1`n38c31bc77e0dd6ae88a4e9cc93428cc27a56ba40`nx64" }
        @{ Cmd = 'k9s';                    Args = 'version -s';       Want = '0.32.5';  Out = '0.32.5'; Err = $true }
    )
    foreach ($c in $cases) {
        New-Stub -Name $c.Cmd -Out $c.Out -ExpectArgs $c.Args -Err:([bool]$c.Err)
        $argStr = (Get-VersionArgs $c.Cmd) -join ' '
        $got    = Get-ToolVersion $c.Cmd
        $msg    = "{0,-24} {1,-20} -> {2}" -f $c.Cmd, $argStr, $got
        if ($argStr -ne $c.Args) { Bad "$msg (args should be '$($c.Args)')" }
        elseif ($got -ne $c.Want) { Bad "$msg (expected $($c.Want))" }
        else { Good $msg }
    }
    if ($null -eq (Get-ToolVersion 'no-such-tool')) { Good 'not installed -> $null' }
    else { Bad 'not installed should give $null' }

    # 2. Install-Tool decision table. -WingetId is $null throughout, so these are the paths a
    #    lab PC takes with -NoWinget or with a tool winget does not own.
    Write-Host "`n== Install-Tool decisions" -ForegroundColor Cyan
    $widget = Join-Path $Bin 'widget'
    function Set-Widget { param([string]$V)
        if ($V) { New-Stub -Name 'widget' -Out "widget version $V" }
        else { Remove-Item $widget -Force -ErrorAction SilentlyContinue }
    }
    $Script:Saw = 'not-run'
    # A working fallback: records what it was handed, then lands 2.0.0 on PATH.
    $good  = { param($Ver) $Script:Saw = if ($Ver) { $Ver } else { '<null>' }; Set-Widget '2.0.0' }
    # A fallback whose result never reaches PATH - an older copy is ahead of $InstallDir.
    $stuck = { param($Ver) $Script:Saw = if ($Ver) { $Ver } else { '<null>' } }

    function Case {
        param([string]$Name, [string]$Have, [scriptblock]$Latest, [scriptblock]$Fallback,
              [bool]$WithForce, [string]$ExpectLog, [string]$ExpectSaw)
        $Script:Log = @(); $Script:Saw = 'not-run'
        Set-Widget $Have
        Set-Variable -Name Force -Value $WithForce -Scope Script
        $r   = Install-Tool -Name 'widget' -Cmd 'widget' -WingetId $null -Fallback $Fallback -Latest $Latest
        $log = $Script:Log -join ' | '
        if ($r -and $log -like $ExpectLog -and $Script:Saw -eq $ExpectSaw) {
            Good ("{0,-26} fallback({1,-7}) {2}" -f $Name, $Script:Saw, $log)
        } else {
            Bad ("{0,-26} fallback({1,-7}) {2}   [wanted '{3}' + fallback({4})]" -f $Name, $Script:Saw, $log, $ExpectLog, $ExpectSaw)
        }
    }

    Case 'fresh install'      ''      { param($h) '2.0.0' } $good  $false '*installed 2.0.0 (download)*'  '<null>'
    Case 'up to date'         '2.0.0' { param($h) '2.0.0' } $good  $false 'SKIP up to date (2.0.0)'      'not-run'
    Case 'behind -> update'   '1.0.0' { param($h) '2.0.0' } $good  $false '*updated 1.0.0 -> 2.0.0*'     '2.0.0'
    Case 'no -Latest'         '1.0.0' $null                 $good  $false '*cannot check for updates*'   'not-run'
    Case 'lookup fell back'   '1.0.0' { param($h) $h }      $good  $false 'SKIP up to date (1.0.0)'      'not-run'
    Case '-Force reinstalls'  '2.0.0' { param($h) '2.0.0' } $good  $true  '*installed 2.0.0 (download)*' '<null>'
    Case 'shadowed copy'      '1.0.0' { param($h) '2.0.0' } $stuck $false 'WARN 2.0.0 written to*still answers 1.0.0*' '2.0.0'

    # An unreadable version is not a version: there is nothing to compare, so the lookup must not
    # be spent either. On a lab network that lookup is a shared 60/hour GitHub quota.
    New-Stub -Name 'widget' -Out 'widget, build unknown'
    $Script:Log = @(); $probed = $false
    Set-Variable -Name Force -Value $false -Scope Script
    $null = Install-Tool -Name 'widget' -Cmd 'widget' -WingetId $null -Fallback $good `
                         -Latest { param($h) $script:probed = $true; '9.9.9' }
    if (-not $probed -and ($Script:Log -join '') -like '*cannot check*') {
        Good ("{0,-26} lookup skipped, {1}" -f 'unreadable version', ($Script:Log -join ' | '))
    } else {
        Bad ("{0,-26} probed={1} {2}" -f 'unreadable version', $probed, ($Script:Log -join ' | '))
    }
} finally {
    Remove-Item $Tmp -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ""
if ($Fail) { Write-Host "$Fail failed" -ForegroundColor Red } else { Write-Host "all ok" -ForegroundColor Green }
exit $Fail
