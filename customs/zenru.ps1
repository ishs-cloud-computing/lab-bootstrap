# SPDX-License-Identifier: BSD-3-Clause
# Copyright 2026 The ISHS Cloud Computing Authors
#
# Custom: zenru - short aliases (g/k/tf) and tab completion.
# Dot-sourced by bootstrap.ps1; see customs/README.md for what is available here.
# User documentation: customs/zenru.md

# Terraform has no PowerShell completion generator ('-install-autocomplete' writes bash/zsh
# only), so this is hand-rolled from the documented subcommand list.
# ponytail: subcommand names only. Extend if resource/variable completion is ever wanted.
$zenruTerraform = @'
$tfCmds = 'init','validate','plan','apply','destroy','fmt','show','output','state',
          'import','workspace','providers','refresh','taint','untaint','console',
          'graph','login','logout','test','version'
Register-ArgumentCompleter -Native -CommandName terraform,tf -ScriptBlock {
    param($wordToComplete, $commandAst, $cursorPosition)
    # Only the first argument is a subcommand; past that we have nothing useful to say.
    if ($commandAst.CommandElements.Count -gt 2) { return }
    $tfCmds | Where-Object { $_ -like "$wordToComplete*" } | ForEach-Object {
        [System.Management.Automation.CompletionResult]::new($_, $_, 'ParameterValue', $_)
    }
}
'@

$zenruAliases = @'
Set-Alias -Name g  -Value git
Set-Alias -Name k  -Value kubectl
Set-Alias -Name tf -Value terraform
'@

# kubectl's own generator, with the completer re-registered for 'k'.
Write-ToolCompletion -Cmd 'kubectl' -Alias 'k'
Write-ToolCompletion -Cmd 'helm'
Write-ToolCompletion -Cmd 'eksctl'
Write-ToolCompletion -Cmd 'k9s'

# Files this custom owns are prefixed, so a second custom cannot silently overwrite them.
Set-Content -Path (Join-Path $ProfileD 'zenru-aliases.ps1') -Value $zenruAliases -Encoding UTF8
Write-Ok "aliases g / k / tf"

if (Test-Tool 'terraform') {
    Set-Content -Path (Join-Path $ProfileD 'zenru-terraform.ps1') -Value $zenruTerraform -Encoding UTF8
    Write-Ok "terraform completion"
}
