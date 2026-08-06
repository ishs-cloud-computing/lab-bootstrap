# lab-bootstrap lib 1
# SPDX-License-Identifier: BSD-3-Clause
# Copyright 2026 The ISHS Cloud Computing Authors
#
# Everything that touches the user's shell: baked completions, and splicing .bootrc into a
# pwsh profile between markers.
# Provided by the loader: $ToolsRoot $CompletionD $BlockBegin $BlockEnd $LogDir
# Definitions only - no top-level code, so load order never matters.

# ACL is not the whole story on MSIX packages, so probe by opening the file rather than reading
# permissions. Append creates the file when missing, which is fine: the first candidate that
# passes is the one we are about to write to anyway. A missing parent means reject, not create -
# we must not scatter empty directories while probing somewhere we will not use.
function Test-ProfileWritable {
    param([string]$Path)
    try {
        if (-not (Test-Path (Split-Path $Path -Parent))) { return $false }
        $fs = [System.IO.File]::Open($Path, [System.IO.FileMode]::Append,
                                     [System.IO.FileAccess]::Write, [System.IO.FileShare]::ReadWrite)
        $fs.Dispose()
        return $true
    } catch { return $false }
}

# Bake one tool's completion script to a file. Running the generators at shell startup instead
# would cost 100-300ms per tool on every new terminal; this way the profile only dot-sources.
function Write-ToolCompletion {
    param([string]$Cmd)
    if (-not (Test-Tool $Cmd)) { return $false }

    # Same reason as Invoke-Verification: generators write hints to stderr, which EAP=Stop
    # would report as failure. Function scope, so it is restored on return.
    $ErrorActionPreference = 'Continue'
    try {
        $s = (& $Cmd completion powershell 2>$null | Out-String)
        if ($LASTEXITCODE -ne 0 -or -not $s.Trim()) { throw "no completion output (exit $LASTEXITCODE)" }

        # cobra writes "Completion ended with directive: ..." to stderr on every request, and its
        # own '2>&1 | Out-Null' misses it: the redirection binds to Invoke-Expression, not to the
        # native command inside the string it evaluates. Push it inside the string. No match
        # (other generator, other version) just means the noise stays; completion still works.
        $s = $s -replace '(?m)^(\s*Invoke-Expression\s+-OutVariable\s+out\s+"\$RequestComp)("\s*)2>&1', '$1 2>`$$null$2'

        # cobra registers the completer under the real command name only. Aliases are .bootrc's
        # business now and the core cannot know them, so resolve them at shell start instead of
        # baking one name in at install time. The block dot-sources .bootrc before this file,
        # so any alias defined there is already visible here.
        if ($s -match "(?m)^Register-ArgumentCompleter\s+(?:-Native\s+)?-CommandName\s+'?$Cmd'?\s+-ScriptBlock\s+(\`$\{?\w+\}?)") {
            $s += @"

Get-Alias -Definition $Cmd -ErrorAction SilentlyContinue | ForEach-Object {
    Register-ArgumentCompleter -CommandName `$_.Name -ScriptBlock $($Matches[1])
}
"@
        } else {
            Write-Warn "$Cmd : aliases get no completion (unexpected generator output)"
        }

        Set-Content -Path (Join-Path $CompletionD "$Cmd.ps1") -Value $s -Encoding UTF8
        return $true
    } catch {
        Write-Warn "$Cmd completion skipped: $($_.Exception.Message)"
        return $false
    }
}

function Install-Completions {
    Write-Step "completion"

    try {
        # Wiped every run, like the directory it replaces: a tool that is gone must not leave a
        # stale completer that keeps answering for it.
        if (Test-Path $CompletionD) { Remove-Item (Join-Path $CompletionD '*.ps1') -Force -ErrorAction SilentlyContinue }
        New-Item -ItemType Directory -Path $CompletionD -Force | Out-Null

        # profile.d is what the previous design generated. It is ours, nothing in it was ever
        # user content, and leaving it means a profile that still references it keeps loading
        # stale completers alongside the new block.
        $legacy = Join-Path $ToolsRoot 'profile.d'
        if (Test-Path $legacy) {
            Remove-Item $legacy -Recurse -Force -ErrorAction SilentlyContinue
            Write-Ok "removed legacy profile.d"
        }

        $done = @('kubectl','helm','eksctl','k9s') | Where-Object { Write-ToolCompletion -Cmd $_ }
        $Script:CompletionsBaked = @($done)
        if ($done) { Write-Ok "baked $($done -join ', ')" } else { Write-Skip "no completion-capable tool installed" }
        return $true
    } catch {
        Write-Err $_.Exception.Message
        return $false
    }
}

# Where the user's shell config comes from. Current directory first: the natural gesture is to
# stand in a folder that has a .bootrc and run bootstrap there. No remote fallback - "there is
# one, or there is not" is the whole rule.
function Get-BootRcPath {
    foreach ($d in @($PWD.Path, $PSScriptRoot)) {
        if (-not $d) { continue }
        $p = Join-Path $d '.bootrc'
        if (Test-Path $p) { return (Resolve-Path $p).Path }
    }
    return $null
}

function Set-ManagedBlock {
    param([string]$Path, [string]$Body)   # empty $Body removes the block

    $existed = Test-Path $Path
    $raw = if ($existed) { Get-Content -LiteralPath $Path -Raw } else { '' }
    if ($null -eq $raw) { $raw = '' }     # -Raw on an empty file yields $null, not ''

    # Preserve how the file was already written. A profile made by notepad is CRLF and may carry
    # a BOM; silently rewriting someone's encoding is not our business. Normalise to LF to edit.
    # A file with no line ending at all - empty, or one unterminated line - teaches us nothing,
    # so fall back to CRLF rather than silently introducing LF endings on Windows.
    $crlf   = if ($raw -match "`n") { [bool]($raw -match "`r`n") } else { $true }
    $hadBom = $existed -and ((Get-Content -LiteralPath $Path -AsByteStream -TotalCount 3) -join ',') -eq '239,187,191'
    $txt    = $raw -replace "`r`n", "`n"

    $block = if ($Body) { "$BlockBegin`n$Body`n$BlockEnd" } else { '' }
    $rx    = [regex]::new('(?s)' + [regex]::Escape($BlockBegin) + '.*?' + [regex]::Escape($BlockEnd))
    $m     = $rx.Matches($txt)

    if ($m.Count -gt 0) {
        # Remove/Insert, never -replace: the replacement is user text, and in a .NET replacement
        # '$_' means the entire input string while '$$' collapses to '$'. A .bootrc containing a
        # single $_ - the most common token in PowerShell - would splice the whole profile into
        # itself. Extras (an interrupted earlier run) are dropped tail-first so earlier offsets
        # stay valid, and the first block is rewritten in place so the user's order is kept.
        for ($i = $m.Count - 1; $i -ge 1; $i--) { $txt = $txt.Remove($m[$i].Index, $m[$i].Length) }
        $txt = $txt.Remove($m[0].Index, $m[0].Length).Insert($m[0].Index, $block)
    } elseif ($block) {
        $txt = if ($txt.Trim()) { $txt.TrimEnd("`n") + "`n`n" + $block + "`n" } else { $block + "`n" }
    }

    if ($crlf) { $txt = $txt -replace "`n", "`r`n" }
    if ($existed -and $txt -eq $raw) { return $false }

    [System.IO.File]::WriteAllText($Path, $txt, [System.Text.UTF8Encoding]::new($hadBom))
    return $true
}

function Copy-ProfileBackup {
    param([string]$Path, [string]$Tag)
    if (-not (Test-Path $Path)) { return }
    # Into our own log directory, not next to the profile: that directory is not ours to litter.
    # Milliseconds because a run that backs up two profiles does it well inside one second.
    $dst = Join-Path $LogDir ("profile_{0}_{1}.bak" -f $Tag, (Get-Date -Format 'yyyyMMdd_HHmmss_fff'))
    Copy-Item -LiteralPath $Path -Destination $dst -Force -ErrorAction SilentlyContinue
}

function Install-BootRc {
    Write-Step ".bootrc"

    try {
        $rcPath = Get-BootRcPath
        if (-not $rcPath) {
            Write-Skip "none in $($PWD.Path) - shell integration off"
            return $true
        }

        $rc = Get-Content -LiteralPath $rcPath -Raw
        if ($null -eq $rc) { $rc = '' }

        # The profile is the one artifact whose failure mode is 'every new shell on this PC is
        # now noisy'. Parsing costs nothing and turns that into one [FAIL] line here instead.
        $errs = $null
        [void][System.Management.Automation.Language.Parser]::ParseInput($rc, [ref]$null, [ref]$errs)
        if ($errs) {
            Write-Err "$rcPath line $($errs[0].Extent.StartLineNumber): $($errs[0].Message)"
            return $false
        }

        # Completions load last so aliases defined in .bootrc already exist when the baked files
        # look for them. $LabToolsRoot keeps the block correct under a non-default -InstallDir.
        $body = @"
# Generated by lab-bootstrap from $rcPath. Edits between the markers are lost on the next run.
`$LabToolsRoot = '$ToolsRoot'
$($rc.TrimEnd())
Get-ChildItem "`$LabToolsRoot\completion\*.ps1" -ErrorAction SilentlyContinue | ForEach-Object { . `$_.FullName }
"@

        # AllUsersAllHosts is $PSHOME\profile.ps1, and a Microsoft Store (MSIX) pwsh puts $PSHOME
        # under C:\Program Files\WindowsApps: TrustedInstaller-owned, denied even to elevated
        # Administrators, and version-stamped so the next pwsh update would orphan it anyway.
        # Per-user is the fallback; its parent may not exist yet, hence the New-Item - best
        # effort, because a redirected Documents on an unreachable share must not stop us from
        # trying the all-users profile. $PROFILE resolves that redirection, so never build it.
        $allUsers = $PROFILE.AllUsersAllHosts
        $perUser  = $PROFILE.CurrentUserAllHosts
        New-Item -ItemType Directory -Path (Split-Path $perUser -Parent) -Force -ErrorAction SilentlyContinue | Out-Null

        # First writable wins, and the loop stops there on purpose: probing appends, so testing a
        # candidate we are not going to use would leave an empty profile behind.
        $target = $null
        foreach ($p in @($allUsers, $perUser)) {
            if (Test-ProfileWritable $p) { $target = $p; break }
        }
        if (-not $target) {
            Write-Err "no writable pwsh profile (tried $allUsers, $perUser)"
            return $false
        }

        Copy-ProfileBackup -Path $target -Tag $(if ($target -eq $allUsers) { 'allusers' } else { $env:USERNAME })
        if (Set-ManagedBlock -Path $target -Body $body) { Write-Ok "$target <- $rcPath" }
        else { Write-Skip "already current ($target)" }
        $Script:BootRcTarget = $target

        # Exactly one block per machine. A PC that moved between MSI and Store pwsh would
        # otherwise keep an older copy and register every alias twice.
        $other = if ($target -eq $allUsers) { $perUser } else { $allUsers }
        if ((Test-Path $other) -and ((Get-Content -LiteralPath $other -Raw -ErrorAction SilentlyContinue) -match [regex]::Escape($BlockBegin))) {
            Copy-ProfileBackup -Path $other -Tag 'other'
            if (Set-ManagedBlock -Path $other -Body '') { Write-Ok "removed stale block from $other" }
        }

        if ($target -eq $allUsers) {
            Write-Warn "all-users profile: this runs in every account's shell, elevated ones included"
        } else {
            Write-Warn "all-users profile is read-only (Store pwsh); applies to $env:USERNAME only"
        }
        return $true
    } catch {
        Write-Err $_.Exception.Message
        return $false
    }
}
