# SPDX-License-Identifier: BSD-3-Clause
# Copyright 2026 The ISHS Cloud Computing Authors

#Requires -Version 7
<#
.SYNOPSIS
    Installs the cloud computing lab toolchain on a school lab Windows PC.

.DESCRIPTION
    Installs Git, Git LFS, AWS CLI v2, SSM plugin, Helm, eksctl, kubectl, Terraform,
    VS Code and k9s. winget first, direct download from each vendor as fallback.
    Idempotent: already-installed tools are skipped. Needs admin; self-elevates via UAC.

    kubectl is the exception: dl.k8s.io is blocked by the school firewall (and the
    winget/choco packages download from there too), so it comes from the Amazon EKS S3
    mirror instead, verified against the published SHA256.

.PARAMETER KubectlMinor
    kubectl minor version, looked up in $KubectlMap. Match it to the EKS cluster in use.

.PARAMETER InstallDir
    Where portable binaries go. Added to the system PATH.

.PARAMETER NoWinget
    Skip winget; install everything by direct download.

.PARAMETER Force
    Reinstall even if the tool is already present.

.PARAMETER Custom
    Names of customization scripts to run after the install, from customs/ in this repo.
    Names only, never URLs: the repo (and its review) is the only way code gets in here.

.PARAMETER BaseUrl
    Where customs/ is fetched from when this script runs without a file on disk (irm | iex).

.EXAMPLE
    pwsh -ExecutionPolicy Bypass -File .\bootstrap.ps1

.EXAMPLE
    pwsh -ExecutionPolicy Bypass -File .\bootstrap.ps1 -KubectlMinor 1.31 -Force

.EXAMPLE
    pwsh -ExecutionPolicy Bypass -File .\bootstrap.ps1 -Custom zenru
#>
[CmdletBinding()]
param(
    [string]$KubectlMinor = "1.36",
    [string]$InstallDir   = "C:\cloud-tools\bin",
    [switch]$NoWinget,
    [switch]$Force,
    [string[]]$Custom     = @(),
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
$GitLfsPinned    = "3.7.1"
# Git for Windows tags and asset names carry different versions (v2.55.0.windows.3 vs
# Git-2.55.0.3-64-bit.exe), so pin the URL rather than a version.
$GitPinnedUrl    = 'https://github.com/git-for-windows/git/releases/download/v2.55.0.windows.3/Git-2.55.0.3-64-bit.exe'

$EnvKey = 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Environment'

# Shell integration lands next to the binaries, not inside them: $InstallDir is on PATH and
# profile scripts have no business being resolvable as commands. One directory, not one file:
# several customs can each drop their own .ps1 without overwriting each other.
$ToolsRoot = Split-Path $InstallDir -Parent
$ProfileD  = Join-Path $ToolsRoot 'profile.d'

# Logging
function Write-Step { param([string]$Msg) Write-Host "`n==> $Msg" -ForegroundColor Cyan }
function Write-Ok   { param([string]$Msg) Write-Host "    [OK]   $Msg" -ForegroundColor Green }
function Write-Skip { param([string]$Msg) Write-Host "    [SKIP] $Msg" -ForegroundColor DarkGray }
function Write-Warn { param([string]$Msg) Write-Host "    [WARN] $Msg" -ForegroundColor Yellow }
function Write-Err  { param([string]$Msg) Write-Host "    [FAIL] $Msg" -ForegroundColor Red }

# Elevation
function Assert-Admin {
    $id  = [Security.Principal.WindowsIdentity]::GetCurrent()
    $pri = New-Object Security.Principal.WindowsPrincipal($id)
    if ($pri.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { return }

    Write-Warn "Not administrator. Re-launching elevated..."

    # No file path (irm | iex) means there is nothing to re-launch. Throw rather than exit:
    # 'exit' would close the user's interactive window before they can read why. A throw
    # still yields exit code 1 when the script runs as a file.
    if ([string]::IsNullOrEmpty($PSCommandPath)) {
        throw "Cannot self-elevate without a script file. Start pwsh as administrator, then retry."
    }

    $pwsh    = (Get-Process -Id $PID).Path
    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"",
                 '-KubectlMinor', $KubectlMinor, '-InstallDir', "`"$InstallDir`"",
                 '-BaseUrl', "`"$BaseUrl`"")
    if ($NoWinget) { $argList += '-NoWinget' }
    if ($Force)    { $argList += '-Force' }
    # Forget this and the customs vanish silently when UAC hands over to the new process.
    if ($Custom)   { $argList += @('-Custom', ($Custom -join ',')) }

    try {
        Start-Process -FilePath $pwsh -Verb RunAs -ArgumentList $argList
    } catch {
        throw "Elevation declined. Run this from an administrator pwsh."
    }
    exit 0   # the elevated process takes over
}

# Utilities

# Picks up PATH entries that installers just registered, without restarting the shell.
function Sync-Path {
    $machine = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    $user    = [Environment]::GetEnvironmentVariable('Path', 'User')
    $env:Path = @($machine, $user, $InstallDir | Where-Object { $_ }) -join ';'
}

function Test-Tool { param([string]$Cmd) [bool](Get-Command $Cmd -ErrorAction SilentlyContinue) }

# [Environment]::SetEnvironmentVariable broadcasts this for us; a direct registry write does
# not, and without it Explorer-spawned terminals keep the old PATH until logoff.
function Publish-EnvChange {
    if (-not ('Win32.NativeMethods' -as [type])) {
        Add-Type -Namespace 'Win32' -Name 'NativeMethods' -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("user32.dll", SetLastError = true, CharSet = System.Runtime.InteropServices.CharSet.Unicode)]
public static extern System.IntPtr SendMessageTimeout(System.IntPtr hWnd, uint Msg, System.UIntPtr wParam,
    string lParam, uint fuFlags, uint uTimeout, out System.UIntPtr lpdwResult);
'@
    }
    $res = [System.UIntPtr]::Zero
    # HWND_BROADCAST, WM_SETTINGCHANGE, SMTO_ABORTIFHUNG, 5s timeout
    [void][Win32.NativeMethods]::SendMessageTimeout([IntPtr]0xFFFF, 0x1A, [System.UIntPtr]::Zero,
                                                    'Environment', 2, 5000, [ref]$res)
}

function Add-SystemPath {
    param([string]$Dir)
    # Read raw: [Environment]::GetEnvironmentVariable('Path','Machine') expands REG_EXPAND_SZ,
    # so writing it back would freeze %SystemRoot% into a literal and downgrade it to REG_SZ.
    $cur   = (Get-Item $EnvKey).GetValue('Path', '', 'DoNotExpandEnvironmentNames')
    $parts = $cur -split ';' | Where-Object { $_ }
    if ($parts -notcontains $Dir) {
        Set-ItemProperty -Path $EnvKey -Name 'Path' -Value ($cur.TrimEnd(';') + ';' + $Dir) -Type ExpandString
        Publish-EnvChange
        Write-Ok "PATH += $Dir"
    }
    Sync-Path
}

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

# Install one tool: winget, then the fallback scriptblock
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

# Direct download per tool
function Fallback-AwsCli {
    $msi = Join-Path $env:TEMP 'AWSCLIV2.msi'
    Get-Download 'https://awscli.amazonaws.com/AWSCLIV2.msi' $msi
    Start-Process msiexec.exe -ArgumentList "/i `"$msi`" /qn /norestart" -Wait
    Remove-Item $msi -Force -ErrorAction SilentlyContinue
}

function Fallback-Ssm {
    $exe = Join-Path $env:TEMP 'SessionManagerPluginSetup.exe'
    Get-Download 'https://s3.amazonaws.com/session-manager-downloads/plugin/latest/windows/SessionManagerPluginSetup.exe' $exe
    Start-Process $exe -ArgumentList '/quiet' -Wait
    Remove-Item $exe -Force -ErrorAction SilentlyContinue
}

function Fallback-Helm {
    $ver = Get-LatestOrPinned -Repo 'helm/helm' -Pinned $HelmPinned -Label 'Helm'
    $zip = Join-Path $env:TEMP "helm-$ver.zip"
    Get-Download "https://get.helm.sh/helm-v$ver-windows-amd64.zip" $zip
    Expand-ToInstallDir -Zip $zip -ExeName 'helm.exe'
    Remove-Item $zip -Force -ErrorAction SilentlyContinue
    Add-SystemPath $InstallDir
}

function Fallback-Eksctl {
    $zip = Join-Path $env:TEMP 'eksctl.zip'
    Get-Download 'https://github.com/eksctl-io/eksctl/releases/latest/download/eksctl_Windows_amd64.zip' $zip
    Expand-ToInstallDir -Zip $zip -ExeName 'eksctl.exe'
    Remove-Item $zip -Force -ErrorAction SilentlyContinue
    Add-SystemPath $InstallDir
}

function Fallback-Terraform {
    $ver = $TerraformPinned
    try {
        $c = Invoke-RestMethod -Uri 'https://checkpoint-api.hashicorp.com/v1/check/terraform' `
                               -Headers @{ 'User-Agent' = 'lab-bootstrap' } -TimeoutSec 30
        if ($c.current_version) { $ver = $c.current_version }
    } catch { Write-Warn "Terraform lookup failed, using pin $TerraformPinned" }
    $zip = Join-Path $env:TEMP "terraform-$ver.zip"
    Get-Download "https://releases.hashicorp.com/terraform/$ver/terraform_${ver}_windows_amd64.zip" $zip
    Expand-ToInstallDir -Zip $zip -ExeName 'terraform.exe'
    Remove-Item $zip -Force -ErrorAction SilentlyContinue
    Add-SystemPath $InstallDir
}

function Fallback-VSCode {
    $exe = Join-Path $env:TEMP 'VSCodeSetup.exe'
    Get-Download 'https://update.code.visualstudio.com/latest/win32-x64/stable' $exe
    # Inno Setup: !runcode = do not launch after install, addtopath = register PATH
    Start-Process $exe -ArgumentList '/VERYSILENT','/NORESTART','/MERGETASKS=!runcode,addtopath' -Wait
    Remove-Item $exe -Force -ErrorAction SilentlyContinue
}

function Fallback-K9s {
    $zip = Join-Path $env:TEMP 'k9s.zip'
    Get-Download 'https://github.com/derailed/k9s/releases/latest/download/k9s_Windows_amd64.zip' $zip
    Expand-ToInstallDir -Zip $zip -ExeName 'k9s.exe'
    Remove-Item $zip -Force -ErrorAction SilentlyContinue
    Add-SystemPath $InstallDir
}

function Fallback-Git {
    $url = $GitPinnedUrl
    try {
        $rel   = Invoke-RestMethod -Uri 'https://api.github.com/repos/git-for-windows/git/releases/latest' `
                                   -Headers @{ 'User-Agent' = 'lab-bootstrap' } -TimeoutSec 30
        $asset = $rel.assets | Where-Object { $_.name -like 'Git-*-64-bit.exe' } | Select-Object -First 1
        if ($asset) { $url = $asset.browser_download_url }
    } catch { Write-Warn "Git lookup failed, using pinned URL" }
    $exe = Join-Path $env:TEMP (Split-Path $url -Leaf)
    Get-Download $url $exe
    Start-Process $exe -ArgumentList '/VERYSILENT','/NORESTART','/NOCANCEL','/SP-' -Wait
    Remove-Item $exe -Force -ErrorAction SilentlyContinue
}

function Fallback-GitLfs {
    $ver = Get-LatestOrPinned -Repo 'git-lfs/git-lfs' -Pinned $GitLfsPinned -Label 'Git LFS'
    $zip = Join-Path $env:TEMP 'git-lfs.zip'
    Get-Download "https://github.com/git-lfs/git-lfs/releases/download/v$ver/git-lfs-windows-amd64-v$ver.zip" $zip
    Expand-ToInstallDir -Zip $zip -ExeName 'git-lfs.exe'
    Remove-Item $zip -Force -ErrorAction SilentlyContinue
    Add-SystemPath $InstallDir
}

# Extension points for customs/

# Bake each tool's completion script to a file. Running the generators at shell startup instead
# would cost 100-300ms per tool on every new terminal; this way the profile only dot-sources.
function Write-ToolCompletion {
    param([string]$Cmd, [string]$Alias)
    if (-not (Test-Tool $Cmd)) { return }

    # Same reason as Invoke-Verification: generators write hints to stderr, which EAP=Stop
    # would report as failure. Function scope, so it is restored on return.
    $ErrorActionPreference = 'Continue'
    try {
        $s = (& $Cmd completion powershell 2>$null | Out-String)
        if ($LASTEXITCODE -ne 0 -or -not $s.Trim()) { throw "no completion output (exit $LASTEXITCODE)" }

        # cobra writes "Completion ended with directive: ..." to stderr on every request, and its
        # own '2>&1 | Out-Null' misses it: the redirection binds to Invoke-Expression, not to the
        # native command inside the string it evaluates. Push it inside the string. No match
        # (other generator, other version) just means the noise stays; completion still works.
        $s = $s -replace '(?m)^(\s*Invoke-Expression\s+-OutVariable\s+out\s+"\$RequestComp)("\s*)2>&1', '$1 2>`$$null$2'

        # The generated script registers the completer under the real command name only.
        # Reuse its script block for the alias rather than regenerating anything.
        if ($Alias) {
            # cobra emits: Register-ArgumentCompleter -CommandName 'kubectl' -ScriptBlock ${__kubectlCompleterBlock}
            if ($s -match "(?m)^Register-ArgumentCompleter\s+(?:-Native\s+)?-CommandName\s+'?$Cmd'?\s+-ScriptBlock\s+(\`$\{?\w+\}?)") {
                $s += "`nRegister-ArgumentCompleter -CommandName '$Alias' -ScriptBlock $($Matches[1])`n"
            } else {
                Write-Warn "$Cmd : alias '$Alias' gets no completion (unexpected generator output)"
            }
        }

        Set-Content -Path (Join-Path $ProfileD "$Cmd.ps1") -Value $s -Encoding UTF8
        Write-Ok "$Cmd completion"
    } catch {
        Write-Warn "$Cmd completion skipped: $($_.Exception.Message)"
    }
}

# The profile.d loader. Installed whether or not any custom runs: an empty directory loads fine,
# and having it always present means a custom never has to touch the shared profile itself.
function Install-ProfileHook {
    Write-Step "profile.d"

    try {
        # Wiped on every run and refilled by whatever -Custom asks for. One rule to remember:
        # what you pass is what is active. No leftovers from a custom you dropped.
        if (Test-Path $ProfileD) { Remove-Item (Join-Path $ProfileD '*.ps1') -Force -ErrorAction SilentlyContinue }
        New-Item -ItemType Directory -Path $ProfileD -Force | Out-Null

        # Append one line; never rewrite the shared profile, it may not be ours.
        $p    = $PROFILE.AllUsersAllHosts
        $line = "Get-ChildItem '$ProfileD\*.ps1' -ErrorAction SilentlyContinue | ForEach-Object { . `$_.FullName }"
        $cur  = if (Test-Path $p) { Get-Content $p -Raw } else { '' }
        if ($cur -match [regex]::Escape($ProfileD)) {
            Write-Skip "profile already hooked"
        } else {
            New-Item -ItemType Directory -Path (Split-Path $p -Parent) -Force | Out-Null
            Add-Content -Path $p -Value "`n# lab-bootstrap`n$line`n" -Encoding UTF8
            Write-Ok "hooked into $p"
        }
        return $true
    } catch {
        Write-Err $_.Exception.Message
        return $false
    }
}

# Run the requested customization scripts. They are dot-sourced, so they see every function and
# variable above; customs/README.md documents which of those are meant to be used.
function Invoke-Customs {
    $allOk = $true
    foreach ($name in $Custom) {
        # A name, never a URL or a path. This is the trust boundary: code can only arrive here
        # through the repo, which means through review. It also blocks '../../evil'.
        if ($name -notmatch '^[a-z0-9][a-z0-9-]*$') {
            Write-Err "invalid custom name: $name"
            $allOk = $false
            continue
        }

        Write-Step "custom: $name"
        try {
            # Local copy wins when running from a file: development, and USB drops on a lab PC
            # where only the S3/GitHub endpoints are blocked.
            $local = if ($PSScriptRoot) { Join-Path $PSScriptRoot "customs\$name.ps1" } else { $null }
            if ($local -and (Test-Path $local)) {
                Write-Ok "source $local"
                . $local
            } else {
                $url = "$BaseUrl/customs/$name.ps1"
                Write-Ok "source $url"
                $src = Invoke-RestMethod -Uri $url -Headers @{ 'User-Agent' = 'lab-bootstrap' } -TimeoutSec 60
                . ([scriptblock]::Create($src))
            }
        } catch {
            # One bad custom must not take the toolchain install down with it.
            Write-Err "custom '$name' failed: $($_.Exception.Message)"
            $allOk = $false
        }
    }
    return $allOk
}

# kubectl: EKS S3 mirror instead of the blocked dl.k8s.io
function Install-Kubectl {
    Write-Step "kubectl (EKS S3 mirror)"

    if (-not $Force -and (Test-Tool 'kubectl')) { Write-Skip "already installed"; return $true }

    if (-not $KubectlMap.ContainsKey($KubectlMinor)) {
        Write-Err "unsupported version $KubectlMinor (have: $($KubectlMap.Keys -join ', '))"
        return $false
    }
    $info = $KubectlMap[$KubectlMinor]
    $base = "https://s3.us-west-2.amazonaws.com/amazon-eks/$($info.v)/$($info.d)/bin/windows/amd64"

    try {
        $exe    = Join-Path $env:TEMP 'kubectl.exe'
        $shaTxt = Join-Path $env:TEMP 'kubectl.exe.sha256'
        Get-Download "$base/kubectl.exe"        $exe
        Get-Download "$base/kubectl.exe.sha256" $shaTxt

        $expected = (Get-Content $shaTxt -Raw).Trim().Split()[0].ToLower()
        $actual   = (Get-FileHash $exe -Algorithm SHA256).Hash.ToLower()
        if ($expected -ne $actual) {
            Write-Err "SHA256 mismatch (expected $expected, got $actual)"
            Remove-Item $exe, $shaTxt -Force -ErrorAction SilentlyContinue
            return $false
        }

        if (-not (Test-Path $InstallDir)) { New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null }
        Copy-Item $exe (Join-Path $InstallDir 'kubectl.exe') -Force
        Remove-Item $exe, $shaTxt -Force -ErrorAction SilentlyContinue
        Add-SystemPath $InstallDir

        if (Test-Tool 'kubectl') { Write-Ok "installed $($info.v), SHA256 verified"; return $true }
        Write-Err "installed but 'kubectl' is not on PATH"
        return $false
    } catch {
        Write-Err $_.Exception.Message
        Write-Warn "check whether the S3 amazon-eks endpoint is blocked too"
        return $false
    }
}

# ssh-agent: Automatic so it survives the lab PC reboot
function Enable-SshAgent {
    Write-Step "ssh-agent"

    if (-not (Get-Service -Name 'ssh-agent' -ErrorAction SilentlyContinue)) {
        Write-Warn "service missing. Add 'OpenSSH Client' in Settings > Apps > Optional features"
        return $false
    }

    try {
        # Must precede Start-Service: some machines ship this service Disabled.
        Set-Service -Name 'ssh-agent' -StartupType Automatic -ErrorAction Stop
        if ((Get-Service -Name 'ssh-agent').Status -ne 'Running') { Start-Service -Name 'ssh-agent' -ErrorAction Stop }
        Write-Ok "running, startup Automatic"
        return $true
    } catch {
        Write-Err $_.Exception.Message
        return $false
    }
}

# Verify
function Invoke-Verification {
    # These tools may write to stderr or return non-zero while healthy, which EAP=Stop would
    # report as a failure. Function scope, so it is restored on return.
    $ErrorActionPreference = 'Continue'

    Write-Step "Verify"
    Sync-Path
    $checks = @(
        @{ Name = 'Git';        Cmd = 'git';                    Args = @('--version') }
        @{ Name = 'Git LFS';    Cmd = 'git-lfs';                Args = @('version') }
        @{ Name = 'AWS CLI';    Cmd = 'aws';                    Args = @('--version') }
        @{ Name = 'SSM plugin'; Cmd = 'session-manager-plugin'; Args = @('--version') }
        @{ Name = 'Helm';       Cmd = 'helm';                   Args = @('version','--short') }
        @{ Name = 'eksctl';     Cmd = 'eksctl';                 Args = @('version') }
        @{ Name = 'kubectl';    Cmd = 'kubectl';                Args = @('version','--client') }
        @{ Name = 'Terraform';  Cmd = 'terraform';              Args = @('version') }
        @{ Name = 'VS Code';    Cmd = 'code';                   Args = @('--version') }
        @{ Name = 'k9s';        Cmd = 'k9s';                    Args = @('version','-s') }
    )
    $fails = @()
    foreach ($c in $checks) {
        if (-not (Test-Tool $c.Cmd)) {
            Write-Err ("{0,-11} not on PATH" -f $c.Name)
            $fails += $c.Name
            continue
        }
        try {
            $out = (& $c.Cmd @($c.Args) 2>&1 | Select-Object -First 1) -join ' '
            Write-Ok ("{0,-11} {1}" -f $c.Name, $out)
        } catch {
            Write-Err ("{0,-11} version check failed" -f $c.Name)
            $fails += $c.Name
        }
    }

    $ssh = Get-Service -Name 'ssh-agent' -ErrorAction SilentlyContinue
    if ($ssh) { Write-Ok ("{0,-11} {1} ({2})" -f 'ssh-agent', $ssh.Status, $ssh.StartType) }
    else      { Write-Err ("{0,-11} service missing" -f 'ssh-agent') }

    if ($Custom) { Write-Ok ("{0,-11} {1} (new terminal required)" -f 'customs', ($Custom -join ', ')) }

    Write-Host ""
    if ($fails.Count -eq 0) { Write-Host "All tools OK." -ForegroundColor Green }
    else { Write-Host ("Failed: {0}" -f ($fails -join ', ')) -ForegroundColor Red }
    Write-Host "Open a new terminal for PATH changes." -ForegroundColor DarkGray
}

# Main
Assert-Admin

$logDir = Join-Path $env:TEMP 'lab-bootstrap'
if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
$log = Join-Path $logDir ("bootstrap_{0}.log" -f (Get-Date -Format 'yyyyMMdd_HHmmss'))
Start-Transcript -Path $log -Force | Out-Null

$wingetState = if ($NoWinget) { 'off (-NoWinget)' } elseif (Test-Winget) { 'yes' } else { 'not found' }
Write-Host "Cloud Lab Bootstrap   pwsh $($PSVersionTable.PSVersion)   kubectl $KubectlMinor   winget: $wingetState   force: $Force" -ForegroundColor Magenta
Write-Host "  dir $InstallDir" -ForegroundColor DarkGray
if ($Custom) { Write-Host "  custom $($Custom -join ', ')" -ForegroundColor DarkGray }
Write-Host "  log $log" -ForegroundColor DarkGray

if (-not (Test-Path $InstallDir)) { New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null }
Add-SystemPath $InstallDir

# Install calls stay on the left of -and so they always run (no short-circuit).
$ok = $true
$ok = (Install-Tool -Name 'Git'          -Cmd 'git'                    -WingetId 'Git.Git'                     -Fallback ${function:Fallback-Git})       -and $ok
$ok = (Install-Tool -Name 'Git LFS'      -Cmd 'git-lfs'                -WingetId 'GitHub.GitLFS'               -Fallback ${function:Fallback-GitLfs})    -and $ok
$ok = (Install-Tool -Name 'AWS CLI v2'   -Cmd 'aws'                    -WingetId 'Amazon.AWSCLI'               -Fallback ${function:Fallback-AwsCli})    -and $ok
$ok = (Install-Tool -Name 'SSM plugin'   -Cmd 'session-manager-plugin' -WingetId 'Amazon.SessionManagerPlugin' -Fallback ${function:Fallback-Ssm})       -and $ok
$ok = (Install-Tool -Name 'Helm'         -Cmd 'helm'                   -WingetId 'Helm.Helm'                   -Fallback ${function:Fallback-Helm})      -and $ok
$ok = (Install-Tool -Name 'eksctl'       -Cmd 'eksctl'                 -WingetId $null                         -Fallback ${function:Fallback-Eksctl})    -and $ok
$ok = (Install-Tool -Name 'Terraform'    -Cmd 'terraform'              -WingetId 'Hashicorp.Terraform'         -Fallback ${function:Fallback-Terraform}) -and $ok
$ok = (Install-Tool -Name 'VS Code'      -Cmd 'code'                   -WingetId 'Microsoft.VisualStudioCode'  -Fallback ${function:Fallback-VSCode})    -and $ok
$ok = (Install-Tool -Name 'k9s'          -Cmd 'k9s'                    -WingetId 'Derailed.k9s'                -Fallback ${function:Fallback-K9s})       -and $ok

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

$ok = (Install-Kubectl)     -and $ok
$ok = (Enable-SshAgent)     -and $ok
$ok = (Install-ProfileHook) -and $ok
$ok = (Invoke-Customs)      -and $ok   # last: customs decide based on what actually got installed

Invoke-Verification

Stop-Transcript | Out-Null

# Only exit when run as a file: 'exit' inside an iex'd one-liner would close the user's window.
if ($PSCommandPath) {
    if ($ok) { exit 0 } else { exit 1 }
}
if (-not $ok) { Write-Host "Some tools failed. Log: $log" -ForegroundColor Red }
