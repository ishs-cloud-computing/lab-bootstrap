# lab-bootstrap lib 1
# SPDX-License-Identifier: BSD-3-Clause
# Copyright 2026 The ISHS Cloud Computing Authors
#
# The summary. Reports shell integration too, not just tools: a run that installed everything
# and hooked nothing used to print 'All tools OK.' while aliases and completion were dead.
# Provided by the loader: $Script:BootRcTarget $Script:CompletionsBaked
# Definitions only - no top-level code, so load order never matters.

function Invoke-Verification {
    # These tools may write to stderr or return non-zero while healthy, which EAP=Stop would
    # report as a failure. Function scope, so it is restored on return.
    $ErrorActionPreference = 'Continue'

    Write-Step "Verify"
    Sync-Path
    $checks = @(
        @{ Name = 'AWS CLI';    Cmd = 'aws';                    Args = @('--version') }
        @{ Name = 'SSM plugin'; Cmd = 'session-manager-plugin'; Args = @('--version') }
        @{ Name = 'Helm';       Cmd = 'helm';                   Args = @('version','--short') }
        @{ Name = 'eksctl';     Cmd = 'eksctl';                 Args = @('version') }
        @{ Name = 'kubectl';    Cmd = 'kubectl';                Args = @('version','--client') }
        @{ Name = 'Terraform';  Cmd = 'terraform';              Args = @('version') }
        @{ Name = 'VS Code';    Cmd = 'code';                   Args = @('--version') }
        @{ Name = 'k9s';        Cmd = 'k9s';                    Args = @('version','-s') }
        @{ Name = 'zoxide';     Cmd = 'zoxide';                 Args = @('--version') }
        @{ Name = 'Neovim';     Cmd = 'nvim';                   Args = @('--version') }
    )
    $fails = @()
    foreach ($c in $checks) {
        if (-not (Test-Tool $c.Cmd)) {
            Write-Err ("{0,-11} not on PATH" -f $c.Name)
            $fails += $c.Name
            continue
        }
        try {
            $out = (& $c.Cmd @($c.Args) 2>&1 | Select-Object -First 1) -join ' '
            Write-Ok ("{0,-11} {1}" -f $c.Name, $out)
        } catch {
            Write-Err ("{0,-11} version check failed" -f $c.Name)
            $fails += $c.Name
        }
    }

    $ssh = Get-Service -Name 'ssh-agent' -ErrorAction SilentlyContinue
    if ($ssh) { Write-Ok ("{0,-11} {1} ({2})" -f 'ssh-agent', $ssh.Status, $ssh.StartType) }
    else      { Write-Err ("{0,-11} service missing" -f 'ssh-agent') }

    $baked = @($Script:CompletionsBaked)
    if ($baked.Count) { Write-Ok ("{0,-11} {1}" -f 'completion', ($baked -join ', ')) }

    # Not a failure when absent: no .bootrc is a valid choice, and the tools are still installed.
    # It has to be visible either way, because 'the aliases do nothing' is otherwise silent.
    if ($Script:BootRcTarget) {
        Write-Ok ("{0,-11} {1} (new terminal required)" -f '.bootrc', $Script:BootRcTarget)
    } else {
        Write-Skip ("{0,-11} none - shell integration off" -f '.bootrc')
    }

    Write-Host ""
    if ($fails.Count -eq 0) { Write-Host "All checks OK." -ForegroundColor Green }
    else { Write-Host ("Failed: {0}" -f ($fails -join ', ')) -ForegroundColor Red }
    Write-Host "Open a new terminal for PATH changes." -ForegroundColor DarkGray
}
