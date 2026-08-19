# SPDX-License-Identifier: BSD-3-Clause
# Copyright 2026 The ISHS Cloud Computing Authors

#Requires -Version 7
<#
.SYNOPSIS
    Installs the cloud computing lab toolchain on a school lab Windows PC.

.DESCRIPTION
    Installs AWS CLI v2, SSM plugin, Helm, eksctl, kubectl, Terraform, VS Code, k9s,
    zoxide, Mark (with an mdv launcher command) and Neovim with mini.nvim.
    Direct download from each vendor first (no winget metadata overhead, 2-5 min faster on a
    fresh PC); winget as the fallback when a vendor download fails.
    Idempotent: already-installed tools are skipped. Needs admin; self-elevates via UAC.

    kubectl is the exception: dl.k8s.io is blocked by the school firewall (and the
    winget/choco packages download from there too), so it comes from the Amazon EKS S3
    mirror instead, verified against the published SHA256.

    Shell setup lives in one file, .bootrc, the way .zshrc does. If the current directory
    has one, its contents are spliced into a pwsh profile between markers. If not, nothing
    touches the profile.

    This file is a loader: the install logic is in lib/*.ps1, read from next to this script
    when it is on disk, and fetched from -BaseUrl when it is not.

.PARAMETER KubectlMinor
    kubectl minor version, looked up in $KubectlMap. Match it to the EKS cluster in use.

.PARAMETER InstallDir
    Where portable binaries go. Added to the system PATH.

.PARAMETER NoWinget
    Disable the winget fallback; direct download only.

.PARAMETER Force
    Reinstall even if the tool is already present.

.PARAMETER BaseUrl
    Where lib/*.ps1 is fetched from when this script runs without a file on disk (irm | iex).

.EXAMPLE
    pwsh -ExecutionPolicy Bypass -File .\bootstrap.ps1

.EXAMPLE
    pwsh -ExecutionPolicy Bypass -File .\bootstrap.ps1 -KubectlMinor 1.31 -Force
#>
[CmdletBinding()]
param(
    [string]$KubectlMinor = "1.36",
    [string]$InstallDir   = "C:\cloud-tools\bin",
    [switch]$NoWinget,
    [switch]$Force,
    [string]$BaseUrl      = 'https://raw.githubusercontent.com/ishs-cloud-computing/lab-bootstrap/main'
)

# #Requires is ignored when this source is piped into iex, which is the documented one-liner.
if ($PSVersionTable.PSVersion.Major -lt 7) {
    throw "PowerShell 7+ is required (current: $($PSVersionTable.PSVersion)). See README."
}

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'   # progress rendering costs more than the download

# Versions: this is the part you edit
# kubectl full version + build date per minor, from the EKS S3 mirror.
# https://docs.aws.amazon.com/eks/latest/userguide/install-kubectl.html
$KubectlMap = @{
    "1.36" = @{ v = "1.36.2";  d = "2026-06-17" }
    "1.35" = @{ v = "1.35.3";  d = "2026-04-08" }
    "1.34" = @{ v = "1.34.6";  d = "2026-04-08" }
    "1.33" = @{ v = "1.33.10"; d = "2026-04-08" }
    "1.32" = @{ v = "1.32.13"; d = "2026-04-08" }
    "1.31" = @{ v = "1.31.14"; d = "2026-04-08" }
    "1.30" = @{ v = "1.30.14"; d = "2026-04-08" }
}

# Used when the online latest-version lookup fails. Not decoration: the unauthenticated
# GitHub quota is 60/hour per IP and the whole lab shares one NAT address, so these get hit.
$HelmPinned      = "4.2.3"
$TerraformPinned = "1.15.8"
$ZoxidePinned    = "0.10.0"

$EnvKey = 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Environment'

# Baked completions land next to the binaries, not inside them: $InstallDir is on PATH and
# shell scripts have no business being resolvable as commands.
$ToolsRoot   = Split-Path $InstallDir -Parent
$CompletionD = Join-Path $ToolsRoot 'completion'

# What we own inside a profile we do not own. Everything between these two lines is generated
# and replaced on every run; everything outside is the user's and is preserved byte for byte.
$BlockBegin = '# >>> lab-bootstrap begin >>>'
$BlockEnd   = '# <<< lab-bootstrap end <<<'

$LogDir = Join-Path $env:TEMP 'lab-bootstrap'

# Filled in by lib/shell.ps1, read by lib/verify.ps1. Null means shell integration did not
# happen, which is the difference between "installed" and "actually works in a new terminal".
$Script:BootRcTarget     = $null
$Script:CompletionsBaked = @()

# Logging. Stays in the loader: it has to be able to report a lib fetch failure in the house
# style, and five one-line functions in a module would only buy a load-order dependency.
function Write-Step { param([string]$Msg) Write-Host "`n==> $Msg" -ForegroundColor Cyan }
function Write-Ok   { param([string]$Msg) Write-Host "    [OK]   $Msg" -ForegroundColor Green }
function Write-Skip { param([string]$Msg) Write-Host "    [SKIP] $Msg" -ForegroundColor DarkGray }
function Write-Warn { param([string]$Msg) Write-Host "    [WARN] $Msg" -ForegroundColor Yellow }
function Write-Err  { param([string]$Msg) Write-Host "    [FAIL] $Msg" -ForegroundColor Red }

# Loader
# Bump $LibVersion only when the loader<->lib contract changes; every lib file carries the
# matching '# lab-bootstrap lib N' on its first line.
$LibVersion = 1
$LibFiles   = 'env','net','install','tools','shell','verify'

# TLS is the whole integrity story here: this file itself arrived over it, so anything that can
# rewrite lib/ can rewrite the loader and skip lib/ entirely. What must not happen is a silent
# downgrade to plain http on a school network. Loopback is exempt so the modules can be served
# locally for testing.
if ($BaseUrl -notmatch '^https://' -and $BaseUrl -notmatch '^http://(127\.0\.0\.1|localhost)(:\d+)?(/|$)') {
    throw "-BaseUrl must be https: $BaseUrl"
}

function Get-LibSource {
    param([string]$Name)

    # A copy on disk wins - that is development, and the documented install path. $PSScriptRoot
    # is empty under 'irm | iex', which is exactly the signal that there is no local tree.
    $local = if ($PSScriptRoot) { Join-Path $PSScriptRoot "lib\$Name.ps1" } else { $null }
    if ($local -and (Test-Path $local)) {
        return [pscustomobject]@{ From = $local; Text = (Get-Content $local -Raw) }
    }

    # Invoke-WebRequest, not Invoke-RestMethod: irm deserializes whenever the server labels the
    # body JSON, and we would get an object where source text is required.
    $url = "$BaseUrl/lib/$Name.ps1"
    try {
        $res = Invoke-WebRequest -Uri $url -Headers @{ 'User-Agent' = 'lab-bootstrap' } -TimeoutSec 60
    } catch {
        # The raw web exception names neither the file nor the fix, and the fix is nearly always
        # one of these two on a lab PC.
        throw "cannot fetch $url`n$($_.Exception.Message)`nRunning from a copied bootstrap.ps1? Copy the whole folder, lib/ included."
    }
    return [pscustomobject]@{ From = $url; Text = [string]$res.Content }
}

# Two passes. Dot-sourcing as we fetch would leave, on a mid-way failure, a session with four of
# six modules loaded and no way to tell which. Nothing is installed at this point, so failing the
# whole load costs a retry and nothing else.
$libs = [ordered]@{}
foreach ($n in $LibFiles) {
    $lib = Get-LibSource $n
    # A captive portal, a 404 page and a truncated CDN response are all 'a string'. Dot-sourcing
    # one gives a parser error that never mentions where the text came from.
    if ($lib.Text -notmatch "(?m)^# lab-bootstrap lib $LibVersion\b") {
        throw "not a lab-bootstrap lib $LibVersion file: $($lib.From)`nCopy the whole folder, not just bootstrap.ps1."
    }
    $libs[$n] = $lib
}
# Script scope on purpose: dot-sourcing inside a function would put every definition in that
# function's scope, and the Direct-* scriptblocks would lose sight of $InstallDir and the pins.
foreach ($n in $LibFiles) { . ([scriptblock]::Create($libs[$n].Text)) }

# Main
Assert-Admin

if (-not (Test-Path $LogDir)) { New-Item -ItemType Directory -Path $LogDir -Force | Out-Null }
$log = Join-Path $LogDir ("bootstrap_{0}.log" -f (Get-Date -Format 'yyyyMMdd_HHmmss'))
Start-Transcript -Path $log -Force | Out-Null

$wingetState = if ($NoWinget) { 'off (-NoWinget)' } elseif (Test-Winget) { 'yes' } else { 'not found' }
Write-Host "Cloud Lab Bootstrap   pwsh $($PSVersionTable.PSVersion)   kubectl $KubectlMinor   winget: $wingetState   force: $Force" -ForegroundColor Magenta
Write-Host "  dir $InstallDir"
Write-Host "  log $log"

if (-not (Test-Path $InstallDir)) { New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null }
Add-SystemPath $InstallDir

# Install calls stay on the left of -and so they always run (no short-circuit).
$ok = $true
$ok = (Install-Tool -Name 'AWS CLI v2'   -Cmd 'aws'                    -WingetId 'Amazon.AWSCLI'               -Direct   ${function:Direct-AwsCli})    -and $ok
$ok = (Install-Tool -Name 'SSM plugin'   -Cmd 'session-manager-plugin' -WingetId 'Amazon.SessionManagerPlugin' -Direct   ${function:Direct-Ssm})       -and $ok
$ok = (Install-Tool -Name 'Helm'         -Cmd 'helm'                   -WingetId 'Helm.Helm'                   -Direct   ${function:Direct-Helm})      -and $ok
$ok = (Install-Tool -Name 'eksctl'       -Cmd 'eksctl'                 -WingetId $null                         -Direct   ${function:Direct-Eksctl})    -and $ok
$ok = (Install-Tool -Name 'Terraform'    -Cmd 'terraform'              -WingetId 'Hashicorp.Terraform'         -Direct   ${function:Direct-Terraform}) -and $ok
$ok = (Install-Tool -Name 'VS Code'      -Cmd 'code'                   -WingetId 'Microsoft.VisualStudioCode'  -Direct   ${function:Direct-VSCode})    -and $ok
$ok = (Install-Tool -Name 'k9s'          -Cmd 'k9s'                    -WingetId 'Derailed.k9s'                -Direct   ${function:Direct-K9s})       -and $ok
$ok = (Install-Tool -Name 'zoxide'       -Cmd 'zoxide'                 -WingetId 'ajeetdsouza.zoxide'          -Direct   ${function:Direct-Zoxide})    -and $ok
$ok = (Install-Tool -Name 'Mark (mdv)'   -Cmd 'mdv'                    -WingetId $null                         -Direct   ${function:Direct-Mark})      -and $ok
$ok = (Install-Tool -Name 'Neovim'       -Cmd 'nvim'                   -WingetId 'Neovim.Neovim'               -Direct   ${function:Direct-Neovim})    -and $ok
$ok = (Install-MiniNvim)                 -and $ok   # after Neovim: plugs into its runtime tree

# Installing git-lfs does not hook it into git. Own scope with EAP=Continue because git
# writes hints to stderr and can return non-zero while succeeding, so judge by exit code.
if ((Test-Tool 'git') -and (Test-Tool 'git-lfs')) {
    & {
        $ErrorActionPreference = 'Continue'
        git lfs install --system 2>&1 | Out-Null
        if ($LASTEXITCODE -eq 0) { Write-Ok "git lfs hooks registered" }
        else { Write-Warn "git lfs install --system failed (exit $LASTEXITCODE)" }
    }
}

$ok = (Install-Kubectl)      -and $ok
$ok = (Enable-SshAgent)      -and $ok
$ok = (Install-Completions)  -and $ok   # after the tools: bakes only what actually got installed
$ok = (Install-BootRc)       -and $ok   # last: the block dot-sources what Install-Completions wrote

Invoke-Verification

Stop-Transcript | Out-Null

# Only exit when run as a file: 'exit' inside an iex'd one-liner would close the user's window.
if ($PSCommandPath) {
    if ($ok) { exit 0 } else { exit 1 }
}
if (-not $ok) { Write-Host "Some steps failed. Log: $log" -ForegroundColor Red }
