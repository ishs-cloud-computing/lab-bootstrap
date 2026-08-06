# 전체 제거

lab-bootstrap 이 PC 에 남기는 것 전부와, 그걸 되돌리는 방법.

재부팅으로 초기화되는 실습실 PC 라면 아무것도 할 필요가 없다. 아래는 **초기화되지 않는 PC**
(개인 노트북, 관리자용 PC)에서 손으로 걷어낼 때의 절차다.

관리자 권한 `pwsh` 에서 실행한다.

---

## 남는 것 한눈에

| 위치 | 내용 | 만든 주체 |
|---|---|---|
| pwsh 프로필의 마커 블록 | `.bootrc` 내용 + 완성 스크립트 로더 | bootstrap |
| `C:\cloud-tools\bin` | 직접 다운로드한 portable 바이너리 | bootstrap |
| `C:\cloud-tools\completion` | 구워진 탭 자동완성 스크립트 | bootstrap |
| 시스템 PATH | `C:\cloud-tools\bin` 항목 1개 | bootstrap |
| `ssh-agent` 서비스 | 시작 유형 `Automatic` | bootstrap |
| `%TEMP%\lab-bootstrap\` | 실행 로그와 프로필 백업(`.bak`) | bootstrap |
| Git, AWS CLI, VS Code 등 | 각자의 설치 관리자로 설치됨 | winget 또는 각 벤더 설치 관리자 |

`-InstallDir` 을 바꿔 설치했다면 `C:\cloud-tools` 대신 **그 폴더의 상위**를 보면 된다
(예: `-InstallDir D:\tools\bin` → `D:\tools\`).

---

## 1. 프로필에서 마커 블록 지우기

가장 중요한 단계다. 이걸 안 지우면 새 터미널마다 없는 폴더를 찾는다 (조용히 실패하긴 한다).

어디에 걸렸는지부터 확인한다:

```powershell
$PROFILE.AllUsersAllHosts, $PROFILE.CurrentUserAllHosts |
    Where-Object { Test-Path $_ } |
    Select-String 'lab-bootstrap begin' |
    Select-Object -ExpandProperty Path
```

나온 파일에서 `# >>> lab-bootstrap begin >>>` 부터 `# <<< lab-bootstrap end <<<` 까지
**두 마커 줄을 포함해** 지운다. 마커 바깥은 여러분이 쓴 것이므로 건드리지 않는다.

손으로 지워도 되고, 아래로 한 번에 지워도 된다:

```powershell
# 블록과 그 앞뒤 빈 줄을 함께 걷어내고, 빈 줄 하나만 남긴다.
$pattern = '(?s)(\r?\n)*# >>> lab-bootstrap begin >>>.*?# <<< lab-bootstrap end <<<[ \t]*(\r?\n)?'
foreach ($p in @($PROFILE.AllUsersAllHosts, $PROFILE.CurrentUserAllHosts)) {
    if (-not (Test-Path $p)) { continue }
    $t = Get-Content -LiteralPath $p -Raw
    $n = [regex]::Replace($t, $pattern, "`r`n").TrimStart("`r", "`n")
    if ($n -ne $t) { Set-Content -LiteralPath $p -Value $n -NoNewline; "cleaned $p" }
}
```

> 실행 전 백업이 이미 `%TEMP%\lab-bootstrap\profile_*.bak` 에 있다. bootstrap 은 프로필을
> 고치기 전에 항상 한 부 떠 둔다.

## 2. 도구 폴더 삭제

```powershell
Remove-Item C:\cloud-tools -Recurse -Force
```

`bin`, `completion`, 그리고 예전 버전이 만들었을 수 있는 `profile.d` 까지 한 번에 사라진다.

## 3. 시스템 PATH 에서 제거

```powershell
$key = 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Environment'
$cur = (Get-Item $key).GetValue('Path', '', 'DoNotExpandEnvironmentNames')
$new = ($cur -split ';' | Where-Object { $_ -and $_ -ne 'C:\cloud-tools\bin' }) -join ';'
Set-ItemProperty -Path $key -Name 'Path' -Value $new -Type ExpandString
```

읽을 때 `DoNotExpandEnvironmentNames` 를 쓰는 이유는, 그냥 읽으면 `%SystemRoot%` 같은 항목이
펼쳐진 채로 다시 쓰여 `REG_EXPAND_SZ` 가 `REG_SZ` 로 떨어지기 때문이다. 다른 프로그램의 PATH
항목까지 망가뜨리지 않으려면 이 형태로 다룬다.

반영은 새 터미널부터다.

## 4. ssh-agent 되돌리기

Windows 기본값은 `Disabled` 다. 다른 용도로 쓰고 있지 않다면:

```powershell
Stop-Service ssh-agent -ErrorAction SilentlyContinue
Set-Service  ssh-agent -StartupType Disabled
```

## 5. 설치된 도구 제거

bootstrap 은 도구를 **직접 설치하지 않고** winget 이나 각 벤더의 설치 관리자에 맡긴다.
그래서 제거도 그쪽 방식으로 한다.

```powershell
# winget 으로 깔린 것
winget uninstall --id Git.Git -e
winget uninstall --id GitHub.GitLFS -e
winget uninstall --id Amazon.AWSCLI -e
winget uninstall --id Amazon.SessionManagerPlugin -e
winget uninstall --id Helm.Helm -e
winget uninstall --id Hashicorp.Terraform -e
winget uninstall --id Microsoft.VisualStudioCode -e
winget uninstall --id Derailed.k9s -e
```

winget 이 없는 PC 였다면 같은 도구들이 직접 다운로드로 깔렸을 수 있다:

- **Git / VS Code**: 설정 > 앱 > 설치된 앱에서 제거
- **AWS CLI v2 / SSM 플러그인**: 같은 곳에서 제거 (MSI/EXE 설치 관리자)
- **Helm / eksctl / Terraform / k9s / git-lfs / kubectl**: 2단계에서 폴더를 지웠으면 이미 없다
  (`C:\cloud-tools\bin` 에 들어 있는 단일 실행 파일들이다)

**eksctl 과 kubectl 은 winget 을 쓰지 않는다.** 각각 GitHub 릴리스와 EKS S3 미러에서 받아
`C:\cloud-tools\bin` 에 두므로 2단계로 끝난다.

`git lfs install --system` 으로 등록한 훅도 되돌리려면 Git 을 지우기 **전에**:

```powershell
git lfs uninstall --system
```

## 6. 로그와 백업 삭제

```powershell
Remove-Item "$env:TEMP\lab-bootstrap" -Recurse -Force
```

1단계에서 뜬 프로필 백업도 여기 들어 있다. **프로필을 되돌릴 일이 없다고 확신한 뒤에** 지운다.

---

## 셸 설정만 끄고 싶다면

전부 제거할 필요 없다. `.bootrc` 가 없는 폴더에서 bootstrap 을 한 번 돌리면 셸 설정 단계가
통째로 건너뛰어진다 — 다만 **이미 박힌 블록은 남는다.** 블록만 없애려면 1단계만 하면 된다.

반대로 내용만 바꾸고 싶으면 `.bootrc` 를 고치고 bootstrap 을 다시 돌린다. 블록 안쪽만 갈린다.
