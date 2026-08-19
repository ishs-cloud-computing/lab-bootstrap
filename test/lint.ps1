# SPDX-License-Identifier: BSD-3-Clause
# Copyright 2026 The ISHS Cloud Computing Authors
#
# Static checks. Runs anywhere pwsh runs - no Windows, no network, nothing installed on the
# machine under test.
#
# The parse pass is the one that matters most: the loader only checks lib/*.ps1 for its marker
# line, never that the text is valid PowerShell, so a syntax error ships as a runtime failure
# on every lab PC at once, in a message that does not name the file. The rest are the three
# things bootstrap.ps1 and lib/ have to agree on and neither can verify at runtime.

$ErrorActionPreference = 'Stop'

$Root     = Split-Path $PSScriptRoot -Parent
$LibDir   = Join-Path $Root 'lib'
$BootPath = Join-Path $Root 'bootstrap.ps1'
$Fail     = 0

function Rel  { param([string]$P) $P.Substring($Root.Length).TrimStart([char]'/', [char]'\') }
function Bad  { param([string]$Msg) $script:Fail++; Write-Host "FAIL $Msg" -ForegroundColor Red }
function Good { param([string]$Msg) Write-Host "ok   $Msg" -ForegroundColor Green }

function Get-Ast {
    param([string]$Path)
    $errs = $null
    $ast  = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$null, [ref]$errs)
    if ($errs) {
        Bad ("{0} line {1}: {2}" -f (Rel $Path), $errs[0].Extent.StartLineNumber, $errs[0].Message)
        return $null
    }
    return $ast
}

# 1. Everything parses, .bootrc and the tests included. .bootrc becomes a pwsh profile, so a
#    syntax error there makes every new terminal on the PC noisy.
Write-Host "`n== parse" -ForegroundColor Cyan
$libFiles = @(Get-ChildItem $LibDir -Filter *.ps1 | Sort-Object Name)
$asts     = @{}
foreach ($f in @($BootPath, (Join-Path $Root '.bootrc')) +
                $libFiles.FullName +
                (Get-ChildItem $PSScriptRoot -Filter *.ps1).FullName) {
    if (Get-Ast $f) { Good "parse $(Rel $f)"; $asts[$f] = $true }
}

# 2. $LibVersion and the marker on every lib file's first line. The loader refuses a mismatch
#    at install time, which is the right behaviour and the worst possible time to find out.
Write-Host "`n== loader contract" -ForegroundColor Cyan
$boot = Get-Content $BootPath -Raw
if ($boot -match '(?m)^\$LibVersion\s*=\s*(\d+)') {
    $libVer = $Matches[1]
    foreach ($f in $libFiles) {
        $first = (Get-Content $f.FullName -TotalCount 1)
        if ($first -match "^# lab-bootstrap lib $libVer\b") { Good "marker $(Rel $f.FullName) = lib $libVer" }
        else { Bad "$(Rel $f.FullName) first line is '$first', expected '# lab-bootstrap lib $libVer'" }
    }
} else {
    Bad 'no $LibVersion assignment in bootstrap.ps1'
}

# 3. $LibFiles vs what is actually in lib/. A new lib file that nobody added to the list is
#    never fetched, and under 'irm | iex' there is no lib/ directory to notice it missing.
if ($boot -match '(?m)^\$LibFiles\s*=\s*(.+)$') {
    $listed = [regex]::Matches($Matches[1], "'([^']+)'") | ForEach-Object { $_.Groups[1].Value }
    $onDisk = $libFiles.BaseName
    $missing = $onDisk | Where-Object { $_ -notin $listed }
    $extra   = $listed | Where-Object { $_ -notin $onDisk }
    if ($missing) { Bad "lib/$($missing -join '.ps1, lib/').ps1 exists but is not in `$LibFiles" }
    if ($extra)   { Bad "`$LibFiles names $($extra -join ', ') but lib/ has no such file" }
    if (-not $missing -and -not $extra) { Good "`$LibFiles = $($listed -join ', ')" }
} else {
    Bad 'no $LibFiles assignment in bootstrap.ps1'
}

# 4. Every ${function:X} the loader hands to Install-Tool exists in lib/. A typo here binds
#    $null to -Fallback or -Latest and the tool silently loses its download path.
Write-Host "`n== function references" -ForegroundColor Cyan
$bootAst = Get-Ast $BootPath
if ($bootAst) {
    $defined = @()
    foreach ($f in $libFiles) {
        $a = Get-Ast $f.FullName
        if ($a) {
            $defined += $a.FindAll({ param($n)
                $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true).Name
        }
    }
    $refs = $bootAst.FindAll({ param($n)
        $n -is [System.Management.Automation.Language.VariableExpressionAst] -and
        $n.VariablePath.UserPath -like 'function:*' }, $true) |
        ForEach-Object { $_.VariablePath.UserPath -replace '^function:', '' } |
        Sort-Object -Unique

    if (-not $refs) { Bad 'no ${function:...} references found - did the loader change shape?' }
    foreach ($r in $refs) {
        if ($r -in $defined) { Good "`${function:$r}" } else { Bad "`${function:$r} is not defined in lib/" }
    }
}

# 5. PSScriptAnalyzer over the shipped code only. The exclusions are deliberate choices this
#    codebase already made, not findings waved away:
#      WriteHost              - the whole logging layer is Write-Host; that is the output
#      ApprovedVerbs          - Fallback-* / Latest-* are the naming convention here
#      DeclaredVarsMoreThan.. - bootstrap.ps1 assigns what lib/*.ps1 consumes after dot-sourcing,
#                               which the analyzer cannot see across the loader boundary
#      SingularNouns          - Install-Completions, Get-VersionArgs
#      ShouldProcess          - an installer already gated by UAC does not need -WhatIf plumbing
#    The baseline is zero, so anything this prints is new.
Write-Host "`n== PSScriptAnalyzer" -ForegroundColor Cyan
if (-not (Get-Module -ListAvailable PSScriptAnalyzer)) {
    Bad 'PSScriptAnalyzer not installed: Install-Module PSScriptAnalyzer -Scope CurrentUser'
} else {
    Import-Module PSScriptAnalyzer
    $exclude = 'PSAvoidUsingWriteHost', 'PSUseApprovedVerbs', 'PSUseDeclaredVarsMoreThanAssignments',
               'PSUseSingularNouns', 'PSUseShouldProcessForStateChangingFunctions'
    $found = @(Invoke-ScriptAnalyzer -Path $BootPath -Severity Error, Warning -ExcludeRule $exclude) +
             @(Invoke-ScriptAnalyzer -Path $LibDir -Recurse -Severity Error, Warning -ExcludeRule $exclude)
    if ($found) {
        foreach ($d in $found) { Bad ("{0} {1}:{2} {3}" -f $d.RuleName, (Rel $d.ScriptPath), $d.Line, $d.Message) }
    } else {
        Good 'no findings'
    }
}

Write-Host ""
if ($Fail) { Write-Host "$Fail failed" -ForegroundColor Red } else { Write-Host "all ok" -ForegroundColor Green }
exit $Fail
