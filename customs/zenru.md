# 커스텀 `zenru` — 셸 통합 (별칭 + 자동완성)

도구 설치가 끝난 뒤 PowerShell 7 프로필에 **명령 별칭**과 **탭 자동완성**을 등록하는 커스텀이다.
실습마다 `kubectl` / `terraform` 을 통째로 타이핑하고 서브커맨드를 외우는 부담을 줄이기 위한 것이다.

기본 부트스트랩에는 포함되지 않는다. **`-Custom zenru` 를 붙여야 적용된다.**

```powershell
& ([scriptblock]::Create((irm https://wsc.zenru.net/bootstrap.ps1))) -Custom zenru

# 로컬 스크립트
pwsh -ExecutionPolicy Bypass -File .\bootstrap.ps1 -Custom zenru
```

> **새 터미널부터 적용된다.** 그리고 **PowerShell 7(`pwsh`) 전용**이다.

---

## 별칭

| 별칭 | 원래 명령 |
|---|---|
| `g` | `git` |
| `k` | `kubectl` |
| `tf` | `terraform` |

```powershell
k get pods
tf plan
g status
```

## 자동완성

| 도구 | 완성 방식 | 별칭에서도 동작 |
|---|---|---|
| **kubectl** | `kubectl completion powershell` (도구 자체 생성) | `k` ✅ |
| **terraform** | 서브커맨드 정적 목록 (스크립트 내장) | `tf` ✅ |
| **helm** | `helm completion powershell` | — |
| **eksctl** | `eksctl completion powershell` | — |
| **k9s** | `k9s completion powershell` | — |
| **git** | 없음 — 별칭 `g` 만 제공 | — |
| **aws**, **session-manager-plugin** | 없음 (PowerShell 완성 생성기 미제공) | — |

```powershell
k get po<TAB>        # → pods
k rollo<TAB>         # → rollout
tf ap<TAB>           # → apply
helm in<TAB>         # → install
```

kubectl 은 클러스터에 연결돼 있으면 **리소스 이름까지** 완성한다 (`k get pod <TAB>`).
terraform 은 서브커맨드 이름만 완성한다 — HashiCorp 가 제공하는 `terraform -install-autocomplete`
는 bash/zsh 전용이라 PowerShell 에서 쓸 수 없어 직접 넣은 목록이기 때문이다.

git 자동완성은 **의도적으로 넣지 않았다.** PowerShell 에서 제대로 하려면 PSGallery 의 `posh-git`
모듈이 필요한데, 실습실 네트워크에 의존성을 하나 더 만들 이유가 없다고 판단했다.

---

## 생성되는 파일

모두 코어가 만드는 `profile.d` 디렉터리 안에 들어간다.

```
C:\cloud-tools\profile.d\zenru-aliases.ps1     별칭 g / k / tf
                        \zenru-terraform.ps1   terraform 서브커맨드 completer
                        \kubectl.ps1           도구 자체 생성 완성 스크립트
                        \helm.ps1  \eksctl.ps1  \k9s.ps1
C:\Program Files\PowerShell\7\profile.ps1      profile.d 를 로드하는 2줄 (코어가 설치)
```

`zenru-` 접두사는 이 커스텀이 소유한 파일이라는 표시다. 다른 커스텀과 같이 써도 서로 덮어쓰지 않는다.

`profile.d` 는 bootstrap 실행마다 **비워지고 다시 채워진다.** 즉 `-Custom zenru` 없이 실행하면
별칭도 자동완성도 사라진다 — 지정한 커스텀만 활성이라는 규칙 하나로 통일돼 있다.

`-InstallDir` 을 바꿔서 실행하면 그 상위 폴더 기준으로 경로가 따라간다
(예: `-InstallDir D:\tools\bin` → `D:\tools\profile.d\`).

### 왜 완성 스크립트를 파일로 굽나

`kubectl completion powershell` 같은 생성기는 실행에 도구당 100~300ms 가 든다.
프로필에서 매번 돌리면 **새 터미널을 열 때마다** 그만큼 멈춘다.
그래서 설치할 때 한 번만 생성해 파일로 저장하고, 프로필은 dot-source 만 한다.

대신 **도구를 업그레이드하면 bootstrap 을 다시 실행**해야 완성 목록이 새 버전 기준으로 갱신된다.

---

## 끄기 / 되돌리기

`-Custom zenru` 없이 bootstrap 을 한 번 더 실행하면 된다 (`profile.d` 가 비워진다).

셸 통합 자체를 완전히 걷어내려면:

```powershell
# 1. 공용 프로필에서 '# lab-bootstrap' 과 그 아래 Get-ChildItem 줄을 지운다
notepad "C:\Program Files\PowerShell\7\profile.ps1"

# 2. 생성물 삭제
Remove-Item C:\cloud-tools\profile.d -Recurse -Force
```

---

## 문제 해결

**Q. `k` / `tf` 명령을 못 찾는다.**
- **`-Custom zenru`** 를 붙여서 실행했는지 확인한다. 안 붙이면 이 커스텀은 돌지 않는다.
- **새 터미널**을 열었는지 확인한다. 이미 열려 있던 창에는 반영되지 않는다.
- `powershell` (Windows PowerShell 5.1) 이 아니라 **`pwsh`** 로 열었는지 확인한다.
- `Test-Path 'C:\cloud-tools\profile.d\zenru-aliases.ps1'` 이 `False` 면 커스텀이 실패한 것이다.
  로그(`%TEMP%\lab-bootstrap\bootstrap_*.log`)에서 `custom: zenru` 블록을 확인한다.

**Q. 별칭은 되는데 `<TAB>` 이 안 먹는다.**
`Get-ChildItem C:\cloud-tools\profile.d` 로 해당 도구의 `.ps1` 이 있는지 본다.
없으면 로그에서 `[WARN] <도구> completion skipped` 를 찾는다.
그 도구가 PowerShell 완성 생성기를 지원하지 않는 버전일 수 있다 — 별칭 자체는 그대로 동작한다.

**Q. `<TAB>` 을 누르면 `Completion ended with directive: ...` 같은 줄이 뜬다.**
kubectl 이 완성 요청마다 stderr 에 찍는 메시지다. bootstrap 이 생성 시 이 출력을 죽이도록
완성 스크립트를 손봐두지만, 도구 버전이 바뀌어 패턴이 달라지면 다시 보일 수 있다.
동작에는 영향이 없고, `bootstrap.ps1` 의 `Write-ToolCompletion` 안 `-replace` 패턴을 갱신하면 된다.

**Q. 완성 후보가 옛날 버전 기준이다.**
도구를 업그레이드한 뒤 bootstrap 을 다시 실행한다 (`-Force` 는 필요 없다).

---

## 커스터마이즈

전부 [`customs/zenru.ps1`](zenru.ps1) 안에 있다 (코어 `bootstrap.ps1` 은 건드릴 필요 없다).

| 바꾸고 싶은 것 | 위치 |
|---|---|
| 별칭 이름 | `$zenruAliases` here-string 의 `Set-Alias` 3줄 |
| terraform 서브커맨드 목록 | `$zenruTerraform` here-string 의 `$tfCmds` |
| 완성을 생성할 도구 목록 | `Write-ToolCompletion` 호출들 |

별칭을 추가할 때, 그 도구가 cobra 기반(`<도구> completion powershell` 이 되는)이면
`Write-ToolCompletion -Cmd '<도구>' -Alias '<별칭>'` 로 넘기면 완성까지 같이 붙는다.

내 취향이 아니라 다른 조합이 필요하면, 이 파일을 고치는 대신
**새 커스텀을 만드는 편이 낫다** → [customs/README.md](README.md)
