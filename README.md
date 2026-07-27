# lab-bootstrap

학교 실습실 Windows PC에 **클라우드 컴퓨팅 실습용 도구**를 한 번에 자동 설치하는 PowerShell 부트스트랩 스크립트.

설치 대상:

| 도구 | 용도 |
|---|---|
| **Git** | 버전 관리 |
| **Git LFS** | Git 대용량 파일 저장소 |
| **AWS CLI v2** | AWS 명령행 도구 |
| **SSM 플러그인** | Session Manager 로 인스턴스 접속 (`aws ssm start-session`) |
| **Helm** | Kubernetes 패키지 매니저 |
| **eksctl** | Amazon EKS 클러스터 생성/관리 CLI |
| **kubectl** | Kubernetes 명령행 도구 |
| **Terraform** | IaC (인프라 코드) |
| **VS Code** | 코드 편집기 |
| **k9s** | Kubernetes 터미널 UI |

## Maintainer

- 성준혁 ([@zenru1023](https://github.com/zenru1023))

## 시작하기

### 요구 사항

- [PowerShell 7](https://github.com/PowerShell/PowerShell/releases/latest)

```powershell
# winget으로 설치
winget install --id Microsoft.PowerShell -e --source winget --accept-package-agreements --accept-source-agreements
```

### 설치

```powershell
# PowerShell 7에서 실행
irm https://wsc.zenru.net/bootstrap.ps1 | iex

# 또는 github 주소 사용
irm https://raw.githubusercontent.com/ishs-cloud-computing/lab-bootstrap/main/bootstrap.ps1 | iex
```

로컬 스크립트 실행:

```powershell
pwsh -ExecutionPolicy Bypass -File .\bootstrap.ps1

# 인자를 포함하여 실행
pwsh -ExecutionPolicy Bypass -File .\bootstrap.ps1 -KubectlMinor 1.31
```

> 설치 직후에는 새 터미널을 하나 열어야 PATH 가 완전히 반영된다.

## 왜 kubectl만 특별 취급하나?

kubectl 공식 배포 사이트(`dl.k8s.io` / `cdn.dl.k8s.io`)가 **학교 네트워크에서 차단**되어 있다.
winget·Chocolatey 의 kubectl 패키지도 결국 이 사이트에서 받으므로 똑같이 실패한다.

그래서 이 스크립트는 kubectl 만은 **Amazon EKS 가 S3 에 미러링한 동일 바이너리**를 받는다:

```
https://s3.us-west-2.amazonaws.com/amazon-eks/<버전>/<날짜>/bin/windows/amd64/kubectl.exe
```

- AWS 공식 문서 기준 *"binary is identical to the upstream community versions"* — 업스트림과 동일한 바이너리다.
- AWS 실습 환경이라 S3 엔드포인트는 방화벽에서 열려 있을 가능성이 높다.
- 받은 뒤 `kubectl.exe.sha256` 로 **SHA256 무결성 검증**까지 수행한다.

나머지 도구는 **winget 우선 설치 → 실패 시 공식 배포처에서 직접 다운로드** 로 fallback 한다.

---

## 파라미터

| 파라미터 | 기본값 | 설명 |
|---|---|---|
| `-KubectlMinor` | `1.36` | 설치할 kubectl 마이너 버전. **사용하는 EKS 클러스터 버전에 맞춰** 지정. (지원: 1.30 ~ 1.36) |
| `-InstallDir` | `C:\cloud-tools\bin` | 직접 다운로드한 portable 바이너리 배치 폴더 (시스템 PATH 에 자동 추가) |
| `-NoWinget` | (off) | winget 을 건너뛰고 **모든 도구를 직접 다운로드**로 설치 |
| `-Force` | (off) | 이미 설치돼 있어도 다시 설치 |

예시:

```powershell
# EKS 클러스터가 1.31 이면
pwsh -ExecutionPolicy Bypass -File .\bootstrap.ps1 -KubectlMinor 1.31

# winget 이 문제를 일으키면 전부 직접 다운로드로
pwsh -ExecutionPolicy Bypass -File .\bootstrap.ps1 -NoWinget
```

---

## 동작 특성

- **Idempotent**: 이미 설치된 도구는 건너뛴다. 재부팅으로 초기화되는 실습 PC 에서 매 세션 다시 돌려도 안전하고, 재실행이 빠르다.
- **로그**: 전체 실행 로그가 `%TEMP%\lab-bootstrap\bootstrap_<시각>.log` 에 저장된다.
- **PATH**: `-InstallDir` 을 시스템 PATH 에 1회만 추가한다.

---

## kubectl 버전 갱신

새 Kubernetes 마이너 버전이 나오면 `bootstrap.ps1` 상단의 `$KubectlMap` 표만 갱신하면 된다.
최신 전체버전/빌드날짜는 [AWS EKS: Install kubectl](https://docs.aws.amazon.com/eks/latest/userguide/install-kubectl.html) 문서에서 확인한다.

```powershell
$KubectlMap = @{
    "1.36" = @{ v = "1.36.2";  d = "2026-06-17" }
    "1.35" = @{ v = "1.35.3";  d = "2026-04-08" }
    ...
}
```

---

## 버전 pin 갱신

winget 없이 직접 다운로드할 때 스크립트는 각 도구의 최신 버전을 온라인으로 조회한다.
조회가 실패하면 `bootstrap.ps1` 상단의 **pin 값**을 쓴다.

```powershell
$HelmPinned      = "4.2.3"
$TerraformPinned = "1.15.8"
$GitLfsPinned    = "3.7.1"
$GitPinnedUrl    = 'https://github.com/git-for-windows/git/releases/download/v2.55.0.windows.3/Git-2.55.0.3-64-bit.exe'
```

이 pin 은 장식이 아니라 **실습실에서 실제로 자주 쓰인다**: 무인증 GitHub API 는 IP 당 시간당 60 요청이고
실습실 전체가 학교 NAT 주소 하나를 공유하므로, PC 20 대가 동시에 돌리면 쿼터가 소진되어 이후 전부
`403` 이 된다. 그때 pin 이 없으면 그 도구는 설치가 실패한다. 학기 시작 전에 한 번씩 갱신해두면 좋다.

(Git for Windows 는 태그와 파일명의 버전 표기가 달라서 — `v2.55.0.windows.3` vs `Git-2.55.0.3-64-bit.exe` —
버전 대신 URL 전체를 pin 한다.)

---

## 문제 해결 (FAQ)

**Q. `PowerShell 7+ is required` 오류가 난다.**
Windows 기본 셸(Windows PowerShell 5.1)로 실행한 것이다. `powershell` 이 아니라 **`pwsh`** 로 실행한다.
`pwsh` 명령 자체가 없으면 위 [선행 조건](#선행-조건-powershell-7) 섹션을 먼저 수행한다.

**Q. winget 이 설치돼 있지 않다.**
스크립트 자체는 winget 이 없어도 자동으로 직접 다운로드로 넘어간다.
다만 **선행 조건인 PowerShell 7 설치**가 먼저 막히므로, PowerShell 7 은 MSI 로 직접 설치하거나
Microsoft Store 에서 "앱 설치 관리자(App Installer)" 를 먼저 설치한다.

**Q. kubectl 설치에서 실패한다 (S3 도 막힌 경우).**
드물지만 S3(`amazon-eks`) 까지 차단됐다면, 인터넷 되는 곳에서 위 S3 URL 로 `kubectl.exe` 를 미리 받아
USB 등으로 옮긴 뒤 `-InstallDir`(`C:\cloud-tools\bin`) 에 복사하면 된다.

**Q. `code` / `session-manager-plugin` 명령을 못 찾는다.**
installer 가 PATH 를 등록한 직후라 현재 창에 반영되지 않았을 수 있다. **새 터미널**을 열어 다시 확인한다.

**Q. 실행이 스크립트 실행 정책 때문에 막힌다.**
`pwsh -ExecutionPolicy Bypass -File .\bootstrap.ps1` 로 실행한다 (위 예시 참고).

## License

This project is licensed under the [BSD 3-Clause License](LICENSE).