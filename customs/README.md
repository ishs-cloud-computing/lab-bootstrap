# customs — 커스텀 부트스트랩

코어 `bootstrap.ps1` 은 모두가 공유하는 도구 설치만 담당한다.
그 위에 얹는 개인·과목·실습실별 설정은 이 디렉터리에 **파일 하나**로 넣는다.

```powershell
& ([scriptblock]::Create((irm https://wsc.zenru.net/bootstrap.ps1))) -Custom zenru
& ([scriptblock]::Create((irm https://wsc.zenru.net/bootstrap.ps1))) -Custom zenru,netlab
```

브랜치로 나누지 않는 이유: 브랜치마다 500줄 스크립트 사본이 생기고, 학기마다 하는 버전 pin 갱신을
브랜치 수만큼 merge 해야 하며, 커스텀끼리 조합할 수 없다. 파일로 두면 코어 수정이 전부에 자동 반영된다.

## 현재 있는 커스텀

| 이름 | 내용 | 문서 |
|---|---|---|
| `zenru` | 별칭 `g`/`k`/`tf` + 탭 자동완성 | [zenru.md](zenru.md) |

---

## 만드는 법

`customs/<이름>.ps1` 파일 하나를 추가한다. 이름은 소문자·숫자·하이픈만 쓴다
(`^[a-z0-9][a-z0-9-]*$` — 코어가 검사한다).

```powershell
# SPDX-License-Identifier: BSD-3-Clause
# Copyright 2026 The ISHS Cloud Computing Authors
#
# Custom: mylab - 한 줄 설명

Install-Tool -Name 'jq' -Cmd 'jq' -WingetId 'jqlang.jq' -Fallback {
    Get-Download 'https://github.com/jqlang/jq/releases/latest/download/jq-windows-amd64.exe' `
                 (Join-Path $InstallDir 'jq.exe')
    Add-SystemPath $InstallDir
}

Set-Content -Path (Join-Path $ProfileD 'mylab-aliases.ps1') -Encoding UTF8 -Value @'
Set-Alias -Name tg -Value terragrunt
'@
Write-Ok "aliases"
```

동작 방식:

- 커스텀은 **모든 도구 설치가 끝난 뒤** dot-source 된다. 무엇이 설치됐는지 보고 판단해도 된다.
- 코어의 함수와 변수를 그대로 쓸 수 있다 (아래 표).
- 예외를 던져도 부트스트랩 전체는 계속된다. 해당 커스텀만 `[FAIL]` 로 기록된다.
- `-Custom a,b` 로 여러 개를 지정하면 **적은 순서대로** 실행된다.

### 쓸 수 있는 것

| 종류 | 이름 |
|---|---|
| 로그 | `Write-Step` `Write-Ok` `Write-Skip` `Write-Warn` `Write-Err` |
| 설치 | `Install-Tool` `Get-Download` `Expand-ToInstallDir` `Get-LatestOrPinned` |
| 환경 | `Add-SystemPath` `Sync-Path` `Test-Tool` |
| 셸 | `Write-ToolCompletion` |
| 변수 | `$InstallDir` `$ToolsRoot` `$ProfileD` `$Force` `$NoWinget` `$BaseUrl` |

`Write-ToolCompletion -Cmd 'helm' -Alias 'h'` 는 그 도구의 `completion powershell` 출력을
`$ProfileD` 에 캐시하고, 별칭에도 같은 completer 를 등록해준다 (cobra 기반 도구에 한함).

### 셸 설정을 넣는 방법

프로필을 직접 건드리지 말고 **`$ProfileD` 에 `.ps1` 파일을 떨군다.**
코어가 pwsh 7 공용 프로필에 `profile.d` 로더를 이미 설치해 뒀다.

- 파일 이름은 **`<커스텀이름>-` 접두사**를 붙인다. 다른 커스텀과 충돌하지 않게 하는 유일한 규칙이다.
  (`Write-ToolCompletion` 이 만드는 `kubectl.ps1` 등은 도구 이름 그대로이고, 내용이 같으므로 겹쳐도 무해하다.)
- `$ProfileD` 는 **실행마다 비워진다.** 지정한 커스텀만 활성이라는 규칙이고, 뺀 커스텀의 잔재가 남지 않는다.

### 하지 말 것

- 코어 `bootstrap.ps1` 수정 — 커스텀 하나 때문에 고쳐야 한다면 설계가 잘못된 것이니 이슈로 먼저 논의한다.
- 공용 프로필(`$PROFILE.AllUsersAllHosts`) 직접 편집 — `$ProfileD` 를 쓴다.
- 다른 커스텀이 만든 파일 수정·삭제.
- `exit` 호출 — 부트스트랩 전체가 죽는다. 실패는 `throw` 하면 코어가 잡는다.

---

## 리뷰 규칙

**커스텀은 관리자(Administrator) 권한으로 실행된다.** 코어는 커스텀을 샌드박싱하지 않는다
(PowerShell 에서 현실적으로 불가능하다). 따라서 **PR 리뷰가 유일한 통제선**이다.

그래서 `-Custom` 은 **이름만** 받고 URL 이나 경로는 받지 않는다. 저장소에 들어오지 않은 코드는
실행될 방법이 없고, 저장소에 들어오려면 리뷰를 거쳐야 한다.

PR 을 올릴 때:

- 커스텀이 하는 일을 한 문단으로 설명한다.
- 아래에 해당하면 **왜 필요한지 PR 본문에 적는다.**
  - 저장소 밖 URL 에서 무언가를 내려받는다
  - 레지스트리에 쓴다 / 서비스를 바꾼다 / 방화벽·정책을 건드린다
  - 자격증명·토큰을 다룬다
- 난독화된 코드(base64 블롭, 인코딩된 명령)는 받지 않는다.
- 사용자 문서 `customs/<이름>.md` 를 같이 넣고, 위 "현재 있는 커스텀" 표에 한 줄 추가한다.

리뷰어는 `customs/` 에 대해 CODEOWNERS 로 지정돼 있다.
