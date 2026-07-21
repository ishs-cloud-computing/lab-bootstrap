# lab-bootstrap

학교 실습실 Windows PC에 **클라우드 컴퓨팅 실습용 도구**를 한 번에 자동 설치하는 PowerShell 부트스트랩 스크립트.

설치 대상:

| 도구 | 용도 |
|---|---|
| **PowerShell 7** | 최신 PowerShell 셸 (`pwsh`) |
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

---

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

## 실행 방법

> 관리자 권한이 필요하다. 관리자가 아니면 스크립트가 UAC 창을 띄워 자동으로 승격한다.

### 1) 로컬 파일로 실행

```powershell
powershell -ExecutionPolicy Bypass -File .\bootstrap.ps1
```

### 2) 원라이너 (레포 raw URL, github.com 접근 가능 시)

```powershell
& ([scriptblock]::Create((irm https://raw.githubusercontent.com/ishs-cloud-computing/lab-bootstrap/main/bootstrap.ps1).TrimStart([char]0xFEFF)))
```

> `irm ... | iex` 는 `param()` 블록이 있는 스크립트에서 실패한다(`iex` 가 param 토큰을 처리 못 함).
> `.TrimStart([char]0xFEFF)` 는 `irm` 이 남기는 UTF-8 BOM 을 떼어낸다. 안 떼면 BOM 이 첫 구문으로 파싱돼
> `param()` 이 스크립트 첫 구문이 아니게 되고 `[CmdletBinding()]` 줄에서 파싱 에러가 난다.
> 파라미터를 넘기려면 뒤에 붙인다: `& ([scriptblock]::Create((irm <URL>).TrimStart([char]0xFEFF))) -KubectlMinor 1.31`

실행이 끝나면 모든 도구의 버전을 실행해 **OK / FAIL 요약 표**를 출력한다.
특히 `kubectl version --client` 결과가 `v1.32.x-eks-...` 처럼 `-eks-` 빌드 문자열이면 차단 우회 성공이다.

> 설치 직후에는 새 터미널을 하나 열어야 PATH 가 완전히 반영된다.

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
powershell -ExecutionPolicy Bypass -File .\bootstrap.ps1 -KubectlMinor 1.31

# winget 이 문제를 일으키면 전부 직접 다운로드로
powershell -ExecutionPolicy Bypass -File .\bootstrap.ps1 -NoWinget
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

## 문제 해결 (FAQ)

**Q. winget 이 설치돼 있지 않다.**
`-NoWinget` 없이 그냥 실행해도 winget 이 없으면 자동으로 직접 다운로드로 넘어간다.
winget 을 쓰고 싶으면 Microsoft Store 에서 "앱 설치 관리자(App Installer)" 를 설치한다.

**Q. kubectl 설치에서 실패한다 (S3 도 막힌 경우).**
드물지만 S3(`amazon-eks`) 까지 차단됐다면, 인터넷 되는 곳에서 위 S3 URL 로 `kubectl.exe` 를 미리 받아
USB 등으로 옮긴 뒤 `-InstallDir`(`C:\cloud-tools\bin`) 에 복사하면 된다.

**Q. `code` / `session-manager-plugin` 명령을 못 찾는다.**
installer 가 PATH 를 등록한 직후라 현재 창에 반영되지 않았을 수 있다. **새 터미널**을 열어 다시 확인한다.

**Q. 실행이 스크립트 실행 정책 때문에 막힌다.**
`-ExecutionPolicy Bypass` 를 붙여 실행한다 (위 예시 참고).

## License

This project is licensed under the [BSD 3-Clause License](LICENSE).