# lab-bootstrap lib 1
# SPDX-License-Identifier: BSD-3-Clause
# Copyright 2026 The ISHS Cloud Computing Authors
#
# Per-vendor facts: URLs, installer flags, version lookups. The file that changes when a vendor
# changes something. The version pins themselves stay in bootstrap.ps1 - they are course policy,
# not implementation, and README points maintainers at that one file.
# Provided by the loader: $InstallDir $KubectlMap $KubectlMinor $Force
#                         $HelmPinned $TerraformPinned
# Definitions only - no top-level code, so load order never matters.

# How to ask a tool its version. Only the ones that are not 'X version' are listed.
# lib/verify.ps1 reads the same function, so the summary and the update check can never
# disagree about which command to run.
function Get-VersionArgs {
    param([string]$Cmd)
    switch ($Cmd) {
        'aws'                    { @('--version') }
        'session-manager-plugin' { @('--version') }
        'code'                   { @('--version') }
        'helm'                   { @('version','--short') }
        'kubectl'                { @('version','--client') }
        'k9s'                    { @('version','-s') }
        default                  { @('version') }
    }
}

# Wanted version per tool, for the update check. The installed version is the fallback pin on
# purpose: when the lookup is blocked or rate-limited, 'latest' becomes 'what is already here'
# and the run skips instead of re-downloading a release it cannot name.
# AWS CLI, the SSM plugin and VS Code have none of these - they go through winget upgrade.
function Latest-Helm {
    param([string]$Have)
    Get-LatestOrPinned -Repo 'helm/helm' -Pinned $(if ($Have) { $Have } else { $HelmPinned }) -Label 'Helm'
}

function Latest-Eksctl {
    param([string]$Have)
    Get-LatestOrPinned -Repo 'eksctl-io/eksctl' -Pinned $Have -Label 'eksctl'
}

function Latest-K9s {
    param([string]$Have)
    Get-LatestOrPinned -Repo 'derailed/k9s' -Pinned $Have -Label 'k9s'
}

# HashiCorp is not on GitHub releases for this; checkpoint is the documented endpoint.
function Latest-Terraform {
    param([string]$Have)
    try {
        $c = Invoke-RestMethod -Uri 'https://checkpoint-api.hashicorp.com/v1/check/terraform' `
                               -Headers @{ 'User-Agent' = 'lab-bootstrap' } -TimeoutSec 30
        if ($c.current_version) { return $c.current_version }
    } catch { }
    $pin = if ($Have) { $Have } else { $TerraformPinned }
    Write-Warn "Terraform lookup failed, using $pin"
    return $pin
}

# Direct download per tool. $Ver is the version Install-Tool already resolved; empty means it
# never asked (fresh install), so the fallback resolves it itself.
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
    param([string]$Ver)
    $ver = if ($Ver) { $Ver } else { Latest-Helm }
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
    param([string]$Ver)
    $ver = if ($Ver) { $Ver } else { Latest-Terraform }
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

# kubectl: EKS S3 mirror instead of the blocked dl.k8s.io
function Install-Kubectl {
    Write-Step "kubectl (EKS S3 mirror)"

    # The map is read before the skip check: it names the exact version we want, so the
    # comparison below costs no network call. This is also what makes -KubectlMinor mean
    # something on a PC that already has kubectl - the course pins a minor to match the cluster,
    # and skipping on presence alone left the wrong one in place.
    if (-not $KubectlMap.ContainsKey($KubectlMinor)) {
        Write-Err "unsupported version $KubectlMinor (have: $($KubectlMap.Keys -join ', '))"
        return $false
    }
    $info = $KubectlMap[$KubectlMinor]
    $base = "https://s3.us-west-2.amazonaws.com/amazon-eks/$($info.v)/$($info.d)/bin/windows/amd64"

    $have = $null
    if (-not $Force -and (Test-Tool 'kubectl')) {
        $have = Get-ToolVersion 'kubectl'
        if ($have -eq $info.v) { Write-Skip "up to date ($have)"; return $true }
    }

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

        if (Test-Tool 'kubectl') {
            # Docker Desktop ships its own kubectl ahead of us on PATH. Claiming success here
            # would mean re-downloading this file on every single run and never noticing.
            $now = Get-ToolVersion 'kubectl'
            if ($now -ne $info.v) {
                Write-Warn "$($info.v) written to $InstallDir, but PATH still answers $now - another copy is ahead of it"
                return $true
            }
            $what = if ($have) { "updated $have -> $($info.v)" } else { "installed $($info.v)" }
            Write-Ok "$what, SHA256 verified"
            return $true
        }
        Write-Err "installed but 'kubectl' is not on PATH"
        return $false
    } catch {
        Write-Err $_.Exception.Message
        Write-Warn "check whether the S3 amazon-eks endpoint is blocked too"
        return $false
    }
}
