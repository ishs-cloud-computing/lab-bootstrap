# SPDX-License-Identifier: BSD-3-Clause
# Copyright 2026 The ISHS Cloud Computing Authors

#Requires -Version 5.1
<#
.SYNOPSIS
    학교 실습실 Windows PC에 클라우드 컴퓨팅 실습용 도구를 자동 설치하는 부트스트랩 스크립트.

.DESCRIPTION
    설치 대상: PowerShell 7, Git, Git LFS, AWS CLI v2, SSM(Session Manager) 플러그인, Helm, eksctl, kubectl, Terraform, VS Code, k9s.

    핵심 설계
    ---------
    * winget 우선 설치 → winget이 없거나 실패하면 각 도구 공식 배포처에서 직접 다운로드(fallback).
    * kubectl 은 예외: 공식 배포 사이트(dl.k8s.io)가 학교 방화벽에서 차단되므로,
      winget/choco 를 쓰지 않고 "Amazon EKS 가 S3 에 미러링한 동일 바이너리"를 직접 받는다.
      (AWS 문서: "binary is identical to the upstream community versions")
      받은 뒤 SHA256 로 무결성까지 검증한다.
    * 관리자 권한 필요 → 없으면 자가 승격(UAC) 후 재실행.
    * 재부팅 시 초기화되는 실습 PC 를 가정 → 이미 설치된 도구는 건너뛰는 idempotent 동작.

.PARAMETER KubectlMinor
    설치할 kubectl 마이너 버전 (예: "1.32"). 아래 $KubectlMap 에서 조회한다.
    사용하는 EKS 클러스터 버전에 맞춰 조정. 기본값 "1.36".

.PARAMETER InstallDir
    직접 다운로드(portable) 바이너리를 배치할 폴더. 시스템 PATH 에 추가된다. 기본값 "C:\cloud-tools\bin".

.PARAMETER NoWinget
    winget 을 완전히 건너뛰고 모든 도구를 직접 다운로드로 설치.

.PARAMETER Force
    이미 설치돼 있어도 다시 설치.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\bootstrap.ps1

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\bootstrap.ps1 -KubectlMinor 1.31 -Force
#>
[CmdletBinding()]
param(
    [string]$KubectlMinor = "1.36",
    [string]$InstallDir   = "C:\cloud-tools\bin",
    [switch]$NoWinget,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
$ProgressPreference     = 'SilentlyContinue'   # Invoke-WebRequest 진행률 렌더링 → 다운로드 대폭 가속

# ---------------------------------------------------------------------------
# kubectl 버전 맵 (Amazon EKS S3 미러). 새 버전이 나오면 이 표만 갱신하면 된다.
# 출처: https://docs.aws.amazon.com/eks/latest/userguide/install-kubectl.html
# ---------------------------------------------------------------------------
$KubectlMap = @{
    "1.36" = @{ v = "1.36.2";  d = "2026-06-17" }
    "1.35" = @{ v = "1.35.3";  d = "2026-04-08" }
    "1.34" = @{ v = "1.34.6";  d = "2026-04-08" }
    "1.33" = @{ v = "1.33.10"; d = "2026-04-08" }
    "1.32" = @{ v = "1.32.13"; d = "2026-04-08" }
    "1.31" = @{ v = "1.31.14"; d = "2026-04-08" }
    "1.30" = @{ v = "1.30.14"; d = "2026-04-08" }
}

# 최신 버전 조회 실패 시 사용할 안전 기본값 (pin). 최신값은 실행 시 온라인으로 조회하고,
# 조회 실패할 때만 아래 값을 쓴다. 가끔 최신 버전으로 갱신해두면 좋다.
$HelmPinned      = "4.2.3"
$TerraformPinned = "1.15.8"

# ===========================================================================
# 로깅 헬퍼
# ===========================================================================
function Write-Step { param([string]$Msg) Write-Host "`n==> $Msg" -ForegroundColor Cyan }
function Write-Ok   { param([string]$Msg) Write-Host "    [OK]   $Msg" -ForegroundColor Green }
function Write-Skip { param([string]$Msg) Write-Host "    [SKIP] $Msg" -ForegroundColor DarkGray }
function Write-Warn { param([string]$Msg) Write-Host "    [WARN] $Msg" -ForegroundColor Yellow }
function Write-Err  { param([string]$Msg) Write-Host "    [FAIL] $Msg" -ForegroundColor Red }

# ===========================================================================
# 관리자 권한 확인 + 자가 승격
# ===========================================================================
function Assert-Admin {
    $id  = [Security.Principal.WindowsIdentity]::GetCurrent()
    $pri = New-Object Security.Principal.WindowsPrincipal($id)
    if ($pri.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { return }

    Write-Warn "관리자 권한이 아닙니다. UAC 창을 띄워 관리자로 다시 실행합니다..."

    # irm | iex 처럼 파일 경로 없이 실행된 경우엔 자가 재실행이 불가 → 수동 안내
    if ([string]::IsNullOrEmpty($PSCommandPath)) {
        Write-Err "파일 경로를 알 수 없어 자동 승격을 할 수 없습니다."
        Write-Err "PowerShell 을 '관리자 권한으로 실행' 한 뒤 다시 실행하세요."
        exit 1
    }

    # 현재 스크립트를 동일한 인자로 관리자 권한으로 재실행
    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"",
                 '-KubectlMinor', $KubectlMinor, '-InstallDir', "`"$InstallDir`"")
    if ($NoWinget) { $argList += '-NoWinget' }
    if ($Force)    { $argList += '-Force' }

    try {
        Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList $argList
    } catch {
        Write-Err "관리자 권한 승격이 거부되었습니다. 스크립트를 관리자 PowerShell 에서 실행하세요."
        exit 1
    }
    exit 0   # 승격된 프로세스가 이어받음
}

# ===========================================================================
# 공용 유틸
# ===========================================================================

# 시스템/사용자 PATH 를 레지스트리에서 다시 읽어 현재 세션에 반영
# (installer/winget 이 등록한 PATH 를 재실행 없이 즉시 인식하기 위함)
function Sync-Path {
    $machine = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    $user    = [Environment]::GetEnvironmentVariable('Path', 'User')
    $env:Path = @($machine, $user, $InstallDir | Where-Object { $_ }) -join ';'
}

# 명령이 이미 존재하는지 (설치 완료 판정)
function Test-Tool { param([string]$Cmd) [bool](Get-Command $Cmd -ErrorAction SilentlyContinue) }

# 시스템 PATH 에 폴더 추가 (중복 방지) + 세션 반영
function Add-SystemPath {
    param([string]$Dir)
    $cur = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    $parts = $cur -split ';' | Where-Object { $_ }
    if ($parts -notcontains $Dir) {
        [Environment]::SetEnvironmentVariable('Path', ($cur.TrimEnd(';') + ';' + $Dir), 'Machine')
        Write-Ok "시스템 PATH 에 추가: $Dir"
    }
    Sync-Path
}

# 재시도 포함 다운로드 (TLS1.2 강제)
function Get-Download {
    param([string]$Url, [string]$OutFile, [int]$Retries = 3)
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    for ($i = 1; $i -le $Retries; $i++) {
        try {
            Invoke-WebRequest -Uri $Url -OutFile $OutFile -UseBasicParsing -TimeoutSec 120
            return
        } catch {
            if ($i -eq $Retries) { throw }
            Write-Warn "다운로드 실패($i/$Retries) → 재시도: $Url"
            Start-Sleep -Seconds 3
        }
    }
}

# zip 안에서 특정 exe 를 찾아 InstallDir 로 복사
function Expand-ToInstallDir {
    param([string]$Zip, [string]$ExeName)
    $tmp = Join-Path $env:TEMP ("x_" + [IO.Path]::GetFileNameWithoutExtension($Zip))
    if (Test-Path $tmp) { Remove-Item $tmp -Recurse -Force }
    Expand-Archive -Path $Zip -DestinationPath $tmp -Force
    $exe = Get-ChildItem -Path $tmp -Filter $ExeName -Recurse | Select-Object -First 1
    if (-not $exe) { throw "$ExeName 을 압축파일에서 찾을 수 없습니다: $Zip" }
    Copy-Item $exe.FullName (Join-Path $InstallDir $ExeName) -Force
    Remove-Item $tmp -Recurse -Force
}

# winget 사용 가능 여부
function Test-Winget {
    if ($NoWinget) { return $false }
    return [bool](Get-Command winget -ErrorAction SilentlyContinue)
}

# winget 으로 설치 시도. 성공 여부를 반환.
function Install-Winget {
    param([string]$Id, [string]$Cmd)
    try {
        winget install --id $Id -e --source winget `
            --accept-package-agreements --accept-source-agreements `
            --silent --disable-interactivity | Out-Null
    } catch {
        Write-Warn "winget 실행 오류($Id): $($_.Exception.Message)"
    }
    # winget 종료코드는 '이미 최신' 등 다양 → 명령 존재 여부로 최종 판정
    Sync-Path
    return (Test-Tool $Cmd)
}

# ===========================================================================
# 도구 하나 설치: winget 우선 → 실패 시 Fallback 스크립트블록
# ===========================================================================
function Install-Tool {
    param(
        [string]$Name,
        [string]$Cmd,
        [string]$WingetId,       # $null 이면 winget 미사용 (예: kubectl)
        [scriptblock]$Fallback   # 직접 다운로드 로직
    )
    Write-Step "$Name"

    if (-not $Force -and (Test-Tool $Cmd)) { Write-Skip "이미 설치됨 ($Cmd)"; return $true }

    if ($WingetId -and (Test-Winget)) {
        Write-Host "    winget 으로 설치 시도: $WingetId"
        if (Install-Winget -Id $WingetId -Cmd $Cmd) { Write-Ok "winget 설치 완료 ($WingetId)"; return $true }
        Write-Warn "winget 설치 실패 → 직접 다운로드로 fallback"
    }

    try {
        & $Fallback
        Sync-Path
        if (Test-Tool $Cmd) { Write-Ok "직접 다운로드 설치 완료"; return $true }
        Write-Err "$Name 설치 후에도 '$Cmd' 명령을 찾을 수 없습니다."
        return $false
    } catch {
        Write-Err "$Name 설치 실패: $($_.Exception.Message)"
        return $false
    }
}

# ===========================================================================
# 개별 도구의 직접 다운로드(fallback) 로직
# ===========================================================================
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
    $ver = $HelmPinned
    try {                                            # 최신 릴리스 태그(예: v3.16.3) 조회, 실패하면 pin 사용
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        $tag = (Invoke-RestMethod -Uri 'https://api.github.com/repos/helm/helm/releases/latest' `
                                  -Headers @{ 'User-Agent' = 'lab-bootstrap' } -TimeoutSec 30).tag_name
        if ($tag) { $ver = $tag.TrimStart('v') }
    } catch { Write-Warn "Helm 최신 버전 조회 실패 → pin($HelmPinned) 사용" }
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
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        $c = Invoke-RestMethod -Uri 'https://checkpoint-api.hashicorp.com/v1/check/terraform' `
                               -Headers @{ 'User-Agent' = 'lab-bootstrap' } -TimeoutSec 30
        if ($c.current_version) { $ver = $c.current_version }
    } catch { Write-Warn "Terraform 최신 버전 조회 실패 → pin($TerraformPinned) 사용" }
    $zip = Join-Path $env:TEMP "terraform-$ver.zip"
    Get-Download "https://releases.hashicorp.com/terraform/$ver/terraform_${ver}_windows_amd64.zip" $zip
    Expand-ToInstallDir -Zip $zip -ExeName 'terraform.exe'
    Remove-Item $zip -Force -ErrorAction SilentlyContinue
    Add-SystemPath $InstallDir
}

function Fallback-VSCode {
    $exe = Join-Path $env:TEMP 'VSCodeSetup.exe'
    Get-Download 'https://update.code.visualstudio.com/latest/win32-x64/stable' $exe
    # Inno Setup 무인 설치 + PATH 등록(addtopath)
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
    # 릴리스 자산명에 버전이 박혀 있어 stable URL 이 없음 → API 로 64-bit 무인 설치 파일 조회
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $rel = Invoke-RestMethod -Uri 'https://api.github.com/repos/git-for-windows/git/releases/latest' `
                             -Headers @{ 'User-Agent' = 'lab-bootstrap' } -TimeoutSec 30
    $asset = $rel.assets | Where-Object { $_.name -like 'Git-*-64-bit.exe' } | Select-Object -First 1
    if (-not $asset) { throw 'Git for Windows 설치 파일을 찾을 수 없습니다.' }
    $exe = Join-Path $env:TEMP $asset.name
    Get-Download $asset.browser_download_url $exe
    # Inno Setup 무인 설치 (설치 후 PATH 는 installer 가 등록)
    Start-Process $exe -ArgumentList '/VERYSILENT','/NORESTART','/NOCANCEL','/SP-' -Wait
    Remove-Item $exe -Force -ErrorAction SilentlyContinue
}

function Fallback-GitLfs {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $rel = Invoke-RestMethod -Uri 'https://api.github.com/repos/git-lfs/git-lfs/releases/latest' `
                             -Headers @{ 'User-Agent' = 'lab-bootstrap' } -TimeoutSec 30
    $asset = $rel.assets | Where-Object { $_.name -like 'git-lfs-windows-amd64-*.zip' } | Select-Object -First 1
    if (-not $asset) { throw 'git-lfs zip 을 찾을 수 없습니다.' }
    $zip = Join-Path $env:TEMP 'git-lfs.zip'
    Get-Download $asset.browser_download_url $zip
    Expand-ToInstallDir -Zip $zip -ExeName 'git-lfs.exe'
    Remove-Item $zip -Force -ErrorAction SilentlyContinue
    Add-SystemPath $InstallDir
}

function Fallback-Pwsh {
    # 릴리스 자산명에 버전이 박혀 있어 stable URL 이 없음 → API 로 x64 MSI 조회
    # releases/latest 는 prerelease 를 제외하므로 RC 를 집을 일이 없다.
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $rel = Invoke-RestMethod -Uri 'https://api.github.com/repos/PowerShell/PowerShell/releases/latest' `
                             -Headers @{ 'User-Agent' = 'lab-bootstrap' } -TimeoutSec 30
    $asset = $rel.assets | Where-Object { $_.name -like 'PowerShell-*-win-x64.msi' } | Select-Object -First 1
    if (-not $asset) { throw 'PowerShell 7 MSI 를 찾을 수 없습니다.' }
    $msi = Join-Path $env:TEMP $asset.name
    Get-Download $asset.browser_download_url $msi
    # 무인 설치 (PATH 등록은 MSI 가 함 — ADD_PATH 기본값 1)
    Start-Process msiexec.exe -ArgumentList "/i `"$msi`" /qn /norestart" -Wait
    Remove-Item $msi -Force -ErrorAction SilentlyContinue
}

# ===========================================================================
# kubectl 전용 설치 — dl.k8s.io 차단 우회 (Amazon EKS S3 미러 + SHA256 검증)
# winget/choco 를 쓰지 않는 이유: 그 패키지들도 결국 차단된 dl.k8s.io 에서 받기 때문.
# ===========================================================================
function Install-Kubectl {
    Write-Step "kubectl (EKS S3 미러 사용 — dl.k8s.io 차단 우회)"

    if (-not $Force -and (Test-Tool 'kubectl')) { Write-Skip "이미 설치됨 (kubectl)"; return $true }

    if (-not $KubectlMap.ContainsKey($KubectlMinor)) {
        Write-Err "지원하지 않는 kubectl 버전: $KubectlMinor (지원: $($KubectlMap.Keys -join ', '))"
        return $false
    }
    $info = $KubectlMap[$KubectlMinor]
    $base = "https://s3.us-west-2.amazonaws.com/amazon-eks/$($info.v)/$($info.d)/bin/windows/amd64"

    try {
        $exe    = Join-Path $env:TEMP 'kubectl.exe'
        $shaTxt = Join-Path $env:TEMP 'kubectl.exe.sha256'
        Write-Host "    다운로드: $base/kubectl.exe"
        Get-Download "$base/kubectl.exe"        $exe
        Get-Download "$base/kubectl.exe.sha256" $shaTxt

        # SHA256 무결성 검증
        $expected = (Get-Content $shaTxt -Raw).Trim().Split()[0].ToLower()
        $actual   = (Get-FileHash $exe -Algorithm SHA256).Hash.ToLower()
        if ($expected -ne $actual) {
            Write-Err "kubectl SHA256 불일치! (expected=$expected actual=$actual)"
            Remove-Item $exe, $shaTxt -Force -ErrorAction SilentlyContinue
            return $false
        }
        Write-Ok "SHA256 검증 통과"

        if (-not (Test-Path $InstallDir)) { New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null }
        Copy-Item $exe (Join-Path $InstallDir 'kubectl.exe') -Force
        Remove-Item $exe, $shaTxt -Force -ErrorAction SilentlyContinue
        Add-SystemPath $InstallDir

        if (Test-Tool 'kubectl') { Write-Ok "kubectl $($info.v) 설치 완료"; return $true }
        Write-Err "kubectl 설치 후에도 명령을 찾을 수 없습니다."
        return $false
    } catch {
        Write-Err "kubectl 설치 실패: $($_.Exception.Message)"
        Write-Warn "S3(amazon-eks) 엔드포인트도 차단되었는지 네트워크를 확인하세요."
        return $false
    }
}

# ===========================================================================
# ssh-agent 서비스 활성화 — 시작 유형을 Automatic 으로 설정하고 즉시 시작
# (Windows 10/11 에 기본 포함된 OpenSSH Client 의 ssh-agent 서비스를 사용)
# 재부팅되는 실습 PC 를 가정 → 로그인 시 자동으로 켜지도록 Automatic 지정.
# ===========================================================================
function Enable-SshAgent {
    Write-Step "ssh-agent 서비스 활성화"

    $svc = Get-Service -Name 'ssh-agent' -ErrorAction SilentlyContinue
    if (-not $svc) {
        Write-Warn "ssh-agent 서비스를 찾을 수 없습니다. OpenSSH Client 기능이 설치돼 있는지 확인하세요."
        Write-Warn "설치: 설정 > 앱 > 선택적 기능 > 'OpenSSH 클라이언트' 추가 (또는 Add-WindowsCapability)"
        return $false
    }

    try {
        # 시작 유형을 자동으로 (재부팅 후에도 자동 실행). 일부 환경은 Disabled 라 먼저 풀어줘야 함.
        Set-Service -Name 'ssh-agent' -StartupType Automatic -ErrorAction Stop
        Write-Ok "시작 유형 = Automatic"

        $svc = Get-Service -Name 'ssh-agent'
        if ($svc.Status -ne 'Running') {
            Start-Service -Name 'ssh-agent' -ErrorAction Stop
            Write-Ok "ssh-agent 서비스 시작됨"
        } else {
            Write-Skip "이미 실행 중"
        }
        return $true
    } catch {
        Write-Err "ssh-agent 서비스 설정 실패: $($_.Exception.Message)"
        return $false
    }
}

# ===========================================================================
# 최종 검증: 각 도구 버전 실행 → OK/FAIL 요약
# ===========================================================================
function Invoke-Verification {
    Write-Step "설치 검증"
    Sync-Path
    $checks = @(
        @{ Name = 'PowerShell 7';   Cmd = 'pwsh';                   Args = @('--version') }
        @{ Name = 'Git';            Cmd = 'git';                    Args = @('--version') }
        @{ Name = 'Git LFS';        Cmd = 'git-lfs';                Args = @('version') }
        @{ Name = 'AWS CLI';        Cmd = 'aws';                    Args = @('--version') }
        @{ Name = 'SSM plugin';     Cmd = 'session-manager-plugin'; Args = @('--version') }
        @{ Name = 'Helm';           Cmd = 'helm';                   Args = @('version','--short') }
        @{ Name = 'eksctl';         Cmd = 'eksctl';                 Args = @('version') }
        @{ Name = 'kubectl';        Cmd = 'kubectl';                Args = @('version','--client') }
        @{ Name = 'Terraform';      Cmd = 'terraform';              Args = @('version') }
        @{ Name = 'VS Code';        Cmd = 'code';                   Args = @('--version') }
        @{ Name = 'k9s';            Cmd = 'k9s';                    Args = @('version','-s') }
    )
    $fails = @()
    foreach ($c in $checks) {
        $cmdObj = Get-Command $c.Cmd -ErrorAction SilentlyContinue
        if (-not $cmdObj) {
            Write-Err ("{0,-12} 미설치 / PATH 없음 ({1})" -f $c.Name, $c.Cmd)
            $fails += $c.Name
            continue
        }
        try {
            $out = (& $c.Cmd @($c.Args) 2>&1 | Select-Object -First 1) -join ' '
            Write-Ok ("{0,-12} {1}" -f $c.Name, $out)
        } catch {
            Write-Err ("{0,-12} 버전 확인 실패" -f $c.Name)
            $fails += $c.Name
        }
    }

    # ssh-agent 서비스 상태 요약
    $ssh = Get-Service -Name 'ssh-agent' -ErrorAction SilentlyContinue
    if ($ssh) {
        Write-Ok ("{0,-12} {1} (StartType={2})" -f 'ssh-agent', $ssh.Status, $ssh.StartType)
    } else {
        Write-Err ("{0,-12} 서비스 없음 (OpenSSH Client 미설치)" -f 'ssh-agent')
    }

    Write-Host ""
    if ($fails.Count -eq 0) {
        Write-Host "모든 도구가 정상 설치되었습니다. ✅" -ForegroundColor Green
    } else {
        Write-Host ("실패한 도구: {0}" -f ($fails -join ', ')) -ForegroundColor Red
    }
    Write-Host "새 터미널을 열면 PATH 가 완전히 반영됩니다." -ForegroundColor DarkGray
}

# ===========================================================================
# 메인
# ===========================================================================
Assert-Admin

$logDir = Join-Path $env:TEMP 'lab-bootstrap'
if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
$log = Join-Path $logDir ("bootstrap_{0}.log" -f (Get-Date -Format 'yyyyMMdd_HHmmss'))
Start-Transcript -Path $log -Force | Out-Null

Write-Host "=======================================================" -ForegroundColor Magenta
Write-Host " Cloud Lab Bootstrap" -ForegroundColor Magenta
Write-Host "  InstallDir : $InstallDir"
Write-Host "  kubectl    : $KubectlMinor (EKS S3 미러)"
Write-Host "  winget     : $([bool](Test-Winget))   (NoWinget=$NoWinget, Force=$Force)"
Write-Host "  log        : $log"
Write-Host "=======================================================" -ForegroundColor Magenta

if (-not (Test-Path $InstallDir)) { New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null }
Add-SystemPath $InstallDir

# 하나라도 실패하면 $ok 가 false 가 됨. (설치 호출은 항상 좌변에 둬 매번 실행되도록)
$ok = $true

# winget 우선 + 직접 다운로드 fallback 을 갖는 도구들
$ok = (Install-Tool -Name 'PowerShell 7' -Cmd 'pwsh'                   -WingetId 'Microsoft.PowerShell'        -Fallback ${function:Fallback-Pwsh})      -and $ok
$ok = (Install-Tool -Name 'Git'          -Cmd 'git'                    -WingetId 'Git.Git'                     -Fallback ${function:Fallback-Git})       -and $ok
$ok = (Install-Tool -Name 'Git LFS'      -Cmd 'git-lfs'                -WingetId 'GitHub.GitLFS'               -Fallback ${function:Fallback-GitLfs})    -and $ok
$ok = (Install-Tool -Name 'AWS CLI v2'   -Cmd 'aws'                    -WingetId 'Amazon.AWSCLI'               -Fallback ${function:Fallback-AwsCli})    -and $ok
$ok = (Install-Tool -Name 'SSM plugin'   -Cmd 'session-manager-plugin' -WingetId 'Amazon.SessionManagerPlugin' -Fallback ${function:Fallback-Ssm})       -and $ok
$ok = (Install-Tool -Name 'Helm'         -Cmd 'helm'                   -WingetId 'Helm.Helm'                   -Fallback ${function:Fallback-Helm})      -and $ok
$ok = (Install-Tool -Name 'eksctl'       -Cmd 'eksctl'                 -WingetId $null                         -Fallback ${function:Fallback-Eksctl})    -and $ok
$ok = (Install-Tool -Name 'Terraform'    -Cmd 'terraform'              -WingetId 'Hashicorp.Terraform'         -Fallback ${function:Fallback-Terraform}) -and $ok
$ok = (Install-Tool -Name 'VS Code'      -Cmd 'code'                   -WingetId 'Microsoft.VisualStudioCode'  -Fallback ${function:Fallback-VSCode})    -and $ok
$ok = (Install-Tool -Name 'k9s'          -Cmd 'k9s'                    -WingetId 'Derailed.k9s'                -Fallback ${function:Fallback-K9s})       -and $ok

# git-lfs 는 설치만으로는 git 에 훅되지 않음 → 시스템 전역으로 등록 (idempotent)
if ((Test-Tool 'git') -and (Test-Tool 'git-lfs')) {
    try { git lfs install --system 2>&1 | Out-Null; Write-Ok "git lfs install --system 완료" }
    catch { Write-Warn "git lfs install 실패: $($_.Exception.Message)" }
}

# kubectl 은 항상 EKS S3 직접 (차단 우회)
$ok = (Install-Kubectl) -and $ok

# ssh-agent 서비스 자동 시작 설정 (도구 설치와 별개의 시스템 구성)
$ok = (Enable-SshAgent) -and $ok

Invoke-Verification

Stop-Transcript | Out-Null

# 하나라도 실패하면 비정상 종료코드
if ($ok) { exit 0 } else { exit 1 }
