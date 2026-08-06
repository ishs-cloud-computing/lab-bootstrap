# lab-bootstrap lib 1
# SPDX-License-Identifier: BSD-3-Clause
# Copyright 2026 The ISHS Cloud Computing Authors
#
# Machine state: privileges, PATH, services.
# Provided by the loader: $InstallDir $EnvKey $KubectlMinor $BaseUrl $NoWinget $Force
# Definitions only - no top-level code, so load order never matters.

# Elevation
function Assert-Admin {
    $id  = [Security.Principal.WindowsIdentity]::GetCurrent()
    $pri = New-Object Security.Principal.WindowsPrincipal($id)
    if ($pri.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { return }

    Write-Warn "Not administrator. Re-launching elevated..."

    # No file path (irm | iex) means there is nothing to re-launch. Throw rather than exit:
    # 'exit' would close the user's interactive window before they can read why. A throw
    # still yields exit code 1 when the script runs as a file.
    if ([string]::IsNullOrEmpty($PSCommandPath)) {
        throw "Cannot self-elevate without a script file. Start pwsh as administrator, then retry."
    }

    $pwsh    = (Get-Process -Id $PID).Path
    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"",
                 '-KubectlMinor', $KubectlMinor, '-InstallDir', "`"$InstallDir`"",
                 '-BaseUrl', "`"$BaseUrl`"")
    if ($NoWinget) { $argList += '-NoWinget' }
    if ($Force)    { $argList += '-Force' }

    try {
        Start-Process -FilePath $pwsh -Verb RunAs -ArgumentList $argList
    } catch {
        throw "Elevation declined. Run this from an administrator pwsh."
    }
    exit 0   # the elevated process takes over
}

# Picks up PATH entries that installers just registered, without restarting the shell.
function Sync-Path {
    $machine = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    $user    = [Environment]::GetEnvironmentVariable('Path', 'User')
    $env:Path = @($machine, $user, $InstallDir | Where-Object { $_ }) -join ';'
}

function Test-Tool { param([string]$Cmd) [bool](Get-Command $Cmd -ErrorAction SilentlyContinue) }

# [Environment]::SetEnvironmentVariable broadcasts this for us; a direct registry write does
# not, and without it Explorer-spawned terminals keep the old PATH until logoff.
function Publish-EnvChange {
    if (-not ('Win32.NativeMethods' -as [type])) {
        Add-Type -Namespace 'Win32' -Name 'NativeMethods' -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("user32.dll", SetLastError = true, CharSet = System.Runtime.InteropServices.CharSet.Unicode)]
public static extern System.IntPtr SendMessageTimeout(System.IntPtr hWnd, uint Msg, System.UIntPtr wParam,
    string lParam, uint fuFlags, uint uTimeout, out System.UIntPtr lpdwResult);
'@
    }
    $res = [System.UIntPtr]::Zero
    # HWND_BROADCAST, WM_SETTINGCHANGE, SMTO_ABORTIFHUNG, 5s timeout
    [void][Win32.NativeMethods]::SendMessageTimeout([IntPtr]0xFFFF, 0x1A, [System.UIntPtr]::Zero,
                                                    'Environment', 2, 5000, [ref]$res)
}

function Add-SystemPath {
    param([string]$Dir)
    # Read raw: [Environment]::GetEnvironmentVariable('Path','Machine') expands REG_EXPAND_SZ,
    # so writing it back would freeze %SystemRoot% into a literal and downgrade it to REG_SZ.
    $cur   = (Get-Item $EnvKey).GetValue('Path', '', 'DoNotExpandEnvironmentNames')
    $parts = $cur -split ';' | Where-Object { $_ }
    if ($parts -notcontains $Dir) {
        Set-ItemProperty -Path $EnvKey -Name 'Path' -Value ($cur.TrimEnd(';') + ';' + $Dir) -Type ExpandString
        Publish-EnvChange
        Write-Ok "PATH += $Dir"
    }
    Sync-Path
}

# ssh-agent: Automatic so it survives the lab PC reboot
function Enable-SshAgent {
    Write-Step "ssh-agent"

    if (-not (Get-Service -Name 'ssh-agent' -ErrorAction SilentlyContinue)) {
        Write-Warn "service missing. Add 'OpenSSH Client' in Settings > Apps > Optional features"
        return $false
    }

    try {
        # Must precede Start-Service: some machines ship this service Disabled.
        Set-Service -Name 'ssh-agent' -StartupType Automatic -ErrorAction Stop
        if ((Get-Service -Name 'ssh-agent').Status -ne 'Running') { Start-Service -Name 'ssh-agent' -ErrorAction Stop }
        Write-Ok "running, startup Automatic"
        return $true
    } catch {
        Write-Err $_.Exception.Message
        return $false
    }
}
