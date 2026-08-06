# lab-bootstrap lib 1
# SPDX-License-Identifier: BSD-3-Clause
# Copyright 2026 The ISHS Cloud Computing Authors
#
# Per-vendor facts: URLs, installer flags, version lookups. The file that changes when a vendor
# changes something. The version pins themselves stay in bootstrap.ps1 - they are course policy,
# not implementation, and README points maintainers at that one file.
# Provided by the loader: $InstallDir $KubectlMap $KubectlMinor $Force
#                         $HelmPinned $TerraformPinned $GitLfsPinned $GitPinnedUrl
# Definitions only - no top-level code, so load order never matters.

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
