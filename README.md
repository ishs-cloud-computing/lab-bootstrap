# lab-bootstrap

학교 실습실 Windows PC에 **클라우드 컴퓨팅 실습용 도구**를 한 번에 자동 설치하는 PowerShell 부트스트랩 스크립트.

설치 대상:

| 도구 | 용도 |
|---|---|
| **AWS CLI v2** | AWS 명령행 도구 |
| **SSM 플러그인** | Session Manager 로 인스턴스 접속 (`aws ssm start-session`) |
| **Helm** | Kubernetes 패키지 매니저 |
| **eksctl** | Amazon EKS 클러스터 생성/관리 CLI |
| **kubectl** | Kubernetes 명령행 도구 |
| **Terraform** | IaC (인프라 코드) |
| **VS Code** | 코드 편집기 |
| **k9s** | Kubernetes 터미널 UI |

여기까지가 모두가 공유하는 기본 설치다. 별칭·자동완성 같은 셸 설정은
[`.bootrc`](https://github.com/ishs-cloud-computing/lab-bootstrap/wiki/Shell-Configuration) 파일 하나로 얹는다.

## 시작하기

### 요구 사항

- [PowerShell 7](https://github.com/PowerShell/PowerShell/releases/latest)
- [Git](https://git-scm.com/)

```powershell
# PowerShell 7 설치
winget install --id Microsoft.PowerShell -e --source winget --accept-package-agreements --accept-source-agreements

# Git 설치
winget install --id Git.Git -e --source winget --accept-package-agreements --accept-source-agreements
```

### 설치

```powershell
git clone https://github.com/ishs-cloud-computing/lab-bootstrap.git
cd lab-bootstrap
pwsh -ExecutionPolicy Bypass -File .\bootstrap.ps1

# 인자를 포함하여 실행
pwsh -ExecutionPolicy Bypass -File .\bootstrap.ps1 -KubectlMinor 1.31
```


#### GitLab 미러를 통해 설치

```powershell
git clone https://gitlab.com/ishs-cloud/lab-bootstrap.git
cd lab-bootstrap
pwsh -ExecutionPolicy Bypass -File .\bootstrap.ps1
```

> 설치 직후에는 새 터미널을 하나 열어야 PATH 와 셸 설정이 반영된다.

같은 명령을 다시 실행하면 최신화된다. 이미 깔린 도구는 버전을 확인해서 뒤처진 것만 올리고,
최신이면 `[SKIP] up to date` 로 넘어간다. 전부 다시 받으려면 `-Force` 를 준다.

ZIP 다운로드, 설치 확인 방법은 [Getting Started](https://github.com/ishs-cloud-computing/lab-bootstrap/wiki/Getting-Started) 를 본다.

## 문서

자세한 내용은 [Wiki](https://github.com/ishs-cloud-computing/lab-bootstrap/wiki) 에 있다.

| 페이지 | 내용 |
|---|---|
| [Getting Started](https://github.com/ishs-cloud-computing/lab-bootstrap/wiki/Getting-Started) | 요구 사항, 설치, 설치 확인 |
| [Parameters](https://github.com/ishs-cloud-computing/lab-bootstrap/wiki/Parameters) | `bootstrap.ps1` 파라미터 레퍼런스 |
| [Shell Configuration](https://github.com/ishs-cloud-computing/lab-bootstrap/wiki/Shell-Configuration) | `.bootrc`, 프로필 마커 블록, 탭 자동완성 |
| [How It Works](https://github.com/ishs-cloud-computing/lab-bootstrap/wiki/How-It-Works) | 파일 구조, kubectl 을 따로 받는 이유, 동작 특성 |
| [Maintenance](https://github.com/ishs-cloud-computing/lab-bootstrap/wiki/Maintenance) | kubectl 버전 표와 버전 pin 갱신 |
| [Troubleshooting](https://github.com/ishs-cloud-computing/lab-bootstrap/wiki/Troubleshooting) | 증상별 해결 |
| [Uninstall](https://github.com/ishs-cloud-computing/lab-bootstrap/wiki/Uninstall) | PC 에 남는 것 전부와 되돌리는 방법 |

## Maintainer

- 성준혁 ([@jhyeok1023](https://github.com/jhyeok1023))

## License

This project is licensed under the [BSD 3-Clause License](LICENSE).
