# lab-bootstrap lib 1
# SPDX-License-Identifier: BSD-3-Clause
# Copyright 2026 The ISHS Cloud Computing Authors
#
# Per-vendor facts: URLs, installer flags, version lookups. The file that changes when a vendor
# changes something. The version pins themselves stay in bootstrap.ps1 - they are course policy,
# not implementation, and README points maintainers at that one file.
# Provided by the loader: $InstallDir $ToolsRoot $KubectlMap $KubectlMinor $Force
#                         $HelmPinned $TerraformPinned $ZoxidePinned
# Definitions only - no top-level code, so load order never matters.

# Direct download per tool
function Direct-AwsCli {
    $msi = Join-Path $env:TEMP 'AWSCLIV2.msi'
    Get-Download 'https://awscli.amazonaws.com/AWSCLIV2.msi' $msi
    Start-Process msiexec.exe -ArgumentList "/i `"$msi`" /qn /norestart" -Wait
    Remove-Item $msi -Force -ErrorAction SilentlyContinue
}

function Direct-Ssm {
    $exe = Join-Path $env:TEMP 'SessionManagerPluginSetup.exe'
    Get-Download 'https://s3.amazonaws.com/session-manager-downloads/plugin/latest/windows/SessionManagerPluginSetup.exe' $exe
    Start-Process $exe -ArgumentList '/quiet' -Wait
    Remove-Item $exe -Force -ErrorAction SilentlyContinue
}

function Direct-Helm {
    $ver = Get-LatestOrPinned -Repo 'helm/helm' -Pinned $HelmPinned -Label 'Helm'
    $zip = Join-Path $env:TEMP "helm-$ver.zip"
    Get-Download "https://get.helm.sh/helm-v$ver-windows-amd64.zip" $zip
    Expand-ToInstallDir -Zip $zip -ExeName 'helm.exe'
    Remove-Item $zip -Force -ErrorAction SilentlyContinue
    Add-SystemPath $InstallDir
}

function Direct-Eksctl {
    $zip = Join-Path $env:TEMP 'eksctl.zip'
    Get-Download 'https://github.com/eksctl-io/eksctl/releases/latest/download/eksctl_Windows_amd64.zip' $zip
    Expand-ToInstallDir -Zip $zip -ExeName 'eksctl.exe'
    Remove-Item $zip -Force -ErrorAction SilentlyContinue
    Add-SystemPath $InstallDir
}

function Direct-Terraform {
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

function Direct-VSCode {
    $exe = Join-Path $env:TEMP 'VSCodeSetup.exe'
    Get-Download 'https://update.code.visualstudio.com/latest/win32-x64/stable' $exe
    # Inno Setup: !runcode = do not launch after install, addtopath = register PATH
    Start-Process $exe -ArgumentList '/VERYSILENT','/NORESTART','/MERGETASKS=!runcode,addtopath' -Wait
    Remove-Item $exe -Force -ErrorAction SilentlyContinue
}

function Direct-K9s {
    $zip = Join-Path $env:TEMP 'k9s.zip'
    Get-Download 'https://github.com/derailed/k9s/releases/latest/download/k9s_Windows_amd64.zip' $zip
    Expand-ToInstallDir -Zip $zip -ExeName 'k9s.exe'
    Remove-Item $zip -Force -ErrorAction SilentlyContinue
    Add-SystemPath $InstallDir
}

function Direct-Zoxide {
    # The binary alone is not enough: 'z' only exists after 'zoxide init' runs in the profile,
    # which .bootrc does. This installs the exe; the shell wiring is .bootrc's job.
    $ver = Get-LatestOrPinned -Repo 'ajeetdsouza/zoxide' -Pinned $ZoxidePinned -Label 'zoxide'
    $zip = Join-Path $env:TEMP "zoxide-$ver.zip"
    Get-Download "https://github.com/ajeetdsouza/zoxide/releases/download/v$ver/zoxide-$ver-x86_64-pc-windows-msvc.zip" $zip
    Expand-ToInstallDir -Zip $zip -ExeName 'zoxide.exe'
    Remove-Item $zip -Force -ErrorAction SilentlyContinue
    Add-SystemPath $InstallDir
}

# Neovim is a whole tree (bin, runtime, ...), not one exe, so it unpacks under $ToolsRoot
# and only bin/ goes on PATH.
function Direct-Neovim {
    $zip = Join-Path $env:TEMP 'nvim-win64.zip'
    Get-Download 'https://github.com/neovim/neovim/releases/latest/download/nvim-win64.zip' $zip
    $tmp = Join-Path $env:TEMP 'x_nvim'
    if (Test-Path $tmp) { Remove-Item $tmp -Recurse -Force }
    Expand-Archive -Path $zip -DestinationPath $tmp -Force
    Remove-Item $zip -Force -ErrorAction SilentlyContinue

    $dest = Join-Path $ToolsRoot 'Neovim'
    if (Test-Path $dest) { Remove-Item $dest -Recurse -Force }
    Move-Item (Join-Path $tmp 'nvim-win64') $dest
    Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
    Add-SystemPath (Join-Path $dest 'bin')
}

# mini.nvim: a plugin, not a binary, so Install-Tool's 'is the command on PATH' test cannot
# see it. It goes into Neovim's own runtime pack tree (pack/dist/start autoloads and is on
# packpath for every user, unlike per-user XDG dirs - this is a shared lab PC), and a sysinit
# wires up the basics. Works for winget and zip installs alike: both keep bin\..\share\nvim.
function Install-MiniNvim {
    Write-Step "mini.nvim"

    try {
        if (-not (Test-Tool 'nvim')) { Write-Skip "nvim not installed"; return $true }

        $vimDir  = Join-Path (Split-Path (Split-Path (Get-Command nvim).Source -Parent) -Parent) 'share\nvim'
        $runtime = Join-Path $vimDir 'runtime'
        if (-not (Test-Path $runtime)) { Write-Err "Neovim runtime not found: $runtime"; return $false }

        $dest = Join-Path $runtime 'pack\dist\start\mini.nvim'
        if (-not $Force -and (Test-Path $dest)) { Write-Skip "already installed"; return $true }

        $zip = Join-Path $env:TEMP 'mini.nvim.zip'
        Get-Download 'https://github.com/nvim-mini/mini.nvim/archive/refs/heads/stable.zip' $zip
        $tmp = Join-Path $env:TEMP 'x_mini.nvim'
        if (Test-Path $tmp) { Remove-Item $tmp -Recurse -Force }
        Expand-Archive -Path $zip -DestinationPath $tmp -Force
        Remove-Item $zip -Force -ErrorAction SilentlyContinue

        # GitHub archives nest one folder named after the branch; take it whatever it is called.
        $src = Get-ChildItem -Path $tmp -Directory | Select-Object -First 1
        if (-not $src) { throw "empty mini.nvim archive" }
        if (Test-Path $dest) { Remove-Item $dest -Recurse -Force }
        New-Item -ItemType Directory -Path (Split-Path $dest -Parent) -Force | Out-Null
        Move-Item $src.FullName $dest
        Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue

        # sysinit runs for every user before their own config; pcall keeps nvim quiet if the
        # plugin ever goes missing. The file lives in Neovim's own tree, so it is ours to write.
        @'
" Generated by lab-bootstrap. Re-running bootstrap.ps1 overwrites this file.
lua pcall(function() require('mini.basics').setup(); require('mini.statusline').setup() end)
'@ | Set-Content -Path (Join-Path $vimDir 'sysinit.vim') -Encoding UTF8

        Write-Ok "installed into $dest"
        return $true
    } catch {
        Write-Err $_.Exception.Message
        return $false
    }
}

# VS Code extras: the HashiCorp Terraform extension, and workspace trust off so 'code .'
# never prompts per folder. Both are per-user state, so they land on whoever ran bootstrap.
function Install-VSCodeConfig {
    Write-Step "VS Code config"

    try {
        if (-not (Test-Tool 'code')) { Write-Skip "code not installed"; return $true }

        # code.cmd writes noise to stderr, so judge by exit code in a Continue scope.
        $extOk = & {
            $ErrorActionPreference = 'Continue'
            code --install-extension hashicorp.terraform --force 2>&1 | Out-Null
            $LASTEXITCODE -eq 0
        }
        if ($extOk) { Write-Ok "extension hashicorp.terraform" }
        else { Write-Err "extension install failed - marketplace blocked?" }

        # Merge, never clobber: settings.json is user state. VS Code tolerates comments in it
        # (JSONC) but ConvertFrom-Json does not; a file we cannot parse we leave alone.
        $file = Join-Path $env:APPDATA 'Code\User\settings.json'
        New-Item -ItemType Directory -Path (Split-Path $file -Parent) -Force | Out-Null
        $cfg = @{}
        if (Test-Path $file) {
            try { $cfg = Get-Content $file -Raw | ConvertFrom-Json -AsHashtable }
            catch { Write-Warn "settings.json has comments or is invalid - trust setting skipped"; return $extOk }
            if ($null -eq $cfg) { $cfg = @{} }
        }
        if ($cfg['security.workspace.trust.enabled'] -eq $false) {
            Write-Skip "workspace trust already off"
        } else {
            $cfg['security.workspace.trust.enabled'] = $false
            $cfg | ConvertTo-Json -Depth 32 | Set-Content -Path $file -Encoding UTF8
            Write-Ok "workspace trust prompt off"
        }
        return $extOk
    } catch {
        Write-Err $_.Exception.Message
        return $false
    }
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
